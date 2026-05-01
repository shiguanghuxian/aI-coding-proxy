import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Security
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import CSQLite3
import XCTest
@testable import CodexProxyCore

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let testGeminiOAuthClientID = "codex-proxy-test-client-id"
private let testGeminiOAuthClientSecret = "codex-proxy-test-client-secret"

final class CodexProxyCoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Self.setGeminiOAuthTestCredentials()
    }

    func testNormalizeLegacyAuthJSON() throws {
        let legacy = """
        {
          "access_token": "access",
          "refresh_token": "refresh",
          "id_token": "header.\(Self.base64URL(["sub": "principal", "https://api.openai.com/auth": ["chatgpt_account_id": "account"]])).sig"
        }
        """
        let normalized = try AuthService.normalizeImportedAuthJSON(legacy)
        let extracted = try AuthService.extractAuth(from: normalized)
        XCTAssertEqual(extracted.accountID, "account")
        XCTAssertEqual(extracted.principalID, "principal")
        XCTAssertEqual(extracted.refreshToken, "refresh")
    }

    func testNormalizeOpenAIAPIKeyAuthJSON() throws {
        let raw = """
        {
          "OPENAI_API_KEY": "sk-test-123"
        }
        """
        let normalized = try AuthService.normalizeImportedAuthJSON(raw)
        let extracted = try AuthService.extractAuth(from: normalized)

        XCTAssertEqual(extracted.authMode, .openAIAPIKey)
        XCTAssertEqual(extracted.accessToken, "sk-test-123")
        XCTAssertEqual(extracted.planType, "api_key")
        XCTAssertEqual(extracted.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(extracted.upstreamBaseURL, OpenAICompatibleUpstream.defaultBaseURL)
        XCTAssertFalse(AuthService.authNeedsRefresh(normalized))
    }

    func testPrepareGeminiOAuthLoginRequiresConfiguredOAuthCredentials() async throws {
        try await Self.withEnvironment([
            GeminiAuthService.oauthClientIDEnvironmentVariable: nil,
            GeminiAuthService.oauthClientSecretEnvironmentVariable: nil,
        ]) {
            XCTAssertThrowsError(
                try GeminiAuthService.prepareOAuthLogin(callbackPort: 1455, config: AppConfig())
            ) { error in
                XCTAssertTrue(String(describing: error).contains(GeminiAuthService.oauthClientIDEnvironmentVariable))
            }
        }
    }

    func testNormalizeAnthropicAPIKeyAuthJSONInfersManualProviderFamily() throws {
        let raw = """
        {
          "x-api-key": "sk-anthropic-test",
          "base_url": "https://api.anthropic.com/v1"
        }
        """
        let normalized = try AuthService.normalizeImportedAuthJSON(raw)
        let extracted = try AuthService.extractAuth(from: normalized)
        let metadata = AuthService.extractAuthMetadata(from: normalized)

        XCTAssertEqual(extracted.providerFamily, .anthropic)
        XCTAssertEqual(extracted.authMode, .anthropicAPIKey)
        XCTAssertEqual(extracted.providerPreset, .anthropicAPICompatible)
        XCTAssertEqual(extracted.accessToken, "sk-anthropic-test")
        XCTAssertEqual(extracted.planType, "api_key")
        XCTAssertEqual(extracted.upstreamBaseURL, AnthropicAPIKeyUpstream.defaultBaseURL)
        XCTAssertEqual(metadata.providerFamily, .anthropic)
        XCTAssertEqual(metadata.authMode, .anthropicAPIKey)
        XCTAssertEqual(metadata.providerPreset, .anthropicAPICompatible)
        XCTAssertEqual(metadata.upstreamBaseURL, AnthropicAPIKeyUpstream.defaultBaseURL)
        XCTAssertFalse(AuthService.authNeedsRefresh(normalized))
    }

    func testAccountAuthModeDecodesLegacyChatGPTAndAnthropicOAuthModes() throws {
        XCTAssertEqual(try Helpers.readJSON(AccountAuthMode.self, from: Data(#""chatgpt""#.utf8)), .chatGPT)
        XCTAssertEqual(
            try Helpers.readJSON(AccountAuthMode.self, from: Data(#""anthropic_subscription_oauth""#.utf8)),
            .anthropicSubscriptionOAuth
        )
    }

    func testProxyAPIKeyRecordDefaultsDataSourceToOpenAIWhenMissing() throws {
        let raw = #"""
        {
          "id": "legacy-key",
          "label": "Legacy",
          "key": "sk-local-legacy",
          "enabled": true,
          "created_at": 1710000000
        }
        """#
        let record = try Helpers.readJSON(ProxyAPIKeyRecord.self, from: Data(raw.utf8))

        XCTAssertEqual(record.dataSource, .openAI)
    }

    func testProxyAPIKeyRecordRoundTripsAllDataSource() throws {
        let record = ProxyAPIKeyRecord(
            id: "all-key",
            label: "All",
            key: "sk-local-all",
            dataSource: .all,
            enabled: true,
            createdAt: 1710000000
        )

        let data = try Helpers.encodeJSON(record)
        let decoded = try Helpers.readJSON(ProxyAPIKeyRecord.self, from: data)

        XCTAssertEqual(decoded.dataSource, .all)
    }

    func testProxyAPIKeyRecordDefaultsAllowedAccountKeysToEmptyWhenMissing() throws {
        let raw = #"""
        {
          "id": "legacy-key",
          "label": "Legacy",
          "key": "sk-local-legacy",
          "data_source": "all",
          "enabled": true,
          "created_at": 1710000000
        }
        """#
        let record = try Helpers.readJSON(ProxyAPIKeyRecord.self, from: Data(raw.utf8))

        XCTAssertEqual(record.allowedAccountKeys, [])
    }

    func testProxyAPIKeyRecordNormalizesAllowedAccountKeysTrimmedDedupedAndOrdered() {
        let record = ProxyAPIKeyRecord(
            id: "restricted-key",
            label: "Restricted",
            key: "sk-local-restricted",
            dataSource: .all,
            allowedAccountKeys: [" acct-openai ", "", "acct-anthropic", "acct-openai", "acct-openai  "],
            enabled: true,
            createdAt: 1710000000
        )

        XCTAssertEqual(record.allowedAccountKeys, ["acct-openai", "acct-anthropic"])
    }

    func testExtractAnthropicOAuthAuthFromSecretStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let bundle = AnthropicOAuthSecretBundle(
            accessToken: "anthropic-access-token",
            refreshToken: "anthropic-refresh-token",
            expiresAt: Helpers.now() + 3_600,
            tokenType: "Bearer",
            scope: "user:profile"
        )
        let secretRef = try secretStore.saveAnthropicOAuthSecret(bundle)
        let authJSON = """
        {
          "auth_mode": "anthropic_subscription_oauth",
          "provider_family": "anthropic",
          "secret_ref": "\(secretRef)",
          "account_id": "anthropic-account",
          "principal_id": "anthropic-principal",
          "email": "claude@example.com",
          "plan_type": "pro",
          "upstream_base_url": "https://api.anthropic.com"
        }
        """

        let extracted = try AuthService.extractAuth(from: authJSON, secretStore: secretStore)

        XCTAssertEqual(extracted.providerFamily, .anthropic)
        XCTAssertEqual(extracted.authMode, .anthropicSubscriptionOAuth)
        XCTAssertEqual(extracted.accountID, "anthropic-account")
        XCTAssertEqual(extracted.principalID, "anthropic-principal")
        XCTAssertEqual(extracted.accessToken, "anthropic-access-token")
        XCTAssertEqual(extracted.refreshToken, "anthropic-refresh-token")
        XCTAssertEqual(extracted.email, "claude@example.com")
        XCTAssertEqual(extracted.planType, "pro")
        XCTAssertEqual(extracted.upstreamBaseURL, "https://api.anthropic.com")
        XCTAssertFalse(AuthService.authNeedsRefresh(authJSON, secretStore: secretStore))
    }

    func testNormalizeManualAPIKeyInputPreservesBaseURLAndChangesIdentityByBaseURL() throws {
        let openAIAuth = try AuthService.normalizeManualAPIKeyInput(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test-123",
            baseURLMode: .exactAPIPrefix
        )
        let proxyAuth = try AuthService.normalizeManualAPIKeyInput(
            baseURL: "https://example.com/proxy/v1",
            apiKey: "sk-test-123",
            baseURLMode: .exactAPIPrefix
        )

        let openAIExtracted = try AuthService.extractAuth(from: openAIAuth)
        let proxyExtracted = try AuthService.extractAuth(from: proxyAuth)

        XCTAssertEqual(openAIExtracted.upstreamBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(openAIExtracted.baseURLMode, .exactAPIPrefix)
        XCTAssertEqual(proxyExtracted.upstreamBaseURL, "https://example.com/proxy/v1")
        XCTAssertEqual(proxyExtracted.baseURLMode, .exactAPIPrefix)
        XCTAssertNotEqual(openAIExtracted.accountID, proxyExtracted.accountID)
        XCTAssertNotEqual(AuthService.accountKey(from: openAIExtracted), AuthService.accountKey(from: proxyExtracted))
    }

    func testGenericManualAPIKeyWithoutBaseURLModeDefaultsToExactPrefix() throws {
        let authJSON = """
        {
          "auth_mode": "openai_api_key",
          "provider_preset": "generic_openai_compatible",
          "upstream_base_url": "https://api.deepseek.com",
          "tokens": {
            "access_token": "sk-exact"
          }
        }
        """

        let extracted = try AuthService.extractAuth(from: authJSON)

        XCTAssertEqual(extracted.upstreamBaseURL, "https://api.deepseek.com")
        XCTAssertEqual(extracted.baseURLMode, .exactAPIPrefix)
        XCTAssertEqual(extracted.upstreamAdapter, .responses)
        XCTAssertEqual(
            try OpenAICompatibleUpstream.chatCompletionsURL(from: "https://api.deepseek.com"),
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            try OpenAICompatibleUpstream.modelsURL(
                from: extracted.upstreamBaseURL ?? "",
                providerPreset: extracted.providerPreset,
                baseURLMode: extracted.baseURLMode
            ),
            "https://api.deepseek.com/models"
        )
        XCTAssertEqual(
            try OpenAICompatibleUpstream.responsesURL(
                from: extracted.upstreamBaseURL ?? "",
                providerPreset: extracted.providerPreset,
                baseURLMode: extracted.baseURLMode
            ),
            "https://api.deepseek.com/responses"
        )
        XCTAssertEqual(
            try OpenAICompatibleUpstream.chatCompletionsURL(
                from: extracted.upstreamBaseURL ?? "",
                providerPreset: extracted.providerPreset,
                baseURLMode: extracted.baseURLMode
            ),
            "https://api.deepseek.com/chat/completions"
        )
    }

    func testGenericManualAPIKeyUpstreamAdapterRoundTripsInAuthJSON() throws {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-chat",
            providerPreset: .genericOpenAICompatible,
            baseURLMode: .exactAPIPrefix,
            upstreamAdapter: .chatCompletions
        )

        let extracted = try AuthService.extractAuth(from: normalized)
        let metadata = AuthService.extractAuthMetadata(from: normalized)

        XCTAssertTrue(normalized.contains(#""upstream_adapter":"chat_completions""#))
        XCTAssertEqual(extracted.upstreamAdapter, .chatCompletions)
        XCTAssertEqual(metadata.upstreamAdapter, .chatCompletions)
        XCTAssertEqual(extracted.upstreamThinkingCompatibility, .disabled)
        XCTAssertEqual(metadata.upstreamThinkingCompatibility, .disabled)
    }

    func testGenericManualAPIKeyThinkingCompatibilityRoundTripsInAuthJSON() throws {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-chat",
            providerPreset: .genericOpenAICompatible,
            baseURLMode: .exactAPIPrefix,
            upstreamAdapter: .chatCompletions,
            upstreamThinkingCompatibility: .enabled
        )

        let extracted = try AuthService.extractAuth(from: normalized)
        let metadata = AuthService.extractAuthMetadata(from: normalized)

        XCTAssertTrue(normalized.contains(#""upstream_thinking_compatibility":"enabled""#))
        XCTAssertEqual(extracted.upstreamAdapter, .chatCompletions)
        XCTAssertEqual(extracted.upstreamThinkingCompatibility, .enabled)
        XCTAssertEqual(metadata.upstreamThinkingCompatibility, .enabled)
    }

    func testLegacyDeepSeekOfficialManualAPIKeyReadsAsGeneric() throws {
        let authJSON = """
        {
          "auth_mode": "openai_api_key",
          "provider_preset": "deepseek_official_api",
          "upstream_base_url": "https://api.deepseek.com",
          "upstream_base_url_mode": "exact_api_prefix",
          "upstream_adapter": "chat_completions",
          "upstream_thinking_mode": "enabled",
          "tokens": {
            "access_token": "sk-deepseek"
          }
        }
        """

        let extracted = try AuthService.extractAuth(from: authJSON)
        let metadata = AuthService.extractAuthMetadata(from: authJSON)

        XCTAssertEqual(extracted.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(metadata.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(extracted.upstreamBaseURL, "https://api.deepseek.com")
        XCTAssertEqual(extracted.baseURLMode, .exactAPIPrefix)
        XCTAssertEqual(extracted.upstreamAdapter, .chatCompletions)
        XCTAssertEqual(extracted.upstreamThinkingCompatibility, .disabled)
        XCTAssertEqual(metadata.upstreamThinkingCompatibility, .disabled)
    }

    func testManualAPIKeyAccountPayloadDecodesSnakeCaseUpstreamAdapter() throws {
        let data = Data(
            """
            {
              "provider_preset": "deepseek_official_api",
              "baseURL": "https://api.deepseek.com",
              "base_url_mode": "exact_api_prefix",
              "upstream_adapter": "chat_completions",
              "upstream_thinking_compatibility": "enabled",
              "apiKey": "sk-chat",
              "enabled": true
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ManualAPIKeyAccountInput.self, from: data)

        XCTAssertEqual(decoded.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(decoded.baseURLMode, .exactAPIPrefix)
        XCTAssertEqual(decoded.upstreamAdapter, .chatCompletions)
        XCTAssertEqual(decoded.upstreamThinkingCompatibility, .enabled)
    }

    func testLegacyDeepSeekPayloadDoesNotAutoEnableThinkingCompatibility() throws {
        let data = Data(
            """
            {
              "provider_preset": "deepseek_official_api",
              "baseURL": "https://api.deepseek.com",
              "base_url_mode": "exact_api_prefix",
              "upstream_adapter": "chat_completions",
              "upstream_thinking_mode": "enabled",
              "apiKey": "sk-chat",
              "enabled": true
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ManualAPIKeyAccountInput.self, from: data)

        XCTAssertEqual(decoded.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(decoded.upstreamAdapter, .chatCompletions)
        XCTAssertNil(decoded.upstreamThinkingCompatibility)
    }

    func testNonGenericManualAPIKeyIgnoresUpstreamAdapter() throws {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            apiKey: "AIzaSy\(String(repeating: "a", count: 32))",
            providerPreset: .googleGeminiCompatible,
            upstreamAdapter: .responses,
            upstreamThinkingCompatibility: .enabled
        )

        let extracted = try AuthService.extractAuth(from: normalized)

        XCTAssertEqual(extracted.providerPreset, .googleGeminiCompatible)
        XCTAssertNil(extracted.upstreamAdapter)
        XCTAssertNil(extracted.upstreamThinkingCompatibility)
        XCTAssertFalse(normalized.contains("upstream_adapter"))
        XCTAssertFalse(normalized.contains("upstream_thinking_compatibility"))
    }

    func testExplicitLegacyGenericManualAPIKeyBaseURLModeAppendsV1() throws {
        let authJSON = """
        {
          "auth_mode": "openai_api_key",
          "provider_preset": "generic_openai_compatible",
          "upstream_base_url": "https://legacy.example.com/proxy",
          "upstream_base_url_mode": "legacy_append_v1",
          "tokens": {
            "access_token": "sk-legacy"
          }
        }
        """

        let extracted = try AuthService.extractAuth(from: authJSON)

        XCTAssertEqual(extracted.upstreamBaseURL, "https://legacy.example.com/proxy")
        XCTAssertEqual(extracted.baseURLMode, .legacyAppendV1)
        XCTAssertEqual(
            try OpenAICompatibleUpstream.chatCompletionsURL(
                from: extracted.upstreamBaseURL ?? "",
                providerPreset: extracted.providerPreset,
                baseURLMode: extracted.baseURLMode
            ),
            "https://legacy.example.com/proxy/v1/chat/completions"
        )
    }

    func testNormalizeManualAPIKeyInputPreservesAliyunProviderPreset() throws {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: "https://coding.dashscope.aliyuncs.com/v1",
            apiKey: "sk-aliyun",
            providerPreset: .aliyunQwenCodingPlan
        )

        let extracted = try AuthService.extractAuth(from: normalized)

        XCTAssertEqual(extracted.authMode, .openAIAPIKey)
        XCTAssertEqual(extracted.providerPreset, .aliyunQwenCodingPlan)
        XCTAssertEqual(extracted.upstreamBaseURL, "https://coding.dashscope.aliyuncs.com")
        XCTAssertEqual(AuthService.extractAuthMetadata(from: normalized).providerPreset, .aliyunQwenCodingPlan)
    }

    func testNormalizeManualAPIKeyInputPreservesGeminiCompatibilityRoot() throws {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
            apiKey: "sk-gemini",
            providerPreset: .googleGeminiCompatible
        )

        let extracted = try AuthService.extractAuth(from: normalized)

        XCTAssertEqual(extracted.authMode, .openAIAPIKey)
        XCTAssertEqual(extracted.providerPreset, .googleGeminiCompatible)
        XCTAssertEqual(extracted.upstreamBaseURL, OpenAICompatibleUpstream.defaultGeminiBaseURL)
        XCTAssertEqual(
            try OpenAICompatibleUpstream.modelsURL(
                from: extracted.upstreamBaseURL ?? "",
                providerPreset: .googleGeminiCompatible
            ),
            "https://generativelanguage.googleapis.com/v1beta/openai/models"
        )
        XCTAssertEqual(
            try OpenAICompatibleUpstream.chatCompletionsURL(
                from: extracted.upstreamBaseURL ?? "",
                providerPreset: .googleGeminiCompatible
            ),
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
        XCTAssertEqual(AuthService.extractAuthMetadata(from: normalized).providerPreset, .googleGeminiCompatible)
    }

    func testManualConfigurationErrorFlagsGenericPresetOnOfficialGeminiRoot() {
        XCTAssertTrue(
            OpenAICompatibleUpstream.isOfficialGeminiCompatibilityRoot(
                "https://generativelanguage.googleapis.com/v1beta/openai/"
            )
        )
        XCTAssertEqual(
            OpenAICompatibleUpstream.manualConfigurationError(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                providerPreset: .genericOpenAICompatible
            ),
            OpenAICompatibleUpstream.geminiCompatibilityRootRequiresGeminiPresetMessage
        )
        XCTAssertNil(
            OpenAICompatibleUpstream.manualConfigurationError(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                providerPreset: .googleGeminiCompatible
            )
        )
        XCTAssertNil(
            OpenAICompatibleUpstream.manualConfigurationError(
                baseURL: "https://api.openai.com",
                providerPreset: .genericOpenAICompatible
            )
        )
    }

    func testAnthropicAPIKeyUpstreamThinkingHistoryCompatibilityDetectsDashScopeOnly() {
        XCTAssertFalse(
            AnthropicAPIKeyUpstream.supportsThinkingContentBlocks(
                baseURL: "https://dashscope.aliyuncs.com/apps/anthropic/v1"
            )
        )
        XCTAssertFalse(
            AnthropicAPIKeyUpstream.supportsThinkingContentBlocks(
                baseURL: "https://dashscope.aliyuncs.com.localhost/apps/anthropic/v1"
            )
        )
        XCTAssertFalse(
            AnthropicAPIKeyUpstream.supportsThinkingContentBlocks(
                baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
            )
        )
        XCTAssertTrue(
            AnthropicAPIKeyUpstream.supportsThinkingContentBlocks(
                baseURL: "https://api.anthropic.com/v1"
            )
        )
        XCTAssertTrue(
            AnthropicAPIKeyUpstream.supportsThinkingContentBlocks(
                baseURL: "https://example.com/v1"
            )
        )
    }

    func testGoogleGeminiCredentialConfigurationErrorFlagsOAuthLikeCredentials() {
        XCTAssertTrue(OpenAICompatibleUpstream.isLikelyGoogleAIOAuthLikeCredential("AQ.test-google-session"))
        XCTAssertTrue(OpenAICompatibleUpstream.isLikelyGoogleAIOAuthLikeCredential("ya29.test-google-oauth"))
        XCTAssertTrue(OpenAICompatibleUpstream.isLikelyGoogleAIOAuthLikeCredential("1//test-google-refresh"))
        XCTAssertNil(
            OpenAICompatibleUpstream.googleGeminiCredentialConfigurationError(
                providerPreset: .googleGeminiCompatible,
                apiKey: "AIzaSyGeminiAPIKey"
            )
        )
        XCTAssertEqual(
            OpenAICompatibleUpstream.googleGeminiCredentialConfigurationError(
                providerPreset: .googleGeminiCompatible,
                apiKey: "AQ.test-google-session"
            ),
            OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage
        )
    }

    func testHumanizedUpstreamErrorMessageMapsGeminiMultipleCredentialsError() {
        let raw = """
        [{
          "error": {
            "code": 400,
            "message": "Multiple authentication credentials received. Please pass only one.",
            "status": "INVALID_ARGUMENT"
          }
        }]
        """
        XCTAssertEqual(
            OpenAICompatibleUpstream.humanizedUpstreamErrorMessage(
                raw,
                providerPreset: .googleGeminiCompatible,
                apiKey: "AQ.test-google-session"
            ),
            OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage
        )
    }

    func testNormalizeImportedAuthJSONRepairsLegacyGenericGeminiRootToGeminiPreset() throws {
        let legacy = try Self.makeLegacyGenericGeminiManualAPIKeyRecordFixture(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "sk-gemini-legacy-import",
            label: "Legacy Gemini"
        )

        let normalized = try AuthService.normalizeImportedAuthJSON(legacy.authJSON)
        let extracted = try AuthService.extractAuth(from: normalized)

        XCTAssertEqual(extracted.providerPreset, .googleGeminiCompatible)
        XCTAssertEqual(extracted.accountID, legacy.accountID)
        XCTAssertEqual(AuthService.extractAuthMetadata(from: normalized).providerPreset, .googleGeminiCompatible)
    }

    func testGeminiProviderPresetMapsOpenAIStyleModelsToOfficialDefaults() {
        XCTAssertEqual(
            OpenAICompatibleProviderPreset.googleGeminiCompatible.resolvedUpstreamModel(for: "gpt-5"),
            "gemini-2.5-flash"
        )
        XCTAssertEqual(
            OpenAICompatibleProviderPreset.googleGeminiCompatible.resolvedUpstreamModel(for: "gpt-5-max"),
            "gemini-2.5-pro"
        )
        XCTAssertEqual(
            OpenAICompatibleProviderPreset.googleGeminiCompatible.resolvedUpstreamModel(for: "gpt-5.4-mini"),
            "gemini-2.5-flash-lite"
        )
        XCTAssertEqual(
            OpenAICompatibleProviderPreset.googleGeminiCompatible.resolvedUpstreamModel(for: "gpt-5.4"),
            "gemini-2.5-flash"
        )
    }

    func testSupportedModelsExposeConfiguredDefaultOrder() {
        XCTAssertEqual(
            ProxyTranscoder.supportedModels,
            ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-5.4-mini", "gpt-5.2"]
        )
        XCTAssertEqual(ProxyTranscoder.defaultModel, "gpt-5.5")
    }

    func testSQLiteStoreTreatsSameAPIKeyDifferentBaseURLsAsDifferentAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let firstRecord = try self.makeManualAPIKeyRecord(baseURL: "https://api.openai.com/v1", apiKey: "sk-duplicate-test", label: "Primary")
        let duplicateRecord = try self.makeManualAPIKeyRecord(baseURL: "https://api.openai.com", apiKey: "sk-duplicate-test", label: "Primary Updated")
        let secondBaseRecord = try self.makeManualAPIKeyRecord(baseURL: "https://example.com/v1", apiKey: "sk-duplicate-test", label: "Secondary")

        XCTAssertFalse(try store.upsertAccount(firstRecord))
        XCTAssertFalse(try store.upsertAccount(duplicateRecord))
        XCTAssertFalse(try store.upsertAccount(secondBaseRecord))

        let records = try store.listAccountRecords()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.filter { $0.accountKey == firstRecord.accountKey }.count, 1)
        XCTAssertEqual(records.filter { $0.accountKey == duplicateRecord.accountKey }.count, 1)
        XCTAssertEqual(records.filter { $0.accountKey == secondBaseRecord.accountKey }.count, 1)
    }

    func testAccountSummaryDecodesOptionalTodayTokenUsageCompatibly() throws {
        let payloadWithUsage = #"""
        {
          "id": "account-1",
          "label": "Primary API",
          "email": "primary@example.com",
          "account_key": "principal|account-1",
          "account_id": "account-1",
          "plan_type": "api_key",
          "auth_mode": "openai_api_key",
          "added_at": 1710000000,
          "updated_at": 1710000300,
          "enabled": true,
          "today_token_usage": {
            "input_tokens": 1200,
            "output_tokens": 450
          },
          "auth_refresh_blocked": false,
          "is_current": false
        }
        """#
        let summaryWithUsage = try Helpers.readJSON(AccountSummary.self, from: Data(payloadWithUsage.utf8))
        XCTAssertEqual(summaryWithUsage.todayTokenUsage, AccountTodayTokenUsage(inputTokens: 1_200, outputTokens: 450))
        XCTAssertEqual(summaryWithUsage.providerPreset, .genericOpenAICompatible)

        let legacyPayload = #"""
        {
          "id": "account-2",
          "label": "Legacy API",
          "account_key": "principal|account-2",
          "account_id": "account-2",
          "plan_type": "api_key",
          "auth_mode": "openai_api_key",
          "added_at": 1710000000,
          "updated_at": 1710000300,
          "enabled": true,
          "auth_refresh_blocked": false,
          "is_current": false
        }
        """#
        let legacySummary = try Helpers.readJSON(AccountSummary.self, from: Data(legacyPayload.utf8))
        XCTAssertNil(legacySummary.todayTokenUsage)
        XCTAssertEqual(legacySummary.providerPreset, .genericOpenAICompatible)
    }

    func testPrepareOAuthLoginMatchesOfficialCodexParameters() throws {
        let (_, prepared) = try AuthService.prepareOAuthLogin(callbackPort: 1455)
        XCTAssertEqual(prepared.redirectURI, "http://localhost:1455/auth/callback")

        let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
        let queryItems: [URLQueryItem] = components.queryItems ?? []
        let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(items["client_id"], AuthService.defaultOAuthClientID)
        XCTAssertEqual(items["redirect_uri"], prepared.redirectURI)
        XCTAssertEqual(items["scope"], AuthService.defaultOAuthScope)
        XCTAssertEqual(items["originator"], AuthService.defaultOAuthOriginator)
        XCTAssertEqual(items["id_token_add_organizations"], "true")
        XCTAssertEqual(items["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertFalse((items["state"] ?? "").isEmpty)
        XCTAssertFalse((items["code_challenge"] ?? "").isEmpty)
    }

    func testPrepareAnthropicOAuthLoginUsesClaudeAIFallbackAndStoresSnapshot() async throws {
        try await Self.withEnvironment([
            "CLAUDE_CODE_CLIENT_METADATA_URL": "http://127.0.0.1:9/oauth/claude-code-client-metadata",
        ]) {
            let (pending, prepared) = try await AnthropicAuthService.prepareOAuthLogin(
                callbackPort: 1455,
                config: AppConfig()
            )
            XCTAssertEqual(prepared.redirectURI, "http://localhost:1455/callback")

            let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
            let queryItems: [URLQueryItem] = components.queryItems ?? []
            let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

            XCTAssertTrue(prepared.authURL.contains(AnthropicAuthService.defaultClaudeAIAuthorizeURL))
            XCTAssertEqual(items["client_id"], AnthropicAuthService.defaultClientID)
            XCTAssertEqual(items["redirect_uri"], prepared.redirectURI)
            XCTAssertEqual(items["scope"], AnthropicAuthService.defaultScopes.joined(separator: " "))
            XCTAssertEqual(items["code_challenge_method"], "S256")
            XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.authorizeURL, AnthropicAuthService.defaultClaudeAIAuthorizeURL)
            XCTAssertEqual(
                pending.anthropicOAuthConfigSnapshot?.requestedScope,
                AnthropicAuthService.defaultScopes.joined(separator: " ")
            )
            XCTAssertEqual(
                pending.anthropicOAuthConfigSnapshot?.loginSource,
                "claude_ai_subscription"
            )
            XCTAssertFalse((items["state"] ?? "").isEmpty)
            XCTAssertFalse((items["code_challenge"] ?? "").isEmpty)
        }
    }

    func testPrepareAnthropicOAuthLoginPrefersEnvironmentOverridesOverMetadata() async throws {
        let metadata = Self.makeAnthropicOAuthMetadataApplication(
            authorizeURL: "http://127.0.0.1:9999/metadata/authorize",
            tokenURL: "http://127.0.0.1:9999/metadata/token",
            clientID: "metadata-client-id",
            requestedScope: "user:profile user:mcp_servers"
        )

        try await metadata.test(.ahc()) { metadataClient in
            try await Self.withEnvironment([
                "CLAUDE_CODE_CLIENT_METADATA_URL": "http://localhost:\(metadataClient.port ?? 0)/oauth/claude-code-client-metadata",
                "CLAUDE_CODE_AUTHORIZE_URL": "https://env.example.com/oauth/authorize",
                "CLAUDE_CODE_TOKEN_URL": "https://env.example.com/v1/oauth/token",
                "CLAUDE_CODE_OAUTH_SCOPES": "user:profile user:inference",
            ]) {
                let (pending, prepared) = try await AnthropicAuthService.prepareOAuthLogin(
                    callbackPort: 1455,
                    config: AppConfig()
                )
                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems: [URLQueryItem] = components.queryItems ?? []
                let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

                XCTAssertTrue(prepared.authURL.contains("https://env.example.com/oauth/authorize"))
                XCTAssertEqual(items["scope"], "user:profile user:inference")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.authorizeURL, "https://env.example.com/oauth/authorize")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.tokenURL, "https://env.example.com/v1/oauth/token")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.loginSource, "environment_override")
            }
        }
    }

    func testPrepareAnthropicOAuthLoginUsesClientMetadataWhenAvailable() async throws {
        let metadata = Self.makeAnthropicOAuthMetadataApplication(
            authorizeURL: "http://127.0.0.1:8787/cai/oauth/authorize",
            tokenURL: "http://127.0.0.1:8787/v1/oauth/token",
            clientID: "metadata-client-id",
            requestedScope: "user:profile user:inference user:mcp_servers",
            betaHeader: "oauth-test-beta",
            apiBaseURL: "http://127.0.0.1:8787"
        )

        try await metadata.test(.ahc()) { metadataClient in
            try await Self.withEnvironment([
                "CLAUDE_CODE_CLIENT_METADATA_URL": "http://localhost:\(metadataClient.port ?? 0)/oauth/claude-code-client-metadata",
            ]) {
                let (pending, prepared) = try await AnthropicAuthService.prepareOAuthLogin(
                    callbackPort: 1455,
                    config: AppConfig()
                )
                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems: [URLQueryItem] = components.queryItems ?? []
                let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

                XCTAssertTrue(prepared.authURL.contains("http://127.0.0.1:8787/cai/oauth/authorize"))
                XCTAssertEqual(items["client_id"], "metadata-client-id")
                XCTAssertEqual(items["scope"], "user:profile user:inference user:mcp_servers")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.authorizeURL, "http://127.0.0.1:8787/cai/oauth/authorize")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.tokenURL, "http://127.0.0.1:8787/v1/oauth/token")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.requestedScope, "user:profile user:inference user:mcp_servers")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.betaHeader, "oauth-test-beta")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.apiBaseURL, "http://127.0.0.1:8787")
                XCTAssertEqual(pending.anthropicOAuthConfigSnapshot?.loginSource, "client_metadata")
            }
        }
    }

    func testAnthropicAuthorizationCodeTokenRequestBodyUsesJSONShape() throws {
        let pending = PendingOAuthLogin(
            providerFamily: .anthropic,
            redirectURI: "http://localhost:1455/callback",
            state: "state-123",
            codeVerifier: "verifier-123",
            expiresAt: Helpers.now() + 120
        )

        let body = try AnthropicAuthService.authorizationCodeTokenRequestBody(
            pending: pending,
            code: "code-123",
            clientID: AnthropicAuthService.defaultClientID
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(AnthropicAuthService.tokenRequestHeaders()["Content-Type"], "application/json")
        XCTAssertEqual(payload["grant_type"], "authorization_code")
        XCTAssertEqual(payload["code"], "code-123")
        XCTAssertEqual(payload["redirect_uri"], pending.redirectURI)
        XCTAssertEqual(payload["client_id"], AnthropicAuthService.defaultClientID)
        XCTAssertEqual(payload["code_verifier"], pending.codeVerifier)
        XCTAssertEqual(payload["state"], pending.state)
    }

    func testAnthropicRefreshTokenRequestBodyUsesJSONShape() throws {
        let body = try AnthropicAuthService.refreshTokenRequestBody(
            refreshToken: "refresh-123",
            clientID: AnthropicAuthService.defaultClientID,
            scope: "user:profile user:inference"
        )
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(AnthropicAuthService.tokenRequestHeaders()["Content-Type"], "application/json")
        XCTAssertEqual(payload["grant_type"], "refresh_token")
        XCTAssertEqual(payload["refresh_token"], "refresh-123")
        XCTAssertEqual(payload["client_id"], AnthropicAuthService.defaultClientID)
        XCTAssertEqual(payload["scope"], "user:profile user:inference")
    }

    func testCompleteAnthropicOAuthCallbackReusesPendingSnapshotInsteadOfReResolvingConfig() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let provider = Self.makeAnthropicOAuthTokenApplication()

        try await provider.test(.ahc()) { upstreamClient in
            let tokenURL = "http://localhost:\(upstreamClient.port ?? 0)/v1/oauth/token"
            let pending = PendingOAuthLogin(
                providerFamily: .anthropic,
                redirectURI: "http://localhost:1455/callback",
                state: "state-123",
                codeVerifier: "verifier-123",
                expiresAt: Helpers.now() + 120,
                anthropicOAuthConfigSnapshot: AnthropicAuthService.OAuthConfigSnapshot(
                    clientID: "pending-client-id",
                    authorizeURL: "https://claude.com/cai/oauth/authorize",
                    tokenURL: tokenURL,
                    requestedScope: "user:profile user:inference",
                    betaHeader: "oauth-test-beta",
                    apiBaseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                    loginSource: "client_metadata"
                )
            )

            try await Self.withEnvironment([
                "CLAUDE_CODE_TOKEN_URL": "http://127.0.0.1:9/should-not-be-used",
                "CLAUDE_CODE_OAUTH_CLIENT_ID": "env-client-id",
            ]) {
                let completed = try await AnthropicAuthService.completeOAuthCallback(
                    pending: pending,
                    callbackURL: "http://localhost:1455/callback?code=good-code&state=state-123",
                    config: AppConfig(),
                    secretStore: secretStore
                )
                let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(completed.utf8)) as? [String: Any])

                XCTAssertEqual(payload["oauth_client_id"] as? String, "pending-client-id")
                XCTAssertEqual(payload["oauth_token_url"] as? String, tokenURL)
                XCTAssertEqual(payload["oauth_authorize_url"] as? String, "https://claude.com/cai/oauth/authorize")
                XCTAssertEqual(payload["oauth_requested_scope"] as? String, "user:profile user:inference")
                XCTAssertEqual(payload["oauth_login_source"] as? String, "client_metadata")
            }
        }
    }

    func testAnthropicOAuthRefreshUsesRequestedScopeInsteadOfLegacyStoredScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let probe = AnthropicOAuthScopeProbe()
        let provider = Self.makeAnthropicOAuthTokenApplication(scopeProbe: probe)

        try await provider.test(.ahc()) { upstreamClient in
            let secretRef = try secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access-stale",
                    refreshToken: "anthropic-refresh-seed",
                    expiresAt: Helpers.now() - 60,
                    tokenType: "Bearer",
                    scope: "org:create_api_key user:profile"
                )
            )
            let authJSON = """
            {
              "auth_mode": "anthropic_subscription_oauth",
              "provider_family": "anthropic",
              "secret_ref": "\(secretRef)",
              "scope": "org:create_api_key user:profile",
              "oauth_requested_scope": "user:profile user:inference",
              "oauth_token_url": "http://localhost:\(upstreamClient.port ?? 0)/v1/oauth/token",
              "oauth_authorize_url": "https://claude.com/cai/oauth/authorize",
              "oauth_login_source": "claude_ai_subscription",
              "oauth_client_id": "test-client-id",
              "upstream_base_url": "https://api.anthropic.com"
            }
            """

            let refreshed = try await AnthropicAuthService.refreshAnthropicAuth(
                authJSON,
                config: AppConfig(),
                secretStore: secretStore
            )
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(refreshed.utf8)) as? [String: Any])
            let requestedScope = await probe.snapshot()

            XCTAssertEqual(requestedScope, "user:profile user:inference")
            XCTAssertEqual(payload["oauth_requested_scope"] as? String, "user:profile user:inference")
            XCTAssertEqual(payload["scope"] as? String, "user:profile user:inference")
        }
    }

    func testAnthropicOAuthRefreshRejectsLegacyScopeWithoutInferencePermission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let secretRef = try secretStore.saveAnthropicOAuthSecret(
            AnthropicOAuthSecretBundle(
                accessToken: "anthropic-access-stale",
                refreshToken: "anthropic-refresh-seed",
                expiresAt: Helpers.now() - 60,
                tokenType: "Bearer",
                scope: "org:create_api_key user:profile"
            )
        )
        let authJSON = """
        {
          "auth_mode": "anthropic_subscription_oauth",
          "provider_family": "anthropic",
          "secret_ref": "\(secretRef)",
          "scope": "org:create_api_key user:profile",
          "oauth_authorize_url": "\(AnthropicAuthService.defaultConsoleAuthorizeURL)",
          "oauth_client_id": "legacy-client-id",
          "oauth_token_url": "http://127.0.0.1:9/v1/oauth/token",
          "upstream_base_url": "https://api.anthropic.com"
        }
        """

        do {
            _ = try await AnthropicAuthService.refreshAnthropicAuth(
                authJSON,
                config: AppConfig(),
                secretStore: secretStore
            )
            XCTFail("Expected legacy OAuth refresh to require re-login")
        } catch {
            XCTAssertEqual(error.localizedDescription, AnthropicAuthService.reauthorizationRequiredMessage)
        }
    }

    func testDecodeOAuthBrowserErrorPayload() throws {
        let url = "https://auth.openai.com/error?payload=eyJraW5kIjogIkF1dGhBcGlGYWlsdXJlIiwgImVycm9yQ29kZSI6ICJ1bmtub3duX2Vycm9yIiwgInJlcXVlc3RJZCI6ICI0OGI4Y2JjZi0xZjk5LTRjMTktYTE5ZS1kOThlZDQzY2U0YzQifQ%3D%3D&session_id=test"
        let payload = try XCTUnwrap(AuthService.decodeOAuthErrorPayload(from: url))

        XCTAssertEqual(payload.kind, "AuthApiFailure")
        XCTAssertEqual(payload.errorCode, "unknown_error")
        XCTAssertEqual(payload.requestId, "48b8cbcf-1f99-4c19-a19e-d98ed43ce4c4")
    }

    func testOAuthCallbackListenerFallsBackWhenPreferredPortBusy() async throws {
        let occupied = try OAuthCallbackListener.bind(preferredPort: AuthService.defaultOAuthRedirectPort)
        let fallback = try OAuthCallbackListener.bind(preferredPort: AuthService.defaultOAuthRedirectPort)

        XCTAssertEqual(occupied.port, AuthService.defaultOAuthRedirectPort)
        XCTAssertNotEqual(fallback.port, AuthService.defaultOAuthRedirectPort)

        await fallback.stop()
        await occupied.stop()
    }

    func testOAuthCallbackPageRendererPrefersChineseAcceptLanguageAndFallsBackToEnglish() {
        XCTAssertEqual(
            OAuthCallbackPageRenderer.preferredLanguage(fromAcceptLanguage: "zh-CN,zh;q=0.9,en;q=0.8"),
            .zhHans
        )
        XCTAssertEqual(
            OAuthCallbackPageRenderer.preferredLanguage(fromAcceptLanguage: "en-US,en;q=0.9"),
            .english
        )
        XCTAssertEqual(
            OAuthCallbackPageRenderer.preferredLanguage(fromAcceptLanguage: nil),
            .english
        )
    }

    func testOAuthCallbackPageRendererRendersSuccessAndFailureDetails() {
        let success = OAuthCallbackPageRenderer.success(accountLabel: "OAuth", preferredLanguage: .zhHans)
        let successHTML = OAuthCallbackPageRenderer.renderHTML(success)
        XCTAssertTrue(successHTML.contains("授权完成"))
        XCTAssertTrue(successHTML.contains("OAuth"))
        XCTAssertTrue(successHTML.contains("现在可以关闭此页面"))

        let failure = OAuthCallbackPageRenderer.failure(
            detail: "OAuth callback 缺少 code",
            preferredLanguage: .english
        )
        let failureHTML = OAuthCallbackPageRenderer.renderHTML(failure)
        XCTAssertTrue(failureHTML.contains("Authorization Failed"))
        XCTAssertTrue(failureHTML.contains("OAuth callback 缺少 code"))
        XCTAssertTrue(failureHTML.contains("Details"))
        XCTAssertTrue(failureHTML.contains("paste the full callback URL"))
    }

    func testOAuthCallbackListenerServesLocalizedSuccessPage() async throws {
        let listener = try OAuthCallbackListener.bind(preferredPort: 0)

        listener.start(
            expiresAt: Helpers.now() + 30,
            onCallback: { callbackURL, preferredLanguage in
                XCTAssertTrue(callbackURL.contains("/auth/callback?code=test-code"))
                XCTAssertEqual(preferredLanguage, .zhHans)
                return OAuthCallbackPageRenderer.success(
                    accountLabel: "OAuth",
                    preferredLanguage: preferredLanguage
                )
            },
            onTimeout: {}
        )
        try? await Task.sleep(for: .milliseconds(120))

        let (statusCode, html) = try await Self.fetchLocalHTML(
            from: "http://127.0.0.1:\(listener.port)/auth/callback?code=test-code&state=test-state",
            acceptLanguage: "zh-CN,zh;q=0.9"
        )
        await listener.stop()

        XCTAssertEqual(statusCode, 200)
        XCTAssertTrue(html.contains("授权完成"))
        XCTAssertTrue(html.contains("已导入账号"))
        XCTAssertTrue(html.contains("OAuth"))
        XCTAssertTrue(html.contains("AI Coding Proxy"))
    }

    func testOAuthCallbackListenerAcceptsLegacyCallbackPathAlias() async throws {
        let listener = try OAuthCallbackListener.bind(preferredPort: 0)

        listener.start(
            expiresAt: Helpers.now() + 30,
            onCallback: { callbackURL, preferredLanguage in
                XCTAssertTrue(callbackURL.contains("/callback?code=legacy-code"))
                XCTAssertEqual(preferredLanguage, .english)
                return OAuthCallbackPageRenderer.success(
                    accountLabel: "Legacy OAuth",
                    preferredLanguage: preferredLanguage
                )
            },
            onTimeout: {}
        )
        try? await Task.sleep(for: .milliseconds(120))

        let (statusCode, html) = try await Self.fetchLocalHTML(
            from: "http://127.0.0.1:\(listener.port)/callback?code=legacy-code&state=test-state",
            acceptLanguage: "en-US,en;q=0.9"
        )
        await listener.stop()

        XCTAssertEqual(statusCode, 200)
        XCTAssertTrue(html.contains("Authorization Completed"))
        XCTAssertTrue(html.contains("Legacy OAuth"))
    }

    func testOAuthCallbackListenerServesInvalidPathPageWithoutBlankResponse() async throws {
        let listener = try OAuthCallbackListener.bind(preferredPort: 0)

        listener.start(
            expiresAt: Helpers.now() + 30,
            onCallback: { _, preferredLanguage in
                XCTFail("Unexpected callback for invalid path")
                return OAuthCallbackPageRenderer.failure(detail: "unexpected", preferredLanguage: preferredLanguage)
            },
            onTimeout: {}
        )
        try? await Task.sleep(for: .milliseconds(120))

        let (statusCode, html) = try await Self.fetchLocalHTML(
            from: "http://127.0.0.1:\(listener.port)/not-codex",
            acceptLanguage: "en-US,en;q=0.9"
        )
        await listener.stop()

        XCTAssertEqual(statusCode, 404)
        XCTAssertTrue(html.contains("Unrecognized Callback Address"))
        XCTAssertTrue(html.contains("AI Coding Proxy"))
        XCTAssertFalse(html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testCompleteOAuthCallbackReportsOAuthErrorsFromRelativeCallbackURL() async {
        let pending = PendingOAuthLogin(
            redirectURI: "http://localhost:1455/auth/callback",
            state: "state-123",
            codeVerifier: "verifier-123",
            expiresAt: Helpers.now() + 120
        )

        do {
            _ = try await AuthService.completeOAuthCallback(
                pending: pending,
                callbackURL: "/auth/callback?error=access_denied&error_description=User%20cancelled&state=state-123",
                config: AppConfig()
            )
            XCTFail("Expected OAuth callback parsing to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("User cancelled"))
        }
    }

    func testAccountRankingPrefersFreeThenRemainingUsage() {
        let paid = AccountRecord(
            label: "Paid",
            principalID: "p1",
            email: nil,
            accountID: "a1",
            planType: "plus",
            authJSON: "{}",
            usage: UsageSnapshot(planType: "plus", fiveHour: UsageWindow(usedPercent: 20, windowSeconds: 18_000, resetAt: nil), oneWeek: UsageWindow(usedPercent: 10, windowSeconds: 604_800, resetAt: nil), credits: nil)
        )
        let free = AccountRecord(
            label: "Free",
            principalID: "p2",
            email: nil,
            accountID: "a2",
            planType: "free",
            authJSON: "{}",
            usage: UsageSnapshot(planType: "free", fiveHour: UsageWindow(usedPercent: 50, windowSeconds: 18_000, resetAt: nil), oneWeek: UsageWindow(usedPercent: 50, windowSeconds: 604_800, resetAt: nil), credits: nil)
        )
        let ranked = AccountRanking.sort([paid, free])
        XCTAssertEqual(ranked.first?.label, "Free")
    }

    func testAccountRankingUsesEffectivePlanTypeWhenStoredPlanIsStale() {
        let staleFreeButPlus = AccountRecord(
            label: "Actually Plus",
            principalID: "p1",
            email: nil,
            accountID: "a1",
            planType: "free",
            authJSON: "{}",
            usage: UsageSnapshot(
                planType: "plus",
                fiveHour: UsageWindow(usedPercent: 20, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 10, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            )
        )
        let realFree = AccountRecord(
            label: "Real Free",
            principalID: "p2",
            email: nil,
            accountID: "a2",
            planType: "free",
            authJSON: "{}",
            usage: UsageSnapshot(
                planType: "free",
                fiveHour: UsageWindow(usedPercent: 50, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 50, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            )
        )

        let ranked = AccountRanking.sort([staleFreeButPlus, realFree])

        XCTAssertEqual(ranked.first?.label, "Real Free")
    }

    func testUsageLimitReachedSignalParsesStructuredErrorPayload() {
        let payload = #"""
        {
          "error": {
            "type": "usage_limit_reached",
            "message": "The usage limit has been reached",
            "plan_type": "free",
            "resets_at": 1776674887
          }
        }
        """#

        let signal = UsageLimitReachedSignal.parse(from: payload)

        XCTAssertEqual(signal?.type, "usage_limit_reached")
        XCTAssertEqual(signal?.planType, "free")
        XCTAssertEqual(signal?.resetsAt, 1776674887)
        XCTAssertEqual(
            signal?.normalizedUsageError,
            "usage_limit_reached, plan=free, resets_at=\(FixedDisplayDateTimeFormat.string(fromUnixSeconds: 1776674887))"
        )
    }

    func testUsageLimitWindowSupportPrefersExistingWindowWhoseResetMatches() {
        let signal = UsageLimitReachedSignal(
            type: "usage_limit_reached",
            message: "The usage limit has been reached",
            planType: "free",
            resetsAt: 1776674887
        )
        let usage = UsageSnapshot(
            fetchedAt: 1,
            planType: "free",
            fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: 1776000000),
            oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: 1776674800),
            credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "5")
        )

        let updated = UsageLimitWindowSupport.usageByApplyingLimit(
            signal,
            to: usage,
            fallbackPlanType: "free",
            now: 1776500000
        )

        XCTAssertEqual(updated.oneWeek?.usedPercent, 100)
        XCTAssertEqual(updated.oneWeek?.resetAt, 1776674887)
        XCTAssertEqual(updated.fiveHour?.usedPercent, 25)
        XCTAssertEqual(updated.credits?.balance, "5")
    }

    func testUsageLimitWindowSupportFallsBackToNearestWindowByResetDistance() {
        let signal = UsageLimitReachedSignal(
            type: "usage_limit_reached",
            message: "The usage limit has been reached",
            planType: "free",
            resetsAt: 1776518000
        )

        let updated = UsageLimitWindowSupport.usageByApplyingLimit(
            signal,
            to: nil,
            fallbackPlanType: "free",
            now: 1776500000
        )

        XCTAssertEqual(updated.fiveHour?.usedPercent, 100)
        XCTAssertEqual(updated.fiveHour?.resetAt, 1776518000)
        XCTAssertNil(updated.oneWeek)
    }

    func testUsageLimitWindowSupportBlocksUntilResetThenRecovers() {
        let usage = UsageSnapshot(
            fetchedAt: 1,
            planType: "free",
            fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: 1776518000),
            oneWeek: nil,
            credits: nil
        )

        XCTAssertTrue(UsageLimitWindowSupport.isBlocked(usage, now: 1776500000))
        XCTAssertEqual(UsageLimitWindowSupport.blockedUntil(in: usage, now: 1776500000), 1776518000)
        XCTAssertEqual(UsageLimitWindowSupport.effectiveRemainingPercent(for: usage.fiveHour, now: 1776500000), -1)

        XCTAssertFalse(UsageLimitWindowSupport.isBlocked(usage, now: 1776518000))
        XCTAssertNil(UsageLimitWindowSupport.blockedUntil(in: usage, now: 1776518000))
        XCTAssertEqual(UsageLimitWindowSupport.effectiveRemainingPercent(for: usage.fiveHour, now: 1776518000), 100)
    }

    func testChatRequestConversionMapsToCodexResponses() throws {
        let payload: [String: Any] = [
            "model": "gpt-5-4",
            "messages": [
                ["role": "system", "content": "You are helpful"],
                ["role": "user", "content": "Hello"],
            ],
            "stream": false,
        ]
        let converted = try ProxyTranscoder.convertChatCompletionsRequest(payload)
        XCTAssertEqual(converted.model, "gpt-5.4")
        XCTAssertEqual(converted.downstreamStream, false)
        XCTAssertEqual((converted.request["stream"] as? Bool), true)
        XCTAssertEqual((converted.request["instructions"] as? String), "")
        XCTAssertEqual((converted.request["input"] as? [[String: Any]])?.count, 2)
    }

    func testChatRequestConversionAllowsCustomModelPassthroughForProxyTest() throws {
        let payload: [String: Any] = [
            "model": "qwen3.6-plus",
            "messages": [
                ["role": "user", "content": "Hello"],
            ],
        ]

        let converted = try ProxyTranscoder.convertChatCompletionsRequest(
            payload,
            allowCustomModelPassthrough: true
        )

        XCTAssertEqual(converted.model, "qwen3.6-plus")
        XCTAssertEqual(converted.request["model"] as? String, "qwen3.6-plus")
    }

    func testChatRequestConversionAllowsFutureModelWithoutPassthrough() throws {
        let payload: [String: Any] = [
            "model": "gpt-6",
            "messages": [
                ["role": "user", "content": "Hello"],
            ],
        ]

        let converted = try ProxyTranscoder.convertChatCompletionsRequest(payload)

        XCTAssertEqual(converted.model, "gpt-6")
        XCTAssertEqual(converted.request["model"] as? String, "gpt-6")
        XCTAssertFalse(ProxyTranscoder.isSupportedClientModel("gpt-6"))
    }

    func testChatRequestConversionPassthroughStillNormalizesKnownAlias() throws {
        let payload: [String: Any] = [
            "model": "gpt-5-4",
            "messages": [
                ["role": "user", "content": "Hello"],
            ],
        ]

        let converted = try ProxyTranscoder.convertChatCompletionsRequest(
            payload,
            allowCustomModelPassthrough: true
        )

        XCTAssertEqual(converted.model, "gpt-5.4")
        XCTAssertEqual(converted.request["model"] as? String, "gpt-5.4")
    }

    func testChatRequestConversionMapsAssistantHistoryTextToOutputText() throws {
        let payload: [String: Any] = [
            "model": "gpt-5.4",
            "messages": [
                ["role": "user", "content": "First question"],
                ["role": "assistant", "content": "First answer"],
                ["role": "user", "content": "Second question"],
            ],
        ]

        let converted = try ProxyTranscoder.convertChatCompletionsRequest(payload)
        let input = try XCTUnwrap(converted.request["input"] as? [[String: Any]])
        let assistantMessage = input[1]
        let content = try XCTUnwrap(assistantMessage["content"] as? [[String: Any]])

        XCTAssertEqual(assistantMessage["role"] as? String, "assistant")
        XCTAssertEqual(content.first?["type"] as? String, "output_text")
        XCTAssertEqual(content.first?["text"] as? String, "First answer")
    }

    func testChatRequestConversionPreservesAssistantReasoningContent() throws {
        let payload: [String: Any] = [
            "model": "gpt-5.4",
            "messages": [
                ["role": "user", "content": "First question"],
                [
                    "role": "assistant",
                    "content": "First answer",
                    "reasoning_content": "internal trace",
                ],
                ["role": "user", "content": "Second question"],
            ],
        ]

        let converted = try ProxyTranscoder.convertChatCompletionsRequest(payload)
        let upstream = ProxyTranscoder.upstreamChatCompletionsRequest(
            from: converted.request,
            upstreamModel: "deepseek-reasoner",
            stream: false
        )
        let messages = try XCTUnwrap(upstream["messages"] as? [[String: Any]])
        let assistantMessage = try XCTUnwrap(messages.first(where: {
            ($0["role"] as? String) == "assistant"
        }))

        XCTAssertEqual(assistantMessage["content"] as? String, "First answer")
        XCTAssertEqual(assistantMessage["reasoning_content"] as? String, "internal trace")
    }

    func testChatRequestConversionPreservesAssistantToolCallsAndReasoningContent() throws {
        let payload: [String: Any] = [
            "model": "gpt-5.4",
            "messages": [
                ["role": "user", "content": "Inspect"],
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "reasoning_content": "tool-call thinking",
                    "tool_calls": [[
                        "id": "call_cli_tool",
                        "type": "function",
                        "function": [
                            "name": "run_command",
                            "arguments": "{\"command\":\"pwd\"}",
                        ],
                    ]],
                ],
                [
                    "role": "tool",
                    "tool_call_id": "call_cli_tool",
                    "content": "/tmp/project",
                ],
            ],
        ]

        let converted = try ProxyTranscoder.convertChatCompletionsRequest(payload)
        let upstream = ProxyTranscoder.upstreamChatCompletionsRequest(
            from: converted.request,
            upstreamModel: "deepseek-chat",
            stream: false
        )
        let messages = try XCTUnwrap(upstream["messages"] as? [[String: Any]])
        let assistantMessage = try XCTUnwrap(messages.first(where: {
            ($0["role"] as? String) == "assistant" && ($0["tool_calls"] as? [[String: Any]]) != nil
        }))

        XCTAssertEqual(assistantMessage["reasoning_content"] as? String, "tool-call thinking")
        let toolCalls = try XCTUnwrap(assistantMessage["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call_cli_tool")
        XCTAssertEqual((toolCalls.first?["function"] as? [String: Any])?["name"] as? String, "run_command")
        XCTAssertEqual((toolCalls.first?["function"] as? [String: Any])?["arguments"] as? String, "{\"command\":\"pwd\"}")
    }

    func testCompletedChatCompletionPreservesReasoningContentForRoundTrip() throws {
        let payload: [String: Any] = [
            "id": "chatcmpl_reasoning",
            "created": 1_710_000_000,
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "Ready",
                    "reasoning_content": "deepseek thinking",
                ],
            ]],
            "usage": [
                "prompt_tokens": 2,
                "completion_tokens": 3,
                "total_tokens": 5,
            ],
        ]

        let completed = ProxyTranscoder.completedResponse(
            fromChatCompletion: payload,
            requestedModel: "deepseek-reasoner"
        )
        let output = try XCTUnwrap(completed["output"] as? [[String: Any]])
        let message = try XCTUnwrap(output.first(where: { ($0["type"] as? String) == "message" }))

        XCTAssertEqual(message["reasoning_content"] as? String, "deepseek thinking")
        XCTAssertEqual(ProxyTranscoder.extractAssistantText(from: completed), "Ready")

        XCTAssertNil(ProxyTranscoder.chatCompletionAssistantReasoningCachePair(fromCompletedResponse: completed))

        let chatCompletion = ProxyTranscoder.chatCompletionFromCompletedResponse(
            completedResponse: completed,
            requestedModel: "deepseek-reasoner"
        )
        let choice = try XCTUnwrap((chatCompletion["choices"] as? [[String: Any]])?.first)
        let chatMessage = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(chatMessage["reasoning_content"] as? String, "deepseek thinking")
    }

    func testToolCallChatCompletionReasoningContentProducesCachePair() throws {
        let payload: [String: Any] = [
            "id": "chatcmpl_reasoning_tool",
            "created": 1_710_000_000,
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "",
                    "reasoning_content": "deepseek tool thinking",
                    "tool_calls": [[
                        "id": "call_cli_tool",
                        "type": "function",
                        "function": [
                            "name": "run_command",
                            "arguments": "{\"command\":\"pwd\"}",
                        ],
                    ]],
                ],
            ]],
            "usage": [
                "prompt_tokens": 2,
                "completion_tokens": 3,
                "total_tokens": 5,
            ],
        ]

        let completed = ProxyTranscoder.completedResponse(
            fromChatCompletion: payload,
            requestedModel: "deepseek-reasoner"
        )
        let pair = try XCTUnwrap(
            ProxyTranscoder.chatCompletionAssistantReasoningCachePair(fromCompletedResponse: completed)
        )

        XCTAssertEqual(pair.reasoningContent, "deepseek tool thinking")
    }

    func testToolCallChatCompletionFingerprintTreatsNilAndEmptyContentAsEquivalent() throws {
        let toolCalls: [[String: Any]] = [[
            "id": "call_cli_tool",
            "type": "function",
            "function": [
                "name": "run_command",
                "arguments": "{\"command\":\"pwd\"}",
            ],
        ]]
        let empty = try XCTUnwrap(ProxyTranscoder.chatCompletionAssistantToolCallMessageFingerprint([
            "role": "assistant",
            "content": "",
            "tool_calls": toolCalls,
        ]))
        let null = try XCTUnwrap(ProxyTranscoder.chatCompletionAssistantToolCallMessageFingerprint([
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": toolCalls,
        ]))
        let missing = try XCTUnwrap(ProxyTranscoder.chatCompletionAssistantToolCallMessageFingerprint([
            "role": "assistant",
            "tool_calls": toolCalls,
        ]))

        XCTAssertEqual(empty, null)
        XCTAssertEqual(empty, missing)
    }

    func testChatCompletionsReasoningContentCachePersistsAndPrunesExpiredEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ChatCompletionsReasoningContentCache(
            dataDirectory: directory,
            retentionSeconds: 10,
            now: 100
        )
        await cache.store(
            reasoningContent: " tool-call thinking ",
            sessionKeyHash: "session-hash",
            accountKey: "account-key",
            model: "deepseek-chat",
            assistantFingerprint: "assistant-fingerprint",
            now: 100
        )

        let cachedReasoningContent = await cache.reasoningContent(
            sessionKeyHash: "session-hash",
            accountKey: "account-key",
            model: "deepseek-chat",
            assistantFingerprint: "assistant-fingerprint",
            now: 105
        )
        XCTAssertEqual(cachedReasoningContent, "tool-call thinking")

        let reloaded = ChatCompletionsReasoningContentCache(
            dataDirectory: directory,
            retentionSeconds: 10,
            now: 105
        )
        let reloadedReasoningContent = await reloaded.reasoningContent(
            sessionKeyHash: "session-hash",
            accountKey: "account-key",
            model: "deepseek-chat",
            assistantFingerprint: "assistant-fingerprint",
            now: 105
        )
        XCTAssertEqual(reloadedReasoningContent, "tool-call thinking")
        let expiredReasoningContent = await reloaded.reasoningContent(
            sessionKeyHash: "session-hash",
            accountKey: "account-key",
            model: "deepseek-chat",
            assistantFingerprint: "assistant-fingerprint",
            now: 111
        )
        XCTAssertNil(expiredReasoningContent)

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: Paths.chatCompletionsReasoningContentCacheURL(in: directory).path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
    }

    func testStreamingChatCompletionAccumulatesReasoningContent() throws {
        var state = OpenAIChatSyntheticStreamState()
        let events: [SSEEvent] = [
            .init(event: nil, data: #"{"id":"chatcmpl_stream","created":1710000000,"choices":[{"delta":{"role":"assistant"}}]}"#),
            .init(event: nil, data: #"{"choices":[{"delta":{"reasoning_content":"think "}}]}"#),
            .init(event: nil, data: #"{"choices":[{"delta":{"reasoning_content":"more"}}]}"#),
            .init(event: nil, data: #"{"choices":[{"delta":{"content":"Ready"}}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5,"prompt_cache_hit_tokens":1}}"#),
        ]

        _ = try events.flatMap { event in
            try ProxyTranscoder.responseSSEChunks(
                fromChatCompletionEvent: event,
                state: &state,
                requestedModel: "deepseek-reasoner"
            )
        }
        let completed = ProxyTranscoder.completedResponse(
            fromChatCompletionState: state,
            requestedModel: "deepseek-reasoner"
        )
        let output = try XCTUnwrap(completed["output"] as? [[String: Any]])
        let message = try XCTUnwrap(output.first(where: { ($0["type"] as? String) == "message" }))

        XCTAssertEqual(message["reasoning_content"] as? String, "think more")
        XCTAssertEqual(ProxyTranscoder.extractAssistantText(from: completed), "Ready")
        let usage = ProxyTranscoder.usageFromCompletedResponse(completed)
        XCTAssertEqual(usage.cacheHitTokens, 1)
    }

    func testResponsesNormalizationInjectsCodexDefaults() throws {
        let payload: [String: Any] = [
            "model": "gpt-5.4",
            "input": "hello",
            "metadata": ["source": "test"],
        ]

        let normalized = try ProxyTranscoder.normalizeResponsesRequest(payload)

        XCTAssertEqual((normalized["stream"] as? Bool), true)
        XCTAssertEqual((normalized["store"] as? Bool), false)
        XCTAssertEqual((normalized["instructions"] as? String), "")
        XCTAssertEqual((normalized["parallel_tool_calls"] as? Bool), true)
        XCTAssertEqual((normalized["include"] as? [String]) ?? [], ["reasoning.encrypted_content"])
        XCTAssertEqual((normalized["reasoning"] as? [String: String])?["effort"], "medium")
        XCTAssertEqual((normalized["reasoning"] as? [String: String])?["summary"], "auto")
        let input = try XCTUnwrap(normalized["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "hello")
        XCTAssertNil(normalized["metadata"])
    }

    func testResponsesNormalizationAllowsCustomModelPassthroughForProxyTest() throws {
        let payload: [String: Any] = [
            "model": "qwen3.6-plus",
            "input": "hello",
        ]

        let normalized = try ProxyTranscoder.normalizeResponsesRequest(
            payload,
            allowCustomModelPassthrough: true
        )

        XCTAssertEqual(normalized["model"] as? String, "qwen3.6-plus")
    }

    func testResponsesNormalizationAllowsFutureModelWithoutPassthrough() throws {
        let payload: [String: Any] = [
            "model": "qwen3.6-plus",
            "input": "hello",
        ]

        let normalized = try ProxyTranscoder.normalizeResponsesRequest(payload)

        XCTAssertEqual(normalized["model"] as? String, "qwen3.6-plus")
        XCTAssertFalse(ProxyTranscoder.isSupportedClientModel("qwen3.6-plus"))
    }

    func testResponsesNormalizationRejectsBlankModel() {
        let payload: [String: Any] = [
            "model": "  ",
            "input": "hello",
        ]

        XCTAssertThrowsError(try ProxyTranscoder.normalizeResponsesRequest(payload)) { error in
            XCTAssertEqual(error.localizedDescription, "不支持的模型   ")
        }
    }

    func testResponsesNormalizationMapsAssistantHistoryTextToOutputText() throws {
        let payload: [String: Any] = [
            "model": "gpt-5.4",
            "input": [
                ["role": "user", "content": "First question"],
                ["role": "assistant", "content": [["type": "text", "text": "First answer"]]],
                ["role": "user", "content": "Second question"],
            ],
        ]

        let normalized = try ProxyTranscoder.normalizeResponsesRequest(payload)
        let input = try XCTUnwrap(normalized["input"] as? [[String: Any]])
        let assistantMessage = input[1]
        let content = try XCTUnwrap(assistantMessage["content"] as? [[String: Any]])

        XCTAssertEqual(assistantMessage["role"] as? String, "assistant")
        XCTAssertEqual(content.first?["type"] as? String, "output_text")
        XCTAssertEqual(content.first?["text"] as? String, "First answer")
    }

    func testUpstreamChatCompletionsRequestDropsTrailingOrphanFunctionCall() throws {
        let normalizedRequest: [String: Any] = [
            "model": "gpt-5.4",
            "instructions": "",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Inspect the repo"]],
                ],
                [
                    "type": "function_call",
                    "call_id": "call_closed",
                    "name": "list_directory",
                    "arguments": #"{"dir_path":"."}"#,
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_closed",
                    "output": #"{"entries":[]}"#,
                ],
                [
                    "type": "function_call",
                    "call_id": "call_orphan",
                    "name": "codebase_investigator",
                    "arguments": #"{}"#,
                ],
            ],
        ]

        let upstream = ProxyTranscoder.upstreamChatCompletionsRequest(
            from: normalizedRequest,
            upstreamModel: "gpt-5.4",
            stream: false
        )

        let messages = try XCTUnwrap(upstream["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[2]["role"] as? String, "tool")

        let toolCalls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call_closed")
        XCTAssertFalse(
            messages.contains(where: { ($0["tool_call_id"] as? String) == "call_orphan" })
        )
        XCTAssertFalse(
            messages.contains(where: {
                let toolCalls = $0["tool_calls"] as? [[String: Any]] ?? []
                return toolCalls.contains(where: { ($0["id"] as? String) == "call_orphan" })
            })
        )
    }

    func testAnthropicMessagesNormalizationMapsTextToolsAndModelAliases() throws {
        let payload: [String: Any] = [
            "model": "claude-3-5-haiku-latest",
            "system": "You are helpful",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "List files"],
                    ],
                ],
                [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use",
                            "id": "toolu_123",
                            "name": "run_command",
                            "input": ["command": "ls"],
                        ],
                    ],
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": "toolu_123",
                            "content": "README.md",
                        ],
                    ],
                ],
            ],
            "tools": [
                [
                    "name": "run_command",
                    "description": "Execute a shell command",
                    "input_schema": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string"],
                        ],
                    ],
                ],
            ],
            "tool_choice": [
                "type": "tool",
                "name": "run_command",
            ],
            "thinking": [
                "budget_tokens": 512,
            ],
            "max_tokens": 256,
            "stream": false,
        ]

        let normalized = try AnthropicTranscoder.normalizeMessagesRequest(payload)

        XCTAssertEqual(normalized.responseModel, "claude-3-5-haiku-latest")
        XCTAssertFalse(normalized.downstreamStream)
        XCTAssertEqual(normalized.request["instructions"] as? String, "You are helpful")
        XCTAssertEqual(normalized.request["max_output_tokens"] as? Int, 256)
        XCTAssertNil(normalized.request["model"])
        XCTAssertEqual((normalized.request["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(normalized.request["tool_choice"] as? [String: String], [
            "type": "function",
            "name": "run_command",
        ])

        let input = try XCTUnwrap(normalized.request["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[1]["type"] as? String, "function_call")
        XCTAssertEqual(input[1]["call_id"] as? String, "toolu_123")
        XCTAssertEqual(input[2]["type"] as? String, "function_call_output")

        let tools = try XCTUnwrap(normalized.request["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "run_command")
        XCTAssertEqual(tools.first?["type"] as? String, "function")
    }

    func testAnthropicMessagesNormalizationMapsAssistantHistoryTextToOutputText() throws {
        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "messages": [
                ["role": "user", "content": "First question"],
                ["role": "assistant", "content": "First answer"],
                ["role": "user", "content": "Second question"],
            ],
            "stream": false,
        ]

        let normalized = try AnthropicTranscoder.normalizeMessagesRequest(payload)
        let input = try XCTUnwrap(normalized.request["input"] as? [[String: Any]])
        let assistantMessage = input[1]
        let content = try XCTUnwrap(assistantMessage["content"] as? [[String: Any]])

        XCTAssertEqual(assistantMessage["role"] as? String, "assistant")
        XCTAssertEqual(content.first?["type"] as? String, "output_text")
        XCTAssertEqual(content.first?["text"] as? String, "First answer")
    }

    func testAnthropicCountTokensNormalizationMapsAssistantHistoryTextToOutputText() throws {
        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "messages": [
                ["role": "user", "content": "First question"],
                ["role": "assistant", "content": [["type": "text", "text": "First answer"]]],
                ["role": "user", "content": "Second question"],
            ],
        ]

        let normalized = try AnthropicTranscoder.normalizeCountTokensRequest(payload)
        let input = try XCTUnwrap(normalized.request["input"] as? [[String: Any]])
        let assistantMessage = input[1]
        let content = try XCTUnwrap(assistantMessage["content"] as? [[String: Any]])

        XCTAssertEqual(content.first?["type"] as? String, "output_text")
        XCTAssertEqual(content.first?["text"] as? String, "First answer")
        XCTAssertEqual(normalized.request["max_output_tokens"] as? Int, 1)
    }

    func testAnthropicMessagesNormalizationSkipsAssistantThinkingHistoryBlocks() throws {
        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "messages": [
                ["role": "user", "content": "Need a command"],
                [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "internal"],
                        ["type": "text", "text": "I'll run a command."],
                        [
                            "type": "tool_use",
                            "id": "toolu_123",
                            "name": "run_command",
                            "input": ["command": "pwd"],
                        ],
                        ["type": "redacted_thinking", "data": "hidden"],
                    ],
                ],
                [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "drop me"],
                    ],
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": "toolu_123",
                            "content": "done",
                        ],
                    ],
                ],
            ],
        ]

        let normalized = try AnthropicTranscoder.normalizeMessagesRequest(payload)
        let input = try XCTUnwrap(normalized.request["input"] as? [[String: Any]])

        XCTAssertEqual(input.count, 4)
        let assistantMessage = input[1]
        let assistantContent = try XCTUnwrap(assistantMessage["content"] as? [[String: Any]])
        XCTAssertEqual(assistantMessage["role"] as? String, "assistant")
        XCTAssertEqual(assistantContent.count, 1)
        XCTAssertEqual(assistantContent[0]["type"] as? String, "output_text")
        XCTAssertEqual(assistantContent[0]["text"] as? String, "I'll run a command.")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["call_id"] as? String, "toolu_123")
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
    }

    func testAnthropicMessagesNormalizationRejectsUnsupportedBlockTypes() {
        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "image", "source": "ignored"],
                    ],
                ],
            ],
        ]

        XCTAssertThrowsError(try AnthropicTranscoder.normalizeMessagesRequest(payload)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported Anthropic content block"))
            XCTAssertTrue(error.localizedDescription.contains("$.messages[0].content[0]"))
        }
    }

    func testAnthropicAPIKeyUpstreamSanitizesUnsupportedThinkingBlocksForDashScopeOnly() throws {
        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "messages": [
                ["role": "user", "content": [["type": "text", "text": "hello"]]],
                [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "internal"],
                        ["type": "text", "text": "visible"],
                        ["type": "redacted_thinking", "data": "hidden"],
                    ],
                ],
                [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "drop me"],
                    ],
                ],
            ],
        ]

        let dashScopeSanitized = AnthropicAPIKeyUpstream.sanitizedRequestForUnsupportedThinkingContentBlocks(
            payload,
            baseURL: "https://dashscope.aliyuncs.com/apps/anthropic/v1"
        )
        let dashScopeMessages = try XCTUnwrap(dashScopeSanitized["messages"] as? [[String: Any]])
        XCTAssertEqual(dashScopeMessages.count, 2)
        let assistantContent = try XCTUnwrap(dashScopeMessages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.count, 1)
        XCTAssertEqual(assistantContent[0]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[0]["text"] as? String, "visible")

        let official = AnthropicAPIKeyUpstream.sanitizedRequestForUnsupportedThinkingContentBlocks(
            payload,
            baseURL: "https://api.anthropic.com/v1"
        )
        let officialMessages = try XCTUnwrap(official["messages"] as? [[String: Any]])
        XCTAssertEqual(officialMessages.count, 3)
        let officialAssistantContent = try XCTUnwrap(officialMessages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(officialAssistantContent.count, 3)
        XCTAssertEqual(officialAssistantContent[0]["type"] as? String, "thinking")
        XCTAssertEqual(officialAssistantContent[2]["type"] as? String, "redacted_thinking")
    }

    func testGeminiGenerateContentNormalizationMapsSystemToolsAndFunctionHistory() throws {
        let payload: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": "You are helpful"],
                ],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "First question"],
                    ],
                ],
                [
                    "role": "model",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call_gemini_123",
                                "name": "run_command",
                                "args": [
                                    "command": "ls",
                                ],
                            ],
                            "thoughtSignature": "sig_call_123",
                        ],
                    ],
                ],
                [
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call_gemini_123",
                                "name": "run_command",
                                "response": [
                                    "output": "file.txt",
                                ],
                            ],
                            "thoughtSignature": "sig_result_123",
                        ],
                    ],
                ],
                [
                    "role": "user",
                    "parts": [
                        ["text": "Second question"],
                    ],
                ],
            ],
            "tools": [
                [
                    "functionDeclarations": [
                        [
                            "name": "run_command",
                            "description": "Execute a shell command",
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "command": ["type": "string"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "toolConfig": [
                "functionCallingConfig": [
                    "mode": "ANY",
                    "allowedFunctionNames": ["run_command"],
                ],
            ],
            "generationConfig": [
                "temperature": 0.2,
                "topP": 0.9,
                "topK": 32,
                "maxOutputTokens": 256,
                "stopSequences": ["DONE"],
            ],
        ]

        let normalized = try GeminiTranscoder.normalizeGenerateContentRequest(
            payload,
            model: "models/gemini-2.5-flash"
        )

        XCTAssertEqual(normalized.responseModel, "gemini-2.5-flash")
        XCTAssertEqual(normalized.request["model"] as? String, "gemini-2.5-flash")
        XCTAssertEqual(normalized.request["instructions"] as? String, "You are helpful")
        XCTAssertEqual(normalized.request["max_output_tokens"] as? Int, 256)
        XCTAssertEqual(normalized.request["stop"] as? [String], ["DONE"])
        XCTAssertEqual(normalized.request["top_k"] as? Int, 32)
        XCTAssertEqual(normalized.request["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual((normalized.request["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(normalized.context.sourceModel, "gemini-2.5-flash")
        XCTAssertTrue(normalized.context.includeThoughts)
        XCTAssertTrue(normalized.context.allowsFunctionCalls)
        XCTAssertEqual(normalized.request["tool_choice"] as? [String: String], [
            "type": "function",
            "name": "run_command",
        ])

        let input = try XCTUnwrap(normalized.request["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 4)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[1]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[3]["type"] as? String, "message")
        XCTAssertEqual(input[1]["name"] as? String, "run_command")
        XCTAssertEqual(input[1]["call_id"] as? String, "call_gemini_123")
        XCTAssertEqual(input[2]["call_id"] as? String, "call_gemini_123")

        let tools = try XCTUnwrap(normalized.request["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "run_command")
    }

    func testGeminiGenerateContentNormalizationSkipsThoughtHistoryAndCapturesThinkingConfig() throws {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "Summarize the repo"],
                    ],
                ],
                [
                    "role": "model",
                    "parts": [
                        [
                            "text": "Internal scan result",
                            "thought": true,
                            "thoughtSignature": "sig_123",
                        ],
                        [
                            "text": "Visible summary",
                        ],
                    ],
                ],
            ],
            "generationConfig": [
                "thinkingConfig": [
                    "includeThoughts": false,
                    "thinkingBudget": 128,
                    "thinkingLevel": "minimal",
                ],
            ],
        ]

        let normalized = try GeminiTranscoder.normalizeGenerateContentRequest(
            payload,
            model: "gemini-2.5-flash"
        )

        XCTAssertFalse(normalized.context.includeThoughts)
        XCTAssertEqual(normalized.context.thinkingBudget, 128)
        XCTAssertEqual(normalized.context.thinkingLevel, "minimal")

        let input = try XCTUnwrap(normalized.request["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[1]["type"] as? String, "message")

        let assistantBlocks = try XCTUnwrap(input[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.count, 1)
        XCTAssertEqual(assistantBlocks[0]["text"] as? String, "Visible summary")
    }

    func testGeminiGenerateContentNormalizationRecordsRequiredToolParameters() throws {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "Inspect the repository"],
                    ],
                ],
            ],
            "tools": [
                [
                    "functionDeclarations": [
                        [
                            "name": "codebase_investigator",
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "objective": ["type": "string"],
                                ],
                                "required": ["objective"],
                            ],
                        ],
                        [
                            "name": "list_directory",
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "dir_path": ["type": "string"],
                                ],
                                "required": ["dir_path"],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let normalized = try GeminiTranscoder.normalizeGenerateContentRequest(
            payload,
            model: "gemini-2.5-flash"
        )

        XCTAssertEqual(
            normalized.context.toolSchemasByName["codebase_investigator"],
            GeminiToolSchemaContext(requiredParameterNames: ["objective"])
        )
        XCTAssertEqual(
            normalized.context.toolSchemasByName["list_directory"],
            GeminiToolSchemaContext(requiredParameterNames: ["dir_path"])
        )
    }

    func testGeminiGenerateContentNormalizationExtractsToolCorrectionHintsFromFunctionResponseErrors() throws {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "model",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call_objective",
                                "name": "codebase_investigator",
                                "args": [:],
                            ],
                        ],
                    ],
                ],
                [
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call_objective",
                                "name": "codebase_investigator",
                                "response": [
                                    "error": "params must have required property 'objective'",
                                ],
                            ],
                        ],
                    ],
                ],
                [
                    "role": "model",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call_dir_path",
                                "name": "list_directory",
                                "args": [:],
                            ],
                        ],
                    ],
                ],
                [
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call_dir_path",
                                "name": "list_directory",
                                "response": [
                                    "error": [
                                        "message": "must have required property 'dir_path'",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "tools": [
                [
                    "functionDeclarations": [
                        [
                            "name": "codebase_investigator",
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "objective": ["type": "string"],
                                ],
                                "required": ["objective"],
                            ],
                        ],
                        [
                            "name": "list_directory",
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "dir_path": ["type": "string"],
                                ],
                                "required": ["dir_path"],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let normalized = try GeminiTranscoder.normalizeGenerateContentRequest(
            payload,
            model: "gemini-2.5-flash"
        )

        XCTAssertTrue(
            normalized.context.toolCorrectionHints.contains(
                GeminiToolCorrectionHint(
                    toolName: "codebase_investigator",
                    missingRequiredParameter: "objective",
                    rawError: "params must have required property 'objective'"
                )
            )
        )
        XCTAssertTrue(
            normalized.context.toolCorrectionHints.contains(
                GeminiToolCorrectionHint(
                    toolName: "list_directory",
                    missingRequiredParameter: "dir_path",
                    rawError: "must have required property 'dir_path'"
                )
            )
        )
    }

    func testGeminiGenerateContentNormalizationDropsTrailingOrphanFunctionCall() throws {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "Inspect the repository"],
                    ],
                ],
                [
                    "role": "model",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call_closed",
                                "name": "list_directory",
                                "args": [
                                    "dir_path": ".",
                                ],
                            ],
                        ],
                    ],
                ],
                [
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call_closed",
                                "name": "list_directory",
                                "response": [
                                    "entries": [],
                                ],
                            ],
                        ],
                    ],
                ],
                [
                    "role": "model",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call_orphan",
                                "name": "codebase_investigator",
                                "args": [:],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let normalized = try GeminiTranscoder.normalizeGenerateContentRequest(
            payload,
            model: "gemini-2.5-flash"
        )

        let input = try XCTUnwrap(normalized.request["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[1]["type"] as? String, "function_call")
        XCTAssertEqual(input[1]["call_id"] as? String, "call_closed")
        XCTAssertEqual(input[2]["type"] as? String, "function_call_output")
        XCTAssertFalse(input.contains(where: { ($0["call_id"] as? String) == "call_orphan" }))
    }

    func testGeminiGenerateContentNormalizationRejectsFunctionResponseWithoutIDOrMatchingCall() {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "name": "run_command",
                                "response": [
                                    "output": "file.txt",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        XCTAssertThrowsError(
            try GeminiTranscoder.normalizeGenerateContentRequest(payload, model: "gemini-2.5-flash")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("functionResponse"))
            XCTAssertTrue(error.localizedDescription.contains("missing `id`"))
        }
    }

    func testGeminiGenerateContentNormalizationRejectsUnsupportedMultimodalParts() {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": "image/png",
                                "data": "ignored",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        XCTAssertThrowsError(
            try GeminiTranscoder.normalizeGenerateContentRequest(payload, model: "gemini-2.5-flash")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Gemini non-text multimodal parts are not supported"))
            XCTAssertTrue(error.localizedDescription.contains("$.contents[0].parts[0]"))
        }
    }

    func testAnthropicMessageResponseMapsToolCallsBackToToolUseBlocks() {
        let completedResponse: [String: Any] = [
            "id": "resp_123",
            "output": [
                [
                    "type": "function_call",
                    "call_id": "call_123",
                    "name": "run_command",
                    "arguments": #"{"command":"ls"}"#,
                ],
            ],
            "usage": [
                "input_tokens": 4,
                "output_tokens": 7,
                "total_tokens": 11,
            ],
        ]

        let response = AnthropicTranscoder.messageResponse(from: completedResponse, requestedModel: "claude-sonnet-4-5")

        XCTAssertEqual(response["type"] as? String, "message")
        XCTAssertEqual(response["stop_reason"] as? String, "tool_use")
        let content = try? XCTUnwrap(response["content"] as? [[String: Any]])
        XCTAssertEqual(content?.first?["type"] as? String, "tool_use")
        XCTAssertEqual(content?.first?["id"] as? String, "call_123")
        XCTAssertEqual(content?.first?["name"] as? String, "run_command")
    }

    func testAnthropicMessagesSSEChunksStreamTextThenToolWithContinuousIndices() throws {
        var streamState = AnthropicStreamState(messageID: "msg_test")
        let requestedModel = "claude-sonnet-4-5"
        let events: [SSEEvent] = [
            .init(event: nil, data: #"{"type":"response.created","response":{"id":"msg_test","created_at":1710000000}}"#),
            .init(event: nil, data: #"{"type":"response.output_text.delta","delta":"Hello world"}"#),
            .init(event: nil, data: #"{"type":"response.output_text.done","output_index":0}"#),
            .init(event: nil, data: #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_123","type":"function_call","call_id":"call_123","name":"run_command","arguments":""}}"#),
            .init(event: nil, data: #"{"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_123","delta":"{\"command\":\"ls\"}"}"#),
            .init(event: nil, data: #"{"type":"response.function_call_arguments.done","output_index":1,"item_id":"fc_123","arguments":"{\"command\":\"ls\"}"}"#),
            .init(event: nil, data: #"{"type":"response.completed","response":{"id":"msg_test","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello world"}]},{"type":"function_call","call_id":"call_123","name":"run_command","arguments":"{\"command\":\"ls\"}"}],"usage":{"input_tokens":4,"output_tokens":7,"total_tokens":11}}}"#),
        ]

        let translated = events.flatMap { event in
            AnthropicTranscoder.messagesSSEChunks(
                from: event,
                streamState: &streamState,
                requestedModel: requestedModel
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }

        XCTAssertEqual(
            translated.compactMap(\.event),
            [
                "message_start",
                "content_block_start",
                "content_block_delta",
                "content_block_stop",
                "content_block_start",
                "content_block_delta",
                "content_block_stop",
                "message_delta",
                "message_stop",
            ]
        )

        let payloads = translated.compactMap(ProxyTranscoder.jsonObject(from:))
        let contentIndexes = payloads.compactMap { payload -> Int? in
            guard (payload["type"] as? String)?.hasPrefix("content_block") == true else {
                return nil
            }
            return payload["index"] as? Int
        }
        XCTAssertEqual(contentIndexes, [0, 0, 0, 1, 1, 1])

        let toolStart = try XCTUnwrap(payloads.first(where: {
            ($0["type"] as? String) == "content_block_start"
                && ((($0["content_block"] as? [String: Any])?["type"] as? String) == "tool_use")
        }))
        let toolBlock = try XCTUnwrap(toolStart["content_block"] as? [String: Any])
        XCTAssertEqual(toolBlock["id"] as? String, "call_123")
        XCTAssertEqual(toolBlock["name"] as? String, "run_command")

        let toolDelta = try XCTUnwrap(payloads.first(where: {
            ($0["type"] as? String) == "content_block_delta"
                && ((($0["delta"] as? [String: Any])?["type"] as? String) == "input_json_delta")
        }))
        let toolDeltaPayload = try XCTUnwrap(toolDelta["delta"] as? [String: Any])
        XCTAssertEqual(toolDeltaPayload["partial_json"] as? String, #"{"command":"ls"}"#)

        let messageDelta = try XCTUnwrap(payloads.first(where: { ($0["type"] as? String) == "message_delta" }))
        let delta = try XCTUnwrap(messageDelta["delta"] as? [String: Any])
        XCTAssertEqual(delta["stop_reason"] as? String, "tool_use")
    }

    func testGeminiGenerateContentSSEChunksStreamTextAndToolCall() throws {
        var streamState = GeminiStreamState()
        let context = GeminiRequestContext(
            sourceModel: "gemini-2.5-flash",
            allowsFunctionCalls: true
        )
        let events: [SSEEvent] = [
            .init(event: nil, data: #"{"type":"response.created","response":{"id":"resp_test","created_at":1710000000}}"#),
            .init(event: nil, data: #"{"type":"response.output_text.delta","delta":"Hello world"}"#),
            .init(event: nil, data: #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_123","type":"function_call","call_id":"call_123","name":"run_command","arguments":""}}"#),
            .init(event: nil, data: #"{"type":"response.function_call_arguments.done","output_index":1,"item_id":"fc_123","arguments":"{\"command\":\"ls\"}"}"#),
            .init(event: nil, data: #"{"type":"response.completed","response":{"id":"resp_test","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello world"}]},{"type":"function_call","call_id":"call_123","name":"run_command","arguments":"{\"command\":\"ls\"}"}],"usage":{"input_tokens":4,"output_tokens":7,"total_tokens":11}}}"#),
        ]

        let translated = events.flatMap { event in
            GeminiTranscoder.streamGenerateContentSSEChunks(
                from: event,
                state: &streamState,
                requestedModel: "gemini-2.5-flash",
                context: context
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }

        let payloads = translated.compactMap(ProxyTranscoder.jsonObject(from:))
        XCTAssertEqual(payloads.count, 3)

        let textChunk = try XCTUnwrap(payloads.first)
        let textCandidates = try XCTUnwrap(textChunk["candidates"] as? [[String: Any]])
        let textContent = try XCTUnwrap(textCandidates.first?["content"] as? [String: Any])
        let textParts = try XCTUnwrap(textContent["parts"] as? [[String: Any]])
        XCTAssertEqual(textParts.first?["text"] as? String, "Hello world")

        let toolChunk = try XCTUnwrap(payloads.dropFirst().first)
        let toolCandidates = try XCTUnwrap(toolChunk["candidates"] as? [[String: Any]])
        let toolContent = try XCTUnwrap(toolCandidates.first?["content"] as? [String: Any])
        let toolParts = try XCTUnwrap(toolContent["parts"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(toolParts.first?["functionCall"] as? [String: Any])
        XCTAssertEqual(functionCall["id"] as? String, "call_123")
        XCTAssertEqual(functionCall["name"] as? String, "run_command")
        XCTAssertEqual((functionCall["args"] as? [String: String])?["command"], "ls")
        XCTAssertEqual(
            toolParts.first?["thoughtSignature"] as? String,
            "proxy_ts_\(Helpers.sha256("gemini-2.5-flash\ncall_123\nrun_command\n{\"command\":\"ls\"}"))"
        )

        let finalChunk = try XCTUnwrap(payloads.last)
        XCTAssertEqual(finalChunk["modelVersion"] as? String, "gemini-2.5-flash")
        let finalCandidates = try XCTUnwrap(finalChunk["candidates"] as? [[String: Any]])
        XCTAssertEqual(finalCandidates.first?["finishReason"] as? String, "STOP")
        let usageMetadata = try XCTUnwrap(finalChunk["usageMetadata"] as? [String: Any])
        XCTAssertEqual((usageMetadata["totalTokenCount"] as? NSNumber)?.intValue, 11)
    }

    func testGeminiGenerateContentSSEChunksStreamThoughtsSeparatelyAndSuppressesWhenDisabled() throws {
        let events: [SSEEvent] = [
            .init(event: nil, data: #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"Inspecting files"}"#),
            .init(event: nil, data: #"{"type":"response.output_text.delta","delta":"Ready"}"#),
            .init(event: nil, data: #"{"type":"response.completed","response":{"id":"resp_reasoning","status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Inspecting files"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Ready"}]}],"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}}"#),
        ]

        var includeThoughtsState = GeminiStreamState()
        let includeThoughtsPayloads = events.flatMap { event in
            GeminiTranscoder.streamGenerateContentSSEChunks(
                from: event,
                state: &includeThoughtsState,
                requestedModel: "gemini-2.5-flash",
                context: .init(sourceModel: "gemini-2.5-flash", includeThoughts: true)
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }.compactMap(ProxyTranscoder.jsonObject(from:))

        XCTAssertEqual(includeThoughtsPayloads.count, 3)
        let thoughtChunk = try XCTUnwrap(includeThoughtsPayloads.first)
        let thoughtParts = try XCTUnwrap(
            ((thoughtChunk["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        )
        XCTAssertEqual(thoughtParts.first?["text"] as? String, "Inspecting files")
        XCTAssertEqual(thoughtParts.first?["thought"] as? Bool, true)

        var suppressThoughtsState = GeminiStreamState()
        let suppressThoughtsPayloads = events.flatMap { event in
            GeminiTranscoder.streamGenerateContentSSEChunks(
                from: event,
                state: &suppressThoughtsState,
                requestedModel: "gemini-2.5-flash",
                context: .init(sourceModel: "gemini-2.5-flash", includeThoughts: false)
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }.compactMap(ProxyTranscoder.jsonObject(from:))

        XCTAssertEqual(suppressThoughtsPayloads.count, 2)
        let visibleTextChunk = try XCTUnwrap(suppressThoughtsPayloads.first)
        let visibleParts = try XCTUnwrap(
            ((visibleTextChunk["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        )
        XCTAssertEqual(visibleParts.first?["text"] as? String, "Ready")
        XCTAssertNil(visibleParts.first?["thought"])
    }

    func testGeminiGenerateContentResponseMapsToolCallIDBackToGeminiPart() throws {
        let completedResponse: [String: Any] = [
            "id": "resp_123",
            "output": [
                [
                    "type": "function_call",
                    "call_id": "call_123",
                    "name": "run_command",
                    "arguments": #"{"command":"ls"}"#,
                ],
            ],
            "usage": [
                "input_tokens": 4,
                "output_tokens": 7,
                "total_tokens": 11,
            ],
        ]

        let response = GeminiTranscoder.generateContentResponse(
            from: completedResponse,
            requestedModel: "gemini-2.5-flash",
            context: .init(sourceModel: "gemini-2.5-flash", allowsFunctionCalls: true)
        )

        let candidates = try XCTUnwrap(response["candidates"] as? [[String: Any]])
        let content = try XCTUnwrap(candidates.first?["content"] as? [String: Any])
        let parts = try XCTUnwrap(content["parts"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(parts.first?["functionCall"] as? [String: Any])
        XCTAssertEqual(functionCall["id"] as? String, "call_123")
        XCTAssertEqual(functionCall["name"] as? String, "run_command")
        XCTAssertEqual(
            parts.first?["thoughtSignature"] as? String,
            "proxy_ts_\(Helpers.sha256("gemini-2.5-flash\ncall_123\nrun_command\n{\"command\":\"ls\"}"))"
        )
    }

    func testGeminiGenerateContentResponsePreservesUpstreamThoughtSignatureOnToolCall() throws {
        let completedResponse: [String: Any] = [
            "id": "resp_123",
            "output": [
                [
                    "type": "function_call",
                    "call_id": "call_123",
                    "name": "run_command",
                    "arguments": #"{"command":"ls"}"#,
                    "thoughtSignature": "upstream_sig_123",
                ],
            ],
        ]

        let response = GeminiTranscoder.generateContentResponse(
            from: completedResponse,
            requestedModel: "gemini-2.5-flash",
            context: .init(sourceModel: "gemini-2.5-flash", allowsFunctionCalls: true)
        )

        let candidates = try XCTUnwrap(response["candidates"] as? [[String: Any]])
        let content = try XCTUnwrap(candidates.first?["content"] as? [String: Any])
        let parts = try XCTUnwrap(content["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["thoughtSignature"] as? String, "upstream_sig_123")
    }

    func testGeminiGenerateContentSSEChunksPreserveUpstreamThoughtSignatureOnToolCall() throws {
        var streamState = GeminiStreamState()
        let context = GeminiRequestContext(
            sourceModel: "gemini-2.5-flash",
            allowsFunctionCalls: true
        )
        let events: [SSEEvent] = [
            .init(event: nil, data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_123","type":"function_call","call_id":"call_123","name":"run_command","arguments":"","thoughtSignature":"upstream_sig_123"}}"#),
            .init(event: nil, data: #"{"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_123","arguments":"{\"command\":\"ls\"}"}"#),
        ]

        let payloads = events.flatMap { event in
            GeminiTranscoder.streamGenerateContentSSEChunks(
                from: event,
                state: &streamState,
                requestedModel: "gemini-2.5-flash",
                context: context
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }.compactMap(ProxyTranscoder.jsonObject(from:))

        let toolChunk = try XCTUnwrap(payloads.first)
        let toolParts = try XCTUnwrap(
            ((toolChunk["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        )
        XCTAssertEqual(toolParts.first?["thoughtSignature"] as? String, "upstream_sig_123")
    }

    func testGeminiGenerateContentResponseAddsCompatibilityThoughtSignatureToFirstVisibleTextForCLISession() throws {
        let completedResponse: [String: Any] = [
            "id": "resp_cli_text",
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "Hello",
                        ],
                        [
                            "type": "output_text",
                            "text": " world",
                        ],
                    ],
                ],
            ],
        ]

        let response = GeminiTranscoder.generateContentResponse(
            from: completedResponse,
            requestedModel: "gemini-2.5-flash",
            context: .init(sourceModel: "gemini-2.5-flash", isGeminiCLISession: true)
        )

        let candidates = try XCTUnwrap(response["candidates"] as? [[String: Any]])
        let content = try XCTUnwrap(candidates.first?["content"] as? [String: Any])
        let parts = try XCTUnwrap(content["parts"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "Hello")
        XCTAssertEqual(
            parts[0]["thoughtSignature"] as? String,
            GeminiTranscoder.compatibilityThoughtSignature
        )
        XCTAssertEqual(parts[1]["text"] as? String, " world")
        XCTAssertNil(parts[1]["thoughtSignature"])
    }

    func testGeminiGenerateContentSSEChunksAddCompatibilityThoughtSignatureOnlyToFirstVisibleTextForCLISession() throws {
        var streamState = GeminiStreamState()
        let context = GeminiRequestContext(
            sourceModel: "gemini-2.5-flash",
            isGeminiCLISession: true
        )
        let events: [SSEEvent] = [
            .init(event: nil, data: #"{"type":"response.output_text.delta","delta":"Hello"}"#),
            .init(event: nil, data: #"{"type":"response.output_text.delta","delta":" world"}"#),
        ]

        let payloads = events.flatMap { event in
            GeminiTranscoder.streamGenerateContentSSEChunks(
                from: event,
                state: &streamState,
                requestedModel: "gemini-2.5-flash",
                context: context
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }.compactMap(ProxyTranscoder.jsonObject(from:))

        let firstParts = try XCTUnwrap(
            ((payloads[0]["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        )
        XCTAssertEqual(firstParts.first?["text"] as? String, "Hello")
        XCTAssertEqual(
            firstParts.first?["thoughtSignature"] as? String,
            GeminiTranscoder.compatibilityThoughtSignature
        )

        let secondParts = try XCTUnwrap(
            ((payloads[1]["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        )
        XCTAssertEqual(secondParts.first?["text"] as? String, " world")
        XCTAssertNil(secondParts.first?["thoughtSignature"])
    }

    func testGeminiThoughtSignatureCompatibilityCleanerReplacesNestedRequestSignatures() throws {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "model",
                    "parts": [
                        [
                            "text": "thinking",
                            "thought": true,
                            "thoughtSignature": "sig-thought",
                        ],
                        [
                            "functionCall": [
                                "id": "call_123",
                                "name": "run_command",
                                "args": ["command": "ls"],
                                "thoughtSignature": "sig-call-inner",
                            ],
                            "thoughtSignature": "sig-call-outer",
                        ],
                    ],
                ],
                [
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call_123",
                                "name": "run_command",
                                "response": ["output": "file.txt"],
                                "thoughtSignature": "sig-response-inner",
                            ],
                            "thought_signature": "sig-response-outer",
                        ],
                    ],
                ],
            ],
        ]

        XCTAssertTrue(GeminiTranscoder.containsThoughtSignature(in: payload))
        let sanitized = GeminiTranscoder.replacingThoughtSignaturesWithCompatibilitySignature(
            in: payload
        )

        let contents = try XCTUnwrap(sanitized["contents"] as? [[String: Any]])
        let modelParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(
            modelParts[0]["thoughtSignature"] as? String,
            GeminiTranscoder.compatibilityThoughtSignature
        )
        XCTAssertEqual(
            modelParts[1]["thoughtSignature"] as? String,
            GeminiTranscoder.compatibilityThoughtSignature
        )

        let functionCall = try XCTUnwrap(modelParts[1]["functionCall"] as? [String: Any])
        XCTAssertEqual(
            functionCall["thoughtSignature"] as? String,
            GeminiTranscoder.compatibilityThoughtSignature
        )

        let toolParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        XCTAssertEqual(
            toolParts[0]["thought_signature"] as? String,
            GeminiTranscoder.compatibilityThoughtSignature
        )
        let functionResponse = try XCTUnwrap(toolParts[0]["functionResponse"] as? [String: Any])
        XCTAssertEqual(
            functionResponse["thoughtSignature"] as? String,
            GeminiTranscoder.compatibilityThoughtSignature
        )
    }

    func testGeminiGenerateContentResponseMapsReasoningSummaryAndFallbackReasoningText() throws {
        let summaryResponse: [String: Any] = [
            "id": "resp_reasoning_summary",
            "status": "completed",
            "output": [
                [
                    "type": "reasoning",
                    "summary": [
                        [
                            "type": "summary_text",
                            "text": "Scanned project structure",
                        ],
                    ],
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "Summary ready",
                        ],
                    ],
                ],
            ],
        ]

        let summaryPayload = GeminiTranscoder.generateContentResponse(
            from: summaryResponse,
            requestedModel: "gemini-2.5-flash",
            context: .init(sourceModel: "gemini-2.5-flash", includeThoughts: true)
        )
        let summaryParts = try XCTUnwrap(
            (((summaryPayload["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])
        )
        XCTAssertEqual(summaryParts.first?["text"] as? String, "Scanned project structure")
        XCTAssertEqual(summaryParts.first?["thought"] as? Bool, true)
        XCTAssertEqual(summaryParts.last?["text"] as? String, "Summary ready")

        let fallbackResponse: [String: Any] = [
            "id": "resp_reasoning_text",
            "status": "completed",
            "output": [
                [
                    "type": "reasoning",
                    "content": [
                        [
                            "type": "reasoning_text",
                            "text": "Listing modules",
                        ],
                    ],
                ],
            ],
        ]

        let fallbackPayload = GeminiTranscoder.generateContentResponse(
            from: fallbackResponse,
            requestedModel: "gemini-2.5-flash",
            context: .init(sourceModel: "gemini-2.5-flash", includeThoughts: true)
        )
        let fallbackParts = try XCTUnwrap(
            (((fallbackPayload["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])
        )
        XCTAssertEqual(fallbackParts.count, 1)
        XCTAssertEqual(fallbackParts.first?["text"] as? String, "Listing modules")
        XCTAssertEqual(fallbackParts.first?["thought"] as? Bool, true)
    }

    func testGeminiGenerateContentResponseMapsFinishReasons() throws {
        let maxTokensResponse: [String: Any] = [
            "id": "resp_max_tokens",
            "status": "incomplete",
            "incomplete_details": [
                "reason": "max_output_tokens",
            ],
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "Partial answer",
                        ],
                    ],
                ],
            ],
        ]
        let maxTokensPayload = GeminiTranscoder.generateContentResponse(
            from: maxTokensResponse,
            requestedModel: "gemini-2.5-flash",
            context: .default(sourceModel: "gemini-2.5-flash")
        )
        XCTAssertEqual(
            ((maxTokensPayload["candidates"] as? [[String: Any]])?.first)?["finishReason"] as? String,
            "MAX_TOKENS"
        )

        let safetyResponse: [String: Any] = [
            "id": "resp_safety",
            "status": "incomplete",
            "incomplete_details": [
                "reason": "content_filter",
            ],
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "refusal",
                            "refusal": "Cannot help with that.",
                        ],
                    ],
                ],
            ],
        ]
        let safetyPayload = GeminiTranscoder.generateContentResponse(
            from: safetyResponse,
            requestedModel: "gemini-2.5-flash",
            context: .default(sourceModel: "gemini-2.5-flash")
        )
        XCTAssertEqual(
            ((safetyPayload["candidates"] as? [[String: Any]])?.first)?["finishReason"] as? String,
            "SAFETY"
        )

        let unexpectedToolResponse: [String: Any] = [
            "id": "resp_unexpected_tool",
            "status": "completed",
            "output": [
                [
                    "type": "function_call",
                    "call_id": "call_unexpected",
                    "name": "run_command",
                    "arguments": #"{"command":"ls"}"#,
                ],
            ],
        ]
        let unexpectedToolPayload = GeminiTranscoder.generateContentResponse(
            from: unexpectedToolResponse,
            requestedModel: "gemini-2.5-flash",
            context: .init(sourceModel: "gemini-2.5-flash", allowsFunctionCalls: false)
        )
        XCTAssertEqual(
            ((unexpectedToolPayload["candidates"] as? [[String: Any]])?.first)?["finishReason"] as? String,
            "UNEXPECTED_TOOL_CALL"
        )
        let unexpectedToolParts = try XCTUnwrap(
            (((unexpectedToolPayload["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])
        )
        XCTAssertTrue(unexpectedToolParts.isEmpty)

        let malformedToolResponse: [String: Any] = [
            "id": "resp_malformed_tool",
            "status": "completed",
            "output": [
                [
                    "type": "function_call",
                    "call_id": "call_malformed",
                    "name": "",
                    "arguments": #"{"command":"ls"}"#,
                ],
            ],
        ]
        let malformedToolPayload = GeminiTranscoder.generateContentResponse(
            from: malformedToolResponse,
            requestedModel: "gemini-2.5-flash",
            context: .init(sourceModel: "gemini-2.5-flash", allowsFunctionCalls: true)
        )
        XCTAssertEqual(
            ((malformedToolPayload["candidates"] as? [[String: Any]])?.first)?["finishReason"] as? String,
            "MALFORMED_FUNCTION_CALL"
        )
    }

    func testSSEIncrementalDecoderHandlesSplitChunks() {
        var decoder = SSEIncrementalDecoder()
        let chunk1 = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hel".utf8)
        let chunk2 = Data("lo\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}}\n\n".utf8)

        XCTAssertEqual(decoder.append(chunk1), [])
        let events = decoder.append(chunk2)

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].data.contains("response.output_text.delta"))
        XCTAssertTrue(events[1].data.contains("response.completed"))
        XCTAssertEqual(decoder.finish(), [])
    }

    func testCompletedResponseFallsBackToSSETextWhenOutputMissing() throws {
        let events = [
            SSEEvent(event: nil, data: #"{"type":"response.output_text.delta","delta":"ok"}"#),
            SSEEvent(event: nil, data: #"{"type":"response.completed","response":{"id":"resp_test","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#),
        ]

        let completed = try XCTUnwrap(ProxyTranscoder.extractCompletedResponse(from: events))
        let patched = ProxyTranscoder.completedResponseByEnsuringAssistantText(
            completed,
            fallbackText: ProxyTranscoder.extractAssistantText(from: events)
        )

        XCTAssertEqual(ProxyTranscoder.extractAssistantText(from: patched), "ok")
    }

    func testSyntheticResponsesFailureSSEChunkEncodesFailedStatus() throws {
        let chunks = [
            ProxyTranscoder.responseCreatedSSEChunk(
                responseID: "resp_failed",
                createdAt: 1710000000,
                requestedModel: "gpt-5"
            ),
            ProxyTranscoder.responseFailedSSEChunk(
                responseID: "resp_failed",
                createdAt: 1710000000,
                requestedModel: "gpt-5",
                message: "Upstream stream terminated before response.completed was received."
            ),
        ]
        let payloads = chunks
            .flatMap { ProxyTranscoder.decodeSSE(Data($0.utf8)) }
            .compactMap(ProxyTranscoder.jsonObject(from:))

        XCTAssertEqual(payloads.first?["type"] as? String, "response.created")
        XCTAssertEqual(payloads.last?["type"] as? String, "response.failed")
        let failedResponse = try XCTUnwrap(payloads.last?["response"] as? [String: Any])
        XCTAssertEqual(failedResponse["status"] as? String, "failed")
        let error = try XCTUnwrap(failedResponse["error"] as? [String: Any])
        XCTAssertEqual(
            error["message"] as? String,
            "Upstream stream terminated before response.completed was received."
        )
    }

    func testGeminiErrorSSEChunkEncodesGeminiErrorPayload() throws {
        let chunk = GeminiTranscoder.errorSSEChunk(
            status: 500,
            message: "Upstream Gemini stream terminated before a final finishReason was received.",
            statusText: "INTERNAL"
        )
        let payload = try XCTUnwrap(
            ProxyTranscoder.decodeSSE(Data(chunk.utf8)).compactMap(ProxyTranscoder.jsonObject(from:)).first
        )
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual((error["code"] as? NSNumber)?.intValue, 500)
        XCTAssertEqual(error["status"] as? String, "INTERNAL")
        XCTAssertEqual(
            error["message"] as? String,
            "Upstream Gemini stream terminated before a final finishReason was received."
        )
    }

    func testUsageExtractionParsesCachedTokensFromResponsesUsage() {
        let completedResponse: [String: Any] = [
            "usage": [
                "input_tokens": 14,
                "output_tokens": 6,
                "total_tokens": 20,
                "input_tokens_details": [
                    "cached_tokens": 9,
                ],
            ]
        ]

        let usage = ProxyTranscoder.usageFromCompletedResponse(completedResponse)

        XCTAssertEqual(usage.inputTokens, 14)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.cacheHitTokens, 9)
    }

    func testUsageExtractionParsesDeepSeekPromptCacheHitTokens() throws {
        let completedResponse = ProxyTranscoder.completedResponse(
            fromChatCompletion: [
                "id": "chatcmpl_deepseek_cache",
                "created": 1_710_000_000,
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "content": "cached",
                    ],
                ]],
                "usage": [
                    "prompt_tokens": 14,
                    "completion_tokens": 6,
                    "total_tokens": 20,
                    "prompt_cache_hit_tokens": 11,
                    "prompt_cache_miss_tokens": 3,
                ],
            ],
            requestedModel: "deepseek-chat"
        )

        let usage = ProxyTranscoder.usageFromCompletedResponse(completedResponse)
        let usageObject = try XCTUnwrap(completedResponse["usage"] as? [String: Any])
        let inputDetails = try XCTUnwrap(usageObject["input_tokens_details"] as? [String: Any])

        XCTAssertEqual(usage.inputTokens, 14)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.cacheHitTokens, 11)
        XCTAssertEqual(inputDetails["cached_tokens"] as? Int64, 11)
    }

    func testRecognizableUsageDetectionRequiresStandardTokenFieldsButAcceptsZeroValues() {
        XCTAssertFalse(ProxyTranscoder.hasRecognizableUsage(inUsageObject: nil))
        XCTAssertFalse(ProxyTranscoder.hasRecognizableUsage(inUsageObject: [:]))
        XCTAssertFalse(ProxyTranscoder.hasRecognizableUsage(in: ["usage": [:]]))
        XCTAssertTrue(
            ProxyTranscoder.hasRecognizableUsage(
                inUsageObject: [
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 0,
                ]
            )
        )
        XCTAssertTrue(
            ProxyTranscoder.hasRecognizableUsage(
                inUsageObject: [
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "total_tokens": 0,
                ]
            )
        )
    }

    func testPromptCacheContextUsesStableSessionAndIsolatesByProxyKey() {
        let payload: [String: Any] = [
            "metadata": [
                "user_id": #"{"session_id":"session-42","user_id":"dev-user"}"#,
            ],
        ]
        let firstRequest: [String: Any] = [
            "instructions": "System",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "hello"]],
                ],
            ],
        ]
        let secondRequest: [String: Any] = [
            "instructions": "System",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "hello again"]],
                ],
            ],
        ]

        let primaryProxyKey = AuthenticatedProxyKeyContext(
            apiKeyHash: "hash-primary",
            proxyKeyID: "proxy-primary",
            dataSource: .openAI
        )
        let secondaryProxyKey = AuthenticatedProxyKeyContext(
            apiKeyHash: "hash-secondary",
            proxyKeyID: "proxy-secondary",
            dataSource: .openAI
        )

        let primaryContext = PromptCacheSupport.context(
            headers: [:],
            requestPayload: payload,
            normalizedRequest: firstRequest,
            requestedModel: "gpt-5.4",
            proxyKey: primaryProxyKey
        )
        let sameSessionContext = PromptCacheSupport.context(
            headers: [:],
            requestPayload: payload,
            normalizedRequest: secondRequest,
            requestedModel: "gpt-5.4",
            proxyKey: primaryProxyKey
        )
        let isolatedContext = PromptCacheSupport.context(
            headers: [:],
            requestPayload: payload,
            normalizedRequest: firstRequest,
            requestedModel: "gpt-5.4",
            proxyKey: secondaryProxyKey
        )

        XCTAssertEqual(primaryContext.sessionIdentifier, "session-42")
        XCTAssertEqual(primaryContext.upstreamPromptCacheKey, sameSessionContext.upstreamPromptCacheKey)
        XCTAssertEqual(primaryContext.upstreamSessionID, sameSessionContext.upstreamSessionID)
        XCTAssertNotEqual(primaryContext.upstreamPromptCacheKey, isolatedContext.upstreamPromptCacheKey)
        XCTAssertNotEqual(primaryContext.upstreamSessionID, isolatedContext.upstreamSessionID)
    }

    func testPromptCacheContextPrefersGeminiCLIStickySessionFingerprint() {
        let tmpHash = String(repeating: "a", count: 64)
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "Inspect /.gemini/tmp/\(tmpHash)/workspace"],
                    ],
                ],
            ],
        ]
        let normalizedRequest: [String: Any] = [
            "instructions": "",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Inspect repo"]],
                ],
            ],
        ]
        let proxyKey = AuthenticatedProxyKeyContext(
            apiKeyHash: "hash-gemini",
            proxyKeyID: "proxy-gemini",
            dataSource: .openAI
        )

        let context = PromptCacheSupport.context(
            headers: [
                "x-gemini-api-privileged-user-id": "gemini-user-42",
            ],
            requestPayload: payload,
            normalizedRequest: normalizedRequest,
            requestedModel: "gemini-2.5-flash",
            proxyKey: proxyKey,
            preferGeminiCLIStickySession: true,
            allowManualAPIKeyStickyBinding: true
        )

        let expectedSeed = "proxy-gemini|gemini-cli=gemini-user-42:\(tmpHash)"
        let expectedStickyKey = "cpx_\(String(Helpers.sha256(expectedSeed).prefix(40)))"

        XCTAssertEqual(context.geminiCLIStickySessionKey, expectedStickyKey)
        XCTAssertEqual(context.stickySessionKey, expectedStickyKey)
        XCTAssertEqual(context.upstreamPromptCacheKey?.hasPrefix("cpx_"), true)
        XCTAssertTrue(context.isGeminiCLISession)
        XCTAssertTrue(context.allowManualAPIKeyStickyBinding)
    }

    func testPromptCacheContextFallsBackToUpstreamStickyKeyWithoutGeminiCLIFingerprint() {
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "Inspect project root"],
                    ],
                ],
            ],
        ]
        let normalizedRequest: [String: Any] = [
            "instructions": "",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Inspect repo"]],
                ],
            ],
        ]
        let proxyKey = AuthenticatedProxyKeyContext(
            apiKeyHash: "hash-gemini",
            proxyKeyID: "proxy-gemini",
            dataSource: .openAI
        )

        let context = PromptCacheSupport.context(
            headers: [
                "x-gemini-api-privileged-user-id": "gemini-user-42",
            ],
            requestPayload: payload,
            normalizedRequest: normalizedRequest,
            requestedModel: "gemini-2.5-flash",
            proxyKey: proxyKey,
            preferGeminiCLIStickySession: true
        )

        XCTAssertNil(context.geminiCLIStickySessionKey)
        XCTAssertEqual(context.stickySessionKey, context.upstreamPromptCacheKey)
        XCTAssertEqual(context.upstreamPromptCacheKey?.hasPrefix("cpx_"), true)
        XCTAssertTrue(context.isGeminiCLISession)
    }

    func testAnthropicUsageNormalizationPromotesCachedTokensToCacheReadInputTokens() {
        let usage = ProxyTranscoder.usageFromAnthropicUsage([
            "input_tokens": 11,
            "output_tokens": 7,
            "cached_tokens": 5,
        ])
        let normalized = ProxyTranscoder.normalizedAnthropicUsageObject([
            "input_tokens": 11,
            "output_tokens": 7,
            "cached_tokens": 5,
        ])

        XCTAssertEqual(usage.inputTokens, 16)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.totalTokens, 23)
        XCTAssertEqual(usage.cacheHitTokens, 5)
        XCTAssertEqual((normalized?["cache_read_input_tokens"] as? NSNumber)?.int64Value, 5)

        let message = AnthropicTranscoder.messageResponse(
            from: [
                "id": "resp_test",
                "output": [],
                "usage": [
                    "input_tokens": 11,
                    "output_tokens": 7,
                    "cache_read_input_tokens": 5,
                ],
            ],
            requestedModel: "claude-sonnet-4-5"
        )
        let responseUsage = message["usage"] as? [String: Any]
        XCTAssertEqual((responseUsage?["cache_read_input_tokens"] as? NSNumber)?.int64Value, 5)
    }

    func testAnthropicUsageCountsCacheReadTokensAsInputTokensForLogs() {
        let usage = ProxyTranscoder.usageFromAnthropicUsage([
            "input_tokens": 0,
            "output_tokens": 7,
            "cache_read_input_tokens": 17,
        ])

        XCTAssertEqual(usage.inputTokens, 17)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.totalTokens, 24)
        XCTAssertEqual(usage.cacheHitTokens, 17)
    }

    func testAnthropicUsageCountsCacheCreationTokensAsInputTokensForLogs() {
        let usage = ProxyTranscoder.usageFromAnthropicUsage([
            "input_tokens": 11,
            "output_tokens": 7,
            "cache_read_input_tokens": 5,
            "cache_creation_input_tokens": 3,
        ])

        XCTAssertEqual(usage.inputTokens, 19)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.totalTokens, 26)
        XCTAssertEqual(usage.cacheHitTokens, 5)
    }

    func testAnthropicUsageCountsCacheCreationObjectAsInputTokensForLogs() {
        let usage = ProxyTranscoder.usageFromAnthropicUsage([
            "input_tokens": 11,
            "output_tokens": 7,
            "cache_creation": [
                "ephemeral_5m_input_tokens": 3,
                "ephemeral_1h_input_tokens": 4,
            ],
        ])
        let normalized = ProxyTranscoder.normalizedAnthropicUsageObject([
            "input_tokens": 11,
            "output_tokens": 7,
            "cache_creation": [
                "ephemeral_5m_input_tokens": 3,
                "ephemeral_1h_input_tokens": 4,
            ],
        ])

        XCTAssertEqual(usage.inputTokens, 18)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.totalTokens, 25)
        XCTAssertNil(usage.cacheHitTokens)
        XCTAssertEqual((normalized?["cache_creation_input_tokens"] as? NSNumber)?.int64Value, 7)
    }

    func testAnthropicMessageResponsePreservesExplicitZeroCacheReadTokens() {
        let message = AnthropicTranscoder.messageResponse(
            from: [
                "id": "resp_test",
                "output": [],
                "usage": [
                    "input_tokens": 11,
                    "output_tokens": 7,
                    "cache_read_input_tokens": 0,
                ],
            ],
            requestedModel: "claude-sonnet-4-5"
        )

        let responseUsage = message["usage"] as? [String: Any]
        XCTAssertEqual((responseUsage?["cache_read_input_tokens"] as? NSNumber)?.int64Value, 0)
    }

    func testAnthropicUpstreamBridgeSyntheticStreamPreservesExplicitZeroCacheReadTokens() throws {
        var state = AnthropicSyntheticStreamState()
        let events: [SSEEvent] = [
            .init(
                event: "message_start",
                data: #"{"type":"message_start","message":{"id":"msg_stream","usage":{"input_tokens":4,"output_tokens":0,"cache_read_input_tokens":0}}}"#
            ),
            .init(
                event: "content_block_delta",
                data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
            ),
            .init(
                event: "message_delta",
                data: #"{"type":"message_delta","usage":{"output_tokens":7,"cache_read_input_tokens":0}}"#
            ),
            .init(event: "message_stop", data: #"{"type":"message_stop"}"#),
        ]

        let translated = events.flatMap { event in
            AnthropicUpstreamBridge.responseSSEChunks(
                from: event,
                state: &state,
                requestedModel: "gpt-5.4"
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }

        let completed = try XCTUnwrap(translated.last)
        let payload = try XCTUnwrap(ProxyTranscoder.jsonObject(from: completed))
        let response = try XCTUnwrap(payload["response"] as? [String: Any])
        let usage = try XCTUnwrap(response["usage"] as? [String: Any])

        XCTAssertEqual((usage["cache_read_input_tokens"] as? NSNumber)?.int64Value, 0)
    }

    func testAnthropicUpstreamBridgeSyntheticStreamCountsCachedTokensInTotalInput() throws {
        var state = AnthropicSyntheticStreamState()
        let events: [SSEEvent] = [
            .init(
                event: "message_start",
                data: #"{"type":"message_start","message":{"id":"msg_stream","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":17,"cache_creation_input_tokens":3}}}"#
            ),
            .init(
                event: "content_block_delta",
                data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
            ),
            .init(
                event: "message_delta",
                data: #"{"type":"message_delta","usage":{"output_tokens":7,"cache_read_input_tokens":17}}"#
            ),
            .init(event: "message_stop", data: #"{"type":"message_stop"}"#),
        ]

        let translated = events.flatMap { event in
            AnthropicUpstreamBridge.responseSSEChunks(
                from: event,
                state: &state,
                requestedModel: "gpt-5.4"
            )
        }.flatMap { chunk in
            ProxyTranscoder.decodeSSE(Data(chunk.utf8))
        }

        let completed = try XCTUnwrap(translated.last)
        let payload = try XCTUnwrap(ProxyTranscoder.jsonObject(from: completed))
        let response = try XCTUnwrap(payload["response"] as? [String: Any])
        let usage = try XCTUnwrap(response["usage"] as? [String: Any])

        XCTAssertEqual((usage["input_tokens"] as? NSNumber)?.int64Value, 20)
        XCTAssertEqual((usage["output_tokens"] as? NSNumber)?.int64Value, 7)
        XCTAssertEqual((usage["total_tokens"] as? NSNumber)?.int64Value, 27)
        XCTAssertEqual((usage["cache_read_input_tokens"] as? NSNumber)?.int64Value, 17)
    }

    func testDuplicateImportPreservesExistingEnabledState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        let config = AppConfig()

        _ = try await service.importAuthJSONAccounts(
            items: [.init(source: "first.json", content: #"{"OPENAI_API_KEY":"sk-test-duplicate"}"#, label: "Primary", enabled: false)],
            config: config
        )
        _ = try await service.importAuthJSONAccounts(
            items: [.init(source: "second.json", content: #"{"OPENAI_API_KEY":"sk-test-duplicate"}"#, label: "Primary", enabled: true)],
            config: config
        )

        let accounts = try await service.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertFalse(accounts[0].enabled)
    }

    func testDuplicateImportPreservesExistingManagedProxyNodeAndModelRouting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        let config = AppConfig()

        _ = try await service.importAuthJSONAccounts(
            items: [.init(source: "first.json", content: #"{"OPENAI_API_KEY":"sk-test-duplicate-policies"}"#, label: "Primary")],
            config: config
        )

        let originalAccounts = try await service.listAccounts()
        let original = try XCTUnwrap(originalAccounts.first)
        _ = try await service.updateAccountManagedProxyNode(
            id: original.id,
            input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Tokyo")
        )
        _ = try await service.updateAccountModelRouting(
            id: original.id,
            input: UpdateAccountModelRoutingRequest(
                defaultTargetModel: "gpt-5.5",
                mappings: [.init(sourceModel: "gpt-5", targetModel: "gpt-5.5")]
            )
        )

        let result = try await service.importAuthJSONAccounts(
            items: [.init(source: "second.json", content: #"{"OPENAI_API_KEY":"sk-test-duplicate-policies"}"#, label: "Primary Updated")],
            config: config
        )

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)

        let accounts = try await service.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].managedProxyNodeName, "Tokyo")
        XCTAssertEqual(
            accounts[0].modelRouting,
            AccountModelRoutingConfig(
                defaultTargetModel: "gpt-5.5",
                mappings: [.init(sourceModel: "gpt-5", targetModel: "gpt-5.5")]
            )
        )
    }

    func testBackupImportDefaultsEnabledWhenFlagMissing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        let legacyBackup = #"""
        {
          "accounts": [
            {
              "label": "Legacy Backup",
              "authJSON": "{\"OPENAI_API_KEY\":\"sk-test-legacy\"}"
            }
          ]
        }
        """#
        _ = try await service.importAuthJSONAccounts(items: [.init(source: "legacy-backup.json", content: legacyBackup)], config: AppConfig())

        let accounts = try await service.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertTrue(accounts[0].enabled)
    }

    func testExportAndReimportBackupPreservesDisabledState() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: targetDirectory)
        }

        let sourceService = try Self.makeAccountService(dataDirectory: sourceDirectory)
        _ = try await sourceService.importAuthJSONAccounts(
            items: [.init(source: "disabled.json", content: #"{"OPENAI_API_KEY":"sk-test-export"}"#, label: "Disabled Export", enabled: false)],
            config: AppConfig()
        )
        let exported = try await sourceService.exportAccounts()

        let targetService = try Self.makeAccountService(dataDirectory: targetDirectory)
        _ = try await targetService.importAuthJSONAccounts(
            items: [.init(source: "backup.json", content: String(decoding: exported, as: UTF8.self))],
            config: AppConfig()
        )

        let accounts = try await targetService.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertFalse(accounts[0].enabled)
    }

    func testExportAndReimportBackupPreservesManagedProxyNodeName() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: targetDirectory)
        }

        let sourceService = try Self.makeAccountService(dataDirectory: sourceDirectory)
        let backup = #"""
        {
          "accounts": [
            {
              "label": "Node Bound Account",
              "managedProxyNodeName": "Tokyo",
              "authJSON": "{\"OPENAI_API_KEY\":\"sk-test-node-export\"}"
            }
          ]
        }
        """#
        _ = try await sourceService.importAuthJSONAccounts(
            items: [.init(source: "managed-proxy-node-backup.json", content: backup)],
            config: AppConfig()
        )

        let sourceAccounts = try await sourceService.listAccounts()
        XCTAssertEqual(sourceAccounts.first?.managedProxyNodeName, "Tokyo")

        let exported = try await sourceService.exportAccounts()
        let targetService = try Self.makeAccountService(dataDirectory: targetDirectory)
        _ = try await targetService.importAuthJSONAccounts(
            items: [.init(source: "backup.json", content: String(decoding: exported, as: UTF8.self))],
            config: AppConfig()
        )

        let accounts = try await targetService.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].managedProxyNodeName, "Tokyo")
    }

    func testAccountServiceUpdateAccountManagedProxyNodeRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        _ = try await service.importAuthJSONAccounts(
            items: [.init(source: "account.json", content: #"{"OPENAI_API_KEY":"sk-test-managed-proxy-node"}"#, label: "Managed Node Account")],
            config: AppConfig()
        )

        let accounts = try await service.listAccounts()
        let account = try XCTUnwrap(accounts.first)
        let updated = try await service.updateAccountManagedProxyNode(
            id: account.id,
            input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
        )
        XCTAssertEqual(updated.managedProxyNodeName, "Seoul")

        let reloaded = try await service.listAccounts()
        XCTAssertEqual(reloaded.first?.managedProxyNodeName, "Seoul")
    }

    func testAccountServiceClearAccountManagedProxyNodesClearsOnlySavedOverrides() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        _ = try await service.importAuthJSONAccounts(
            items: [
                .init(source: "account-a.json", content: #"{"OPENAI_API_KEY":"sk-test-managed-proxy-node-a"}"#, label: "Managed Node A"),
                .init(source: "account-b.json", content: #"{"OPENAI_API_KEY":"sk-test-managed-proxy-node-b"}"#, label: "Managed Node B"),
                .init(source: "account-c.json", content: #"{"OPENAI_API_KEY":"sk-test-managed-proxy-node-c"}"#, label: "Managed Node C"),
            ],
            config: AppConfig()
        )

        let accounts = try await service.listAccounts()
        XCTAssertEqual(accounts.count, 3)
        _ = try await service.updateAccountManagedProxyNode(
            id: accounts[0].id,
            input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Tokyo")
        )
        _ = try await service.updateAccountManagedProxyNode(
            id: accounts[2].id,
            input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
        )

        let result = try service.clearAccountManagedProxyNodes()
        XCTAssertEqual(result.clearedCount, 2)

        let reloaded = try await service.listAccounts()
        XCTAssertTrue(reloaded.allSatisfy { $0.managedProxyNodeName == nil })
    }

    func testAccountServiceUpdateAccountModelRoutingRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        _ = try await service.importAuthJSONAccounts(
            items: [.init(source: "account.json", content: #"{"OPENAI_API_KEY":"sk-test-model-routing"}"#, label: "Model Routing Account")],
            config: AppConfig()
        )

        let accounts = try await service.listAccounts()
        let account = try XCTUnwrap(accounts.first)
        let updated = try await service.updateAccountModelRouting(
            id: account.id,
            input: UpdateAccountModelRoutingRequest(
                defaultTargetModel: "  custom-default  ",
                mappings: [
                    .init(sourceModel: " gpt-5 ", targetModel: " first-target "),
                    .init(sourceModel: "gpt-5", targetModel: "override-target"),
                    .init(sourceModel: "", targetModel: "ignored"),
                    .init(sourceModel: "gpt-5.4", targetModel: " "),
                ]
            )
        )

        XCTAssertEqual(
            updated.modelRouting,
            AccountModelRoutingConfig(
                defaultTargetModel: "custom-default",
                mappings: [.init(sourceModel: "gpt-5", targetModel: "override-target")]
            )
        )

        let reloaded = try await service.listAccounts()
        XCTAssertEqual(reloaded.first?.modelRouting, updated.modelRouting)
    }

    func testAccountServiceExportImportPreservesAccountModelRouting() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: targetDirectory)
        }

        let sourceService = try Self.makeAccountService(dataDirectory: sourceDirectory)
        _ = try await sourceService.importAuthJSONAccounts(
            items: [.init(source: "account.json", content: #"{"OPENAI_API_KEY":"sk-export-model-routing"}"#, label: "Export Routing")],
            config: AppConfig()
        )

        let sourceAccounts = try await sourceService.listAccounts()
        let sourceAccount = try XCTUnwrap(sourceAccounts.first)
        _ = try await sourceService.updateAccountModelRouting(
            id: sourceAccount.id,
            input: UpdateAccountModelRoutingRequest(
                defaultTargetModel: "custom-export-default",
                mappings: [.init(sourceModel: "gpt-5.4", targetModel: "custom-export-target")]
            )
        )

        let exported = try await sourceService.exportAccounts()
        let targetService = try Self.makeAccountService(dataDirectory: targetDirectory)
        _ = try await targetService.importAuthJSONAccounts(
            items: [.init(source: "backup.json", content: String(decoding: exported, as: UTF8.self))],
            config: AppConfig()
        )

        let importedAccounts = try await targetService.listAccounts()
        let imported = try XCTUnwrap(importedAccounts.first)
        XCTAssertEqual(
            imported.modelRouting,
            AccountModelRoutingConfig(
                defaultTargetModel: "custom-export-default",
                mappings: [.init(sourceModel: "gpt-5.4", targetModel: "custom-export-target")]
            )
        )
    }

    func testManualAddAPIKeyAccountRejectsGenericPresetForOfficialGeminiRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)

        do {
            _ = try await service.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Gemini Wrong Preset",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
                    apiKey: "sk-gemini",
                    enabled: true
                ),
                config: AppConfig()
            )
            XCTFail("Expected Gemini root to be rejected for generic preset")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Google Gemini OpenAI-compatible"))
            XCTAssertTrue(error.localizedDescription.contains("Google Gemini Compatible"))
        }
    }

    func testUpdateManualAPIKeyAccountRejectsGenericPresetForOfficialGeminiRoot() async throws {
        let upstream = Self.makeOpenAICompatibleModelsApplication()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let service = try Self.makeAccountService(dataDirectory: directory)
            let original = try await service.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Valid Generic",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "http://localhost:\(client.port ?? 0)/v1",
                    apiKey: "sk-valid-generic",
                    enabled: true
                ),
                config: AppConfig()
            )

            do {
                _ = try await service.updateManualAPIKeyAccount(
                    id: original.id,
                    input: UpdateManualAPIKeyAccountRequest(
                        label: "Wrong Gemini Preset",
                        providerPreset: .genericOpenAICompatible,
                        baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
                        apiKey: "sk-gemini",
                        enabled: true
                    ),
                    config: AppConfig()
                )
                XCTFail("Expected Gemini root to be rejected for generic preset update")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Google Gemini OpenAI-compatible"))
                XCTAssertTrue(error.localizedDescription.contains("Google Gemini Compatible"))
            }
        }
    }

    func testManualAddAPIKeyAccountRejectsGoogleAIOAuthLikeCredentialForGeminiPreset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)

        do {
            _ = try await service.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Gemini AI Pro",
                    providerPreset: .googleGeminiCompatible,
                    baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
                    apiKey: "AQ.test-google-session",
                    enabled: true
                ),
                config: AppConfig()
            )
            XCTFail("Expected OAuth-like Google credential to be rejected for Gemini preset")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage))
        }
    }

    func testUpdateManualAPIKeyAccountRejectsGoogleAIOAuthLikeCredentialForGeminiPreset() async throws {
        let upstream = Self.makeOpenAICompatibleModelsApplication()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let service = try Self.makeAccountService(dataDirectory: directory)
            let original = try await service.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Valid Generic",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "http://localhost:\(client.port ?? 0)/v1",
                    apiKey: "sk-valid-generic",
                    enabled: true
                ),
                config: AppConfig()
            )

            do {
                _ = try await service.updateManualAPIKeyAccount(
                    id: original.id,
                    input: UpdateManualAPIKeyAccountRequest(
                        label: "Gemini AI Pro",
                        providerPreset: .googleGeminiCompatible,
                        baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
                        apiKey: "AQ.test-google-session",
                        enabled: true
                    ),
                    config: AppConfig()
                )
                XCTFail("Expected OAuth-like Google credential to be rejected for Gemini preset update")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage))
            }
        }
    }

    func testImportAuthJSONAccountsRejectsGoogleAIOAuthLikeCredentialForGeminiPreset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        let authJSON = try AuthService.normalizeManualAPIKeyInput(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "AQ.test-google-session",
            providerPreset: .googleGeminiCompatible
        )

        let result = try await service.importAuthJSONAccounts(
            items: [.init(source: "gemini-ai-pro.json", content: authJSON)],
            config: AppConfig()
        )

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].error.contains(OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage))
        let accounts = try await service.listAccounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testUpdateManualAPIKeyAccountRejectsNonAPIKeyAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        let record = try self.makeChatGPTAccountRecord(label: "OAuth Account")
        XCTAssertFalse(try store.upsertAccount(record))

        do {
            _ = try await service.updateManualAPIKeyAccount(
                id: record.id,
                input: UpdateManualAPIKeyAccountRequest(
                    label: "Edited",
                    baseURL: "https://api.openai.com/v1",
                    apiKey: "sk-updated",
                    enabled: true
                ),
                config: AppConfig()
            )
            XCTFail("Expected non-API-key account edit to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("仅支持编辑 API Key 类型账号"))
        }
    }

    func testManualAPIKeyAccountDetailsReturnsStoredSecretAndNormalizedBaseURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try self.makeManualAPIKeyRecord(
            baseURL: "https://example.com/proxy/v1",
            apiKey: "sk-stored-secret",
            label: "Stored API",
            providerPreset: .aliyunQwenCodingPlan
        )
        record.enabled = false
        XCTAssertFalse(try store.upsertAccount(record))

        let details = try service.manualAPIKeyAccountDetails(id: record.id)

        XCTAssertEqual(
            details,
            ManualAPIKeyAccountDetails(
                label: "Stored API",
                providerPreset: .aliyunQwenCodingPlan,
                baseURL: "https://example.com/proxy",
                apiKey: "sk-stored-secret",
                enabled: false
            )
        )
    }

    func testManualAPIKeyAccountDetailsUsesStoredGenericBaseURLWithoutModeAsExactPrefix() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        let authJSON = """
        {
          "auth_mode": "openai_api_key",
          "provider_preset": "generic_openai_compatible",
          "upstream_base_url": "https://legacy.example.com/proxy",
          "tokens": {
            "access_token": "sk-legacy-details"
          }
        }
        """
        let extracted = try AuthService.extractAuth(from: authJSON)
        var record = AccountRecord(
            label: "Stored Generic",
            principalID: extracted.principalID,
            email: nil,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            providerPreset: extracted.providerPreset,
            upstreamBaseURL: extracted.upstreamBaseURL,
            authJSON: authJSON
        )
        record.enabled = false
        XCTAssertFalse(try store.upsertAccount(record))

        let details = try service.manualAPIKeyAccountDetails(id: record.id)

        XCTAssertEqual(
            details,
            ManualAPIKeyAccountDetails(
                label: "Stored Generic",
                providerPreset: .genericOpenAICompatible,
                baseURL: "https://legacy.example.com/proxy",
                baseURLMode: .exactAPIPrefix,
                upstreamAdapter: .responses,
                upstreamThinkingCompatibility: .disabled,
                apiKey: "sk-legacy-details",
                enabled: false
            )
        )
    }

    func testManualAPIKeyAccountDetailsRejectsOAuthAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        let record = try self.makeChatGPTAccountRecord(label: "OAuth Account")
        XCTAssertFalse(try store.upsertAccount(record))

        XCTAssertThrowsError(try service.manualAPIKeyAccountDetails(id: record.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("仅支持 API Key 类型账号"))
        }
    }

    func testManualAPIKeyAccountDetailsRejectsMissingAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)

        XCTAssertThrowsError(try service.manualAPIKeyAccountDetails(id: "missing-account-id")) { error in
            XCTAssertTrue(error.localizedDescription.contains("读取现有账号时出错"))
        }
    }

    func testManualAddGenericOpenAICompatibleAPIKeyFallsBackToResponsesProbeWhenModelsMissing() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .genericOpenAICompatible
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let service = try Self.makeAccountService(dataDirectory: directory)
            let added = try await service.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Generic Fallback",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "http://localhost:\(client.port ?? 0)/v1",
                    apiKey: "sk-generic-fallback",
                    enabled: true
                ),
                config: AppConfig()
            )
            let snapshot = await probe.snapshot()

            XCTAssertEqual(added.authMode, .openAIAPIKey)
            XCTAssertEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.responsesBodies.count, 1)
            XCTAssertTrue(snapshot.responsesBodies[0].contains(#""model":"gpt-5.5""#))
            XCTAssertTrue(snapshot.responsesBodies[0].contains(#""input":"你好""#))
            XCTAssertTrue(snapshot.responsesBodies[0].contains(#""stream":false"#))
            XCTAssertTrue(snapshot.responsesBodies[0].contains(#""max_output_tokens":1"#))
        }
    }

    func testRefreshManualAPIKeyUsageSuccessClearsFailureState() async throws {
        let upstream = Self.makeOpenAICompatibleModelsApplication()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-refresh-success",
                label: "Refreshable API"
            )
            record.consecutiveFailureCount = 2
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

            XCTAssertEqual(refreshed.authMode, .openAIAPIKey)
            XCTAssertEqual(refreshed.consecutiveFailureCount, 0)
            XCTAssertNil(refreshed.cooldownUntil)
            XCTAssertNil(refreshed.usageError)
            XCTAssertFalse(refreshed.authRefreshBlocked)
            XCTAssertNil(refreshed.authRefreshError)

            let stored = try store.loadAccountRecord(id: record.id)
            XCTAssertEqual(stored.consecutiveFailureCount, 0)
            XCTAssertNil(stored.cooldownUntil)
            XCTAssertNil(stored.usageError)
            XCTAssertFalse(stored.authRefreshBlocked)
            XCTAssertNil(stored.authRefreshError)
        }
    }

    func testRefreshAllUsageSuccessClearsFailureStateForManualAPIKeyAccounts() async throws {
        let upstream = Self.makeOpenAICompatibleModelsApplication()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-refresh-all-success",
                label: "Refresh All API"
            )
            record.consecutiveFailureCount = 3
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshAllUsage(config: AppConfig())
            let updated = try XCTUnwrap(refreshed.first(where: { $0.id == record.id }))

            XCTAssertEqual(updated.authMode, .openAIAPIKey)
            XCTAssertEqual(updated.consecutiveFailureCount, 0)
            XCTAssertNil(updated.cooldownUntil)
            XCTAssertNil(updated.usageError)
            XCTAssertFalse(updated.authRefreshBlocked)
            XCTAssertNil(updated.authRefreshError)

            let stored = try store.loadAccountRecord(id: record.id)
            XCTAssertEqual(stored.consecutiveFailureCount, 0)
            XCTAssertNil(stored.cooldownUntil)
            XCTAssertNil(stored.usageError)
            XCTAssertFalse(stored.authRefreshBlocked)
            XCTAssertNil(stored.authRefreshError)
        }
    }

    func testRefreshAllUsageLimitsManualAPIKeyRefreshesToThreeConcurrentTasks() async throws {
        let probe = ConcurrentRequestProbe()
        let upstream = Self.makeDelayedOpenAICompatibleModelsApplication(probe: probe)

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            for index in 0..<5 {
                var record = try Self.makeManualAPIKeyRecordFixture(
                    baseURL: "http://localhost:\(client.port ?? 0)/v1",
                    apiKey: "sk-refresh-all-concurrent-\(index)",
                    label: "Concurrent API \(index)"
                )
                record.usageError = "previous error"
                XCTAssertFalse(try store.upsertAccount(record))
            }

            let refreshed = try await service.refreshAllUsage(config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertEqual(refreshed.count, 5)
            XCTAssertTrue(
                refreshed.allSatisfy { $0.usageError == nil },
                refreshed.compactMap(\.usageError).joined(separator: " | ")
            )
            XCTAssertEqual(snapshot.totalHits, 5)
            XCTAssertEqual(snapshot.maxActiveHits, 3)
        }
    }

    func testRefreshGenericManualAPIKeyFallbackValidationUsesAccountModelRoutingBeforePresetCandidates() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .genericOpenAICompatible
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-generic-routing",
                label: "Generic Routed API"
            )
            record.modelRouting = AccountModelRoutingConfig(
                mappings: [.init(sourceModel: "gpt-5.4", targetModel: "account-final-model")]
            )
            record.consecutiveFailureCount = 3
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(refreshed.consecutiveFailureCount, 0)
            XCTAssertNil(refreshed.cooldownUntil)
            XCTAssertEqual(snapshot.responsesBodies.count, 1)
            XCTAssertTrue(snapshot.responsesBodies[0].contains(#""model":"account-final-model""#))
            XCTAssertTrue(snapshot.responsesBodies[0].contains(#""input":"你好""#))
        }
    }

    func testRefreshGenericManualAPIKeyFallbackValidationRetriesNextModelWhenFirstCandidateUnsupported() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .genericOpenAICompatible,
            unsupportedModels: ["gpt-5.5"]
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-generic-retry",
                label: "Generic Retry API"
            )
            record.consecutiveFailureCount = 2
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(snapshot.responsesBodies.count, 2)
            XCTAssertTrue(snapshot.responsesBodies[0].contains(#""model":"gpt-5.5""#))
            XCTAssertTrue(snapshot.responsesBodies[1].contains(#""model":"gpt-5.4""#))
        }
    }

    func testRefreshGenericManualAPIKeyFallbackValidationHandlesNotImplementedModelsEndpoint() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .genericOpenAICompatible,
            modelsStatus: HTTPResponse.Status(code: 501, reasonPhrase: "Not Implemented")
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-generic-not-implemented",
                label: "Generic Not Implemented API"
            )
            record.usageError = "previous error"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.responsesBodies.count, 1)
        }
    }

    func testRefreshGenericManualAPIKeyFallbackValidationHandlesBadRequestModelsMissing() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .genericOpenAICompatible,
            modelsStatus: .badRequest
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-generic-models-missing",
                label: "Generic Models Missing API"
            )
            record.usageError = "previous error"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.responsesBodies.count, 1)
        }
    }

    func testRefreshGenericManualAPIKeyDoesNotFallbackForUnauthorizedModelsEndpoint() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .genericOpenAICompatible,
            modelsStatus: .unauthorized,
            modelsBody: #"{"error":{"message":"invalid api key"}}"#
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-generic-unauthorized",
                label: "Generic Unauthorized API"
            )
            record.usageError = "previous error"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertTrue(refreshed.usageError?.contains("invalid api key") == true)
            XCTAssertEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.responsesBodies.count, 0)
            XCTAssertEqual(snapshot.chatBodies.count, 0)
        }
    }

    func testRefreshGoogleGeminiManualAPIKeyFallbackValidationUsesChatCompletionsProbe() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .googleGeminiCompatible
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1beta/openai",
                apiKey: "sk-gemini-fallback",
                label: "Gemini Fallback API",
                providerPreset: .googleGeminiCompatible
            )
            record.consecutiveFailureCount = 2
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.chatBodies.count, 1)
            XCTAssertTrue(snapshot.chatBodies[0].contains(#""model":"gemini-2.5-flash""#))
            XCTAssertTrue(snapshot.chatBodies[0].contains(#""content":"你好""#))
        }
    }

    func testRefreshGoogleGeminiManualAPIKeyFallbackValidationHandlesBadRequestModelsMissing() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .googleGeminiCompatible,
            modelsStatus: .badRequest
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1beta/openai",
                apiKey: "sk-gemini-models-missing",
                label: "Gemini Models Missing API",
                providerPreset: .googleGeminiCompatible
            )
            record.usageError = "previous error"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.chatBodies.count, 1)
        }
    }

    func testRefreshAliyunManualAPIKeyValidationUsesHelloChatCompletionsProbe() async throws {
        let probe = ManualValidationProbe()
        let upstream = Self.makeOpenAICompatibleValidationFallbackApplication(
            probe: probe,
            providerPreset: .aliyunQwenCodingPlan
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-aliyun-validation",
                label: "Aliyun Validation API",
                providerPreset: .aliyunQwenCodingPlan
            )
            record.consecutiveFailureCount = 2
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())
            let snapshot = await probe.snapshot()

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(snapshot.modelsHits, 0)
            XCTAssertEqual(snapshot.chatBodies.count, 1)
            XCTAssertTrue(snapshot.chatBodies[0].contains(#""model":"qwen3-coder-plus""#))
            XCTAssertTrue(snapshot.chatBodies[0].contains(#""content":"你好""#))
        }
    }

    func testRefreshAnthropicManualAPIKeyFallbackValidationClearsFailureStateWhenModelsMissing() async throws {
        let upstream = Self.makeAnthropicValidationFallbackApplication(
            modelsStatus: .notFound,
            expectedMessagesModel: "qwen3.6-plus",
            expectedProbeText: "你好"
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-anthropic-refresh-success",
                label: "Anthropic Refreshable API",
                providerPreset: .anthropicAPICompatible
            )
            record.modelRouting = AccountModelRoutingConfig(defaultTargetModel: "qwen3.6-plus")
            record.consecutiveFailureCount = 3
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

            XCTAssertEqual(refreshed.authMode, .anthropicAPIKey)
            XCTAssertEqual(refreshed.consecutiveFailureCount, 0)
            XCTAssertNil(refreshed.cooldownUntil)
            XCTAssertNil(refreshed.usageError)

            let stored = try store.loadAccountRecord(id: record.id)
            XCTAssertEqual(stored.consecutiveFailureCount, 0)
            XCTAssertNil(stored.cooldownUntil)
            XCTAssertNil(stored.usageError)
        }
    }

    func testRefreshAllAnthropicManualAPIKeyFallbackValidationClearsFailureStateWhenModelsMissing() async throws {
        let upstream = Self.makeAnthropicValidationFallbackApplication(
            modelsStatus: .notFound,
            expectedMessagesModel: "qwen3.6-plus",
            expectedProbeText: "你好"
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-anthropic-refresh-all-success",
                label: "Anthropic Refresh All API",
                providerPreset: .anthropicAPICompatible
            )
            record.modelRouting = AccountModelRoutingConfig(defaultTargetModel: "qwen3.6-plus")
            record.consecutiveFailureCount = 3
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshAllUsage(config: AppConfig())
            let updated = try XCTUnwrap(refreshed.first(where: { $0.id == record.id }))

            XCTAssertEqual(updated.authMode, .anthropicAPIKey)
            XCTAssertEqual(updated.consecutiveFailureCount, 0)
            XCTAssertNil(updated.cooldownUntil)
            XCTAssertNil(updated.usageError)

            let stored = try store.loadAccountRecord(id: record.id)
            XCTAssertEqual(stored.consecutiveFailureCount, 0)
            XCTAssertNil(stored.cooldownUntil)
            XCTAssertNil(stored.usageError)
        }
    }

    func testRefreshAnthropicManualAPIKeyFallbackValidationHandlesBadRequestModelsMissing() async throws {
        let upstream = Self.makeAnthropicValidationFallbackApplication(
            modelsStatus: .badRequest,
            modelsBody: #"{"error":{"message":"models missing"}}"#,
            expectedMessagesModel: "qwen3.6-plus",
            expectedProbeText: "你好"
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-anthropic-models-missing",
                label: "Anthropic Models Missing API",
                providerPreset: .anthropicAPICompatible
            )
            record.modelRouting = AccountModelRoutingConfig(defaultTargetModel: "qwen3.6-plus")
            record.usageError = "previous error"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(refreshed.consecutiveFailureCount, 0)
            XCTAssertNil(refreshed.cooldownUntil)
        }
    }

    func testRefreshAnthropicManualAPIKeyKeepsFailureStateWhenFallbackValidationFails() async throws {
        let upstream = Self.makeAnthropicValidationFallbackApplication(
            modelsStatus: .notFound,
            messagesStatus: .badRequest,
            messagesBody: #"{"error":{"message":"model `qwen3.6-plus` is not supported."}}"#,
            expectedProbeText: "你好"
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-anthropic-refresh-failure",
                label: "Anthropic Broken API",
                providerPreset: .anthropicAPICompatible
            )
            record.modelRouting = AccountModelRoutingConfig(defaultTargetModel: "qwen3.6-plus")
            record.consecutiveFailureCount = 3
            record.cooldownUntil = Helpers.now() + 1_800
            record.usageError = "API key cooling down"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

            XCTAssertEqual(refreshed.authMode, .anthropicAPIKey)
            XCTAssertEqual(refreshed.consecutiveFailureCount, 3)
            XCTAssertEqual(refreshed.cooldownUntil, record.cooldownUntil)
            XCTAssertTrue(refreshed.usageError?.contains("qwen3.6-plus") == true)

            let stored = try store.loadAccountRecord(id: record.id)
            XCTAssertEqual(stored.consecutiveFailureCount, 3)
            XCTAssertEqual(stored.cooldownUntil, record.cooldownUntil)
            XCTAssertTrue(stored.usageError?.contains("qwen3.6-plus") == true)
        }
    }

    func testRefreshChatGPTOAuthUsageSuccessClearsStaleRefreshError() async throws {
        let upstream = Self.makeChatGPTUsageApplication(usagePlanType: "plus")
        let baseRecord: AccountRecord = try {
            var record = try self.makeChatGPTAccountRecord(label: "OAuth Account")
            record.authRefreshBlocked = true
            record.authRefreshError = "previous refresh error"
            record.usageError = "previous usage error"
            record.usageWindowsVisible = false
            return record
        }()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            XCTAssertFalse(try store.upsertAccount(baseRecord))

            var config = AppConfig()
            config.chatGPTBaseURL = "http://localhost:\(client.port ?? 0)"

            let refreshed = try await service.refreshUsage(id: baseRecord.id, config: config)

            XCTAssertEqual(refreshed.authMode, .chatGPT)
            XCTAssertFalse(refreshed.authRefreshBlocked)
            XCTAssertNil(refreshed.authRefreshError)
            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(refreshed.effectivePlanType, "plus")
            XCTAssertTrue(refreshed.usageWindowsVisible)

            let stored = try store.loadAccountRecord(id: baseRecord.id)
            XCTAssertFalse(stored.authRefreshBlocked)
            XCTAssertNil(stored.authRefreshError)
            XCTAssertNil(stored.usageError)
            XCTAssertEqual(stored.effectivePlanType, "plus")
            XCTAssertTrue(stored.usageWindowsVisible)
        }
    }

    func testRefreshChatGPTOAuthUsageFailureKeepsUsageWindowsHidden() async throws {
        let router = Router()
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .internalServerError,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"usage unavailable"}"#))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .internalServerError,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"usage unavailable"}"#))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .internalServerError,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"usage unavailable"}"#))
            )
        }
        let upstream = Application(router: router)
        let baseRecord: AccountRecord = try {
            var record = try self.makeChatGPTAccountRecord(label: "Hidden OAuth")
            record.usageWindowsVisible = false
            record.usage = UsageSnapshot(
                fetchedAt: Helpers.now(),
                planType: "plus",
                fiveHour: UsageWindow(usedPercent: 30, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 40, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            )
            return record
        }()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            XCTAssertFalse(try store.upsertAccount(baseRecord))

            var config = AppConfig()
            config.chatGPTBaseURL = "http://localhost:\(client.port ?? 0)"

            let refreshed = try await service.refreshUsage(id: baseRecord.id, config: config)

            XCTAssertFalse(refreshed.usageWindowsVisible)
            XCTAssertTrue(refreshed.usageError?.contains("usage unavailable") == true)

            let stored = try store.loadAccountRecord(id: baseRecord.id)
            XCTAssertFalse(stored.usageWindowsVisible)
            XCTAssertTrue(stored.usageError?.contains("usage unavailable") == true)
        }
    }

    func testRefreshChatGPTOAuthUsageLimitKeepsQuotaIssueAndClearsStaleRefreshError() async throws {
        let resetAt: Int64 = Helpers.now() + 604_800
        let upstream = Self.makeChatGPTUsageLimitApplication(resetAt: resetAt)
        let baseRecord: AccountRecord = try {
            var record = try self.makeChatGPTAccountRecord(label: "Quota OAuth")
            record.authRefreshBlocked = true
            record.authRefreshError = "previous refresh error"
            record.usageError = "previous usage error"
            record.usageWindowsVisible = false
            return record
        }()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            XCTAssertFalse(try store.upsertAccount(baseRecord))

            var config = AppConfig()
            config.chatGPTBaseURL = "http://localhost:\(client.port ?? 0)"

            let refreshed = try await service.refreshUsage(id: baseRecord.id, config: config)

            XCTAssertEqual(
                refreshed.usageError,
                "usage_limit_reached, plan=free, resets_at=\(FixedDisplayDateTimeFormat.string(fromUnixSeconds: resetAt))"
            )
            XCTAssertFalse(refreshed.authRefreshBlocked)
            XCTAssertNil(refreshed.authRefreshError)
            XCTAssertEqual(refreshed.usage?.oneWeek?.usedPercent, 100)
            XCTAssertEqual(refreshed.usage?.oneWeek?.resetAt, resetAt)
            XCTAssertTrue(refreshed.usageWindowsVisible)

            let stored = try store.loadAccountRecord(id: baseRecord.id)
            XCTAssertEqual(
                stored.usageError,
                "usage_limit_reached, plan=free, resets_at=\(FixedDisplayDateTimeFormat.string(fromUnixSeconds: resetAt))"
            )
            XCTAssertFalse(stored.authRefreshBlocked)
            XCTAssertNil(stored.authRefreshError)
            XCTAssertEqual(stored.usage?.oneWeek?.usedPercent, 100)
            XCTAssertEqual(stored.usage?.oneWeek?.resetAt, resetAt)
            XCTAssertTrue(stored.usageWindowsVisible)
        }
    }

    func testRefreshManualAPIKeyUsageFailureKeepsFailureState() async throws {
        let upstream = Self.makeOpenAICompatibleModelsApplication(
            status: HTTPResponse.Status.internalServerError,
            errorMessage: "models unavailable"
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            let expectedCooldown = Helpers.now() + 1_800
            var record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-refresh-failure",
                label: "Failing API"
            )
            record.consecutiveFailureCount = 2
            record.cooldownUntil = expectedCooldown
            record.usageError = "previous error"
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

            XCTAssertEqual(refreshed.authMode, .openAIAPIKey)
            XCTAssertEqual(refreshed.consecutiveFailureCount, 2)
            XCTAssertEqual(refreshed.cooldownUntil, expectedCooldown)
            XCTAssertTrue(refreshed.usageError?.contains("models unavailable") == true)

            let stored = try store.loadAccountRecord(id: record.id)
            XCTAssertEqual(stored.consecutiveFailureCount, 2)
            XCTAssertEqual(stored.cooldownUntil, expectedCooldown)
            XCTAssertTrue(stored.usageError?.contains("models unavailable") == true)
        }
    }

    func testStopAccountCooldownClearsAPIKeyFailureStateAndCoolingUsageError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try Self.makeManualAPIKeyRecordFixture(
            baseURL: "https://example.com/v1",
            apiKey: "sk-stop-cooldown",
            label: "Cooling API"
        )
        record.consecutiveFailureCount = 3
        record.cooldownUntil = Helpers.now() + 3_600
        record.usageError = "API key cooling down"
        XCTAssertFalse(try store.upsertAccount(record))

        let updated = try await service.stopAccountCooldown(id: record.id)

        XCTAssertEqual(updated.consecutiveFailureCount, 0)
        XCTAssertNil(updated.cooldownUntil)
        XCTAssertNil(updated.usageError)

        let stored = try store.loadAccountRecord(id: record.id)
        XCTAssertEqual(stored.consecutiveFailureCount, 0)
        XCTAssertNil(stored.cooldownUntil)
        XCTAssertNil(stored.usageError)
    }

    func testStopAccountCooldownKeepsNonCoolingUsageError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try Self.makeManualAPIKeyRecordFixture(
            baseURL: "https://example.com/v1",
            apiKey: "sk-stop-cooldown-keeps-error",
            label: "Cooling API With Error"
        )
        record.consecutiveFailureCount = 3
        record.cooldownUntil = Helpers.now() + 3_600
        record.usageError = "models unavailable"
        XCTAssertFalse(try store.upsertAccount(record))

        let updated = try await service.stopAccountCooldown(id: record.id)

        XCTAssertEqual(updated.consecutiveFailureCount, 0)
        XCTAssertNil(updated.cooldownUntil)
        XCTAssertEqual(updated.usageError, "models unavailable")
    }

    func testStopAccountCooldownRejectsNonAPIKeyAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try self.makeChatGPTAccountRecord(label: "OAuth Account")
        record.consecutiveFailureCount = 3
        record.cooldownUntil = Helpers.now() + 3_600
        XCTAssertFalse(try store.upsertAccount(record))

        do {
            _ = try await service.stopAccountCooldown(id: record.id)
            XCTFail("Expected non-API-key cooldown stop to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("仅支持 API Key 类型账号"))
        }
    }

    func testRefreshManualAPIKeyUsageFallsBackToGeminiConfigurationErrorForDamagedLegacyRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try Self.makeLegacyGenericGeminiManualAPIKeyRecordFixture(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "sk-gemini-broken-refresh",
            label: "Broken Legacy Gemini"
        )
        record.authJSON = "{"
        XCTAssertFalse(try store.upsertAccount(record))

        let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

        XCTAssertEqual(
            refreshed.usageError,
            OpenAICompatibleUpstream.geminiCompatibilityRootRequiresGeminiPresetMessage
        )
    }

    func testRefreshManualAPIKeyUsageReturnsGoogleGeminiAPIKeyOnlyErrorForStoredOAuthLikeCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        let record = try Self.makeManualAPIKeyRecordFixture(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "AQ.test-google-session",
            label: "Gemini OAuth-like",
            providerPreset: .googleGeminiCompatible
        )
        XCTAssertFalse(try store.upsertAccount(record))

        let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

        XCTAssertEqual(refreshed.usageError, OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage)
    }

    func testListAccountsRepairsStoredGoogleGeminiOAuthLikeUsageErrorToUnifiedUnsupportedMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try Self.makeManualAPIKeyRecordFixture(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "AQ.test-google-session",
            label: "Gemini OAuth-like",
            providerPreset: .googleGeminiCompatible
        )
        record.usageError = "Multiple authentication credentials received. Please pass only one."
        XCTAssertFalse(try store.upsertAccount(record))

        let accounts = try await service.listAccounts()
        let account = try XCTUnwrap(accounts.first(where: { $0.id == record.id }))
        let persisted = try store.loadAccountRecord(id: record.id)

        XCTAssertEqual(account.usageError, OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage)
        XCTAssertEqual(persisted.usageError, OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage)
    }

    func testExtractAuthLoadsGoogleAIProGeminiSecretBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let secretRef = try secretStore.saveGeminiOAuthSecret(
            GeminiOAuthSecretBundle(
                accessToken: "gemini-access-token",
                refreshToken: "gemini-refresh-token",
                expiresAt: Helpers.now() + 3_600,
                tokenType: "Bearer",
                scope: GeminiAuthService.defaultOAuthScopes
            )
        )
        let authJSON = Self.geminiOAuthAuthJSON(
            secretRef: secretRef,
            baseURL: GeminiAuthService.defaultCodeAssistEndpoint,
            projectID: "gemini-project"
        )

        let extracted = try AuthService.extractAuth(from: authJSON, secretStore: secretStore)

        XCTAssertEqual(extracted.providerFamily, AccountProviderFamily.gemini)
        XCTAssertEqual(extracted.authMode, AccountAuthMode.geminiOAuth)
        XCTAssertEqual(extracted.accessToken, "gemini-access-token")
        XCTAssertEqual(extracted.refreshToken, "gemini-refresh-token")
        XCTAssertEqual(extracted.upstreamBaseURL, GeminiAuthService.defaultCodeAssistEndpoint)
        XCTAssertEqual(AuthService.geminiAuthBackend(from: authJSON), GeminiAuthService.googleAIProBackend)
        XCTAssertFalse(AuthService.authNeedsRefresh(authJSON, secretStore: secretStore))
    }

    func testListAccountsPurgesLegacyGeminiOAuthAccountsAndSecrets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let secretRef = try secretStore.saveGeminiOAuthSecret(
            GeminiOAuthSecretBundle(
                accessToken: "legacy-access-token",
                refreshToken: "legacy-refresh-token",
                expiresAt: Helpers.now() + 3_600,
                tokenType: "Bearer",
                scope: GeminiAuthService.defaultOAuthScopes
            )
        )
        let legacyAuthJSON = """
        {
          "auth_mode": "gemini_api_oauth",
          "provider_family": "gemini",
          "secret_ref": "\(secretRef)",
          "principal_id": "legacy-gemini-principal",
          "account_id": "legacy-gemini-account",
          "email": "legacy@example.com",
          "plan_type": "gemini_oauth",
          "oauth_client_id": "legacy-client",
          "oauth_scopes": "\(GeminiAuthService.defaultOAuthScopes)",
          "upstream_base_url": "https://generativelanguage.googleapis.com"
        }
        """
        XCTAssertFalse(
            try store.upsertAccount(
                AccountRecord(
                    label: "Legacy Gemini OAuth",
                    principalID: "legacy-gemini-principal",
                    email: "legacy@example.com",
                    accountID: "legacy-gemini-account",
                    planType: "gemini_oauth",
                    authMode: .geminiOAuth,
                    upstreamBaseURL: "https://generativelanguage.googleapis.com",
                    authJSON: legacyAuthJSON
                )
            )
        )

        let service = AccountService(store: store, secretStore: secretStore)
        let accounts = try await service.listAccounts()

        XCTAssertTrue(accounts.isEmpty)
        XCTAssertNil(secretStore.loadGeminiOAuthSecretIfPresent(ref: secretRef))
    }

    func testRefreshGeminiOAuthUsageValidatesConnectionWithoutWindowUsage() async throws {
        let upstream = Self.makeGeminiOAuthProviderApplication()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let service = AccountService(store: store, secretStore: secretStore)
            let secretRef = try secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            let record = try Self.makeGeminiOAuthAccountRecordFixture(
                secretRef: secretRef,
                baseURL: "http://localhost:\(client.port ?? 0)",
                label: "Gemini OAuth",
                projectID: "gemini-project"
            )
            XCTAssertFalse(try store.upsertAccount(record))

            let refreshed = try await service.refreshUsage(id: record.id, config: AppConfig())

            XCTAssertEqual(refreshed.authMode, .geminiOAuth)
            XCTAssertNil(refreshed.usage)
            XCTAssertNil(refreshed.usageError)
            XCTAssertFalse(refreshed.authRefreshBlocked)
            XCTAssertNil(refreshed.authRefreshError)

            let stored = try store.loadAccountRecord(id: record.id)
            XCTAssertNil(stored.usage)
            XCTAssertNil(stored.usageError)
            XCTAssertTrue(stored.usageWindowsVisible)
        }
    }

    func testRefreshGeminiOAuthAuthUpdatesSecretBundle() async throws {
        let upstream = Self.makeGeminiOAuthProviderApplication()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let secretRef = try secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-stale",
                    refreshToken: "gemini-refresh-seed",
                    expiresAt: Helpers.now() - 120,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            let refreshed = try await AuthService.refreshAuth(
                Self.geminiOAuthAuthJSON(
                    secretRef: secretRef,
                    baseURL: "http://localhost:\(client.port ?? 0)",
                    projectID: "gemini-project",
                    tokenURL: "http://localhost:\(client.port ?? 0)/token"
                ),
                config: AppConfig(),
                secretStore: secretStore
            )

            let extracted = try AuthService.extractAuth(from: refreshed, secretStore: secretStore)
            let bundle = try secretStore.loadGeminiOAuthSecret(ref: secretRef)

            XCTAssertEqual(extracted.accessToken, "gemini-access-refresh-gemini-refresh-seed")
            XCTAssertEqual(bundle.accessToken, "gemini-access-refresh-gemini-refresh-seed")
            XCTAssertEqual(bundle.refreshToken, "gemini-refresh-rotated-gemini-refresh-seed")
            XCTAssertFalse(AuthService.authNeedsRefresh(refreshed, secretStore: secretStore))
        }
    }

    func testCompleteGoogleAIProOAuthCallbackStoresBackendAndEligibility() async throws {
        let upstream = Self.makeGeminiOAuthProviderApplication()

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let pending = PendingOAuthLogin(
                providerFamily: .gemini,
                redirectURI: "http://localhost:1455\(AuthService.geminiOAuthCallbackPath)",
                state: "state-test",
                codeVerifier: "code-verifier-test",
                expiresAt: Helpers.now() + 60
            )

            let authJSON = try await GeminiAuthService.completeOAuthCallback(
                pending: pending,
                callbackURL: "\(pending.redirectURI)?code=browser-success&state=\(pending.state)",
                config: AppConfig(),
                secretStore: secretStore,
                tokenURLOverride: "http://localhost:\(client.port ?? 0)/token",
                codeAssistBaseURLOverride: "http://localhost:\(client.port ?? 0)",
                userInfoURLOverride: "http://localhost:\(client.port ?? 0)/userinfo"
            )

            let extracted = try AuthService.extractAuth(from: authJSON, secretStore: secretStore)

            XCTAssertEqual(extracted.providerFamily, AccountProviderFamily.gemini)
            XCTAssertEqual(extracted.authMode, AccountAuthMode.geminiOAuth)
            XCTAssertEqual(extracted.accessToken, "gemini-access-browser-success")
            XCTAssertEqual(extracted.refreshToken, "gemini-refresh-browser-success")
            XCTAssertEqual(extracted.email, "gemini@example.com")
            XCTAssertEqual(AuthService.geminiAuthBackend(from: authJSON), GeminiAuthService.googleAIProBackend)
            XCTAssertEqual(GeminiAuthService.projectID(fromAuthJSON: authJSON), "gemini-project")
        }
    }

    func testCompleteGoogleGeminiOAuthCallbackAutoOnboardsPersonalTier() async throws {
        let probe = GeminiOAuthProviderProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(
            loadCodeAssistResponses: [
                """
                {
                  "allowedTiers": [
                    {
                      "id": "personal_free",
                      "name": "Personal Free",
                      "isDefault": true,
                      "userDefinedCloudaicompanionProject": false
                    }
                  ]
                }
                """,
                """
                {
                  "currentTier": {
                    "id": "personal_free",
                    "name": "Personal Free",
                    "userDefinedCloudaicompanionProject": false
                  },
                  "allowedTiers": [
                    {
                      "id": "personal_free",
                      "name": "Personal Free",
                      "isDefault": true,
                      "userDefinedCloudaicompanionProject": false
                    }
                  ],
                  "cloudaicompanionProject": "gemini-personal-project"
                }
                """
            ],
            onboardResponse: #"{"name":"operations/onboard-personal-free"}"#,
            operationResponses: [
                #"{"name":"operations/onboard-personal-free","done":true,"response":{"cloudaicompanionProject":{"id":"gemini-personal-project"}}}"#
            ],
            probe: probe
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let pending = PendingOAuthLogin(
                providerFamily: .gemini,
                redirectURI: "http://localhost:1455\(AuthService.geminiOAuthCallbackPath)",
                state: "state-test",
                codeVerifier: "code-verifier-test",
                expiresAt: Helpers.now() + 60
            )

            let authJSON = try await GeminiAuthService.completeOAuthCallback(
                pending: pending,
                callbackURL: "\(pending.redirectURI)?code=browser-success&state=\(pending.state)",
                config: AppConfig(),
                secretStore: secretStore,
                tokenURLOverride: "http://localhost:\(client.port ?? 0)/token",
                codeAssistBaseURLOverride: "http://localhost:\(client.port ?? 0)",
                userInfoURLOverride: "http://localhost:\(client.port ?? 0)/userinfo"
            )

            let extracted = try AuthService.extractAuth(from: authJSON, secretStore: secretStore)
            let snapshot = await probe.snapshot()

            XCTAssertEqual(extracted.planType, "free")
            XCTAssertEqual(GeminiAuthService.projectID(fromAuthJSON: authJSON), "gemini-personal-project")
            XCTAssertEqual(snapshot.loadCodeAssistHits, 2)
            XCTAssertEqual(snapshot.onboardUserHits, 1)
            XCTAssertEqual(snapshot.operationPollHits, 1)
        }
    }

    func testCompleteGoogleGeminiOAuthCallbackRejectsWorkspaceProjectRequiredAccount() async throws {
        let upstream = Self.makeGeminiOAuthProviderApplication(
            validationBody: """
            {
              "currentTier": {
                "id": "workspace_enterprise",
                "name": "Workspace Enterprise",
                "userDefinedCloudaicompanionProject": true
              },
              "allowedTiers": [
                {
                  "id": "workspace_enterprise",
                  "name": "Workspace Enterprise",
                  "userDefinedCloudaicompanionProject": true
                }
              ]
            }
            """
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let pending = PendingOAuthLogin(
                providerFamily: .gemini,
                redirectURI: "http://localhost:1455\(AuthService.geminiOAuthCallbackPath)",
                state: "state-test",
                codeVerifier: "code-verifier-test",
                expiresAt: Helpers.now() + 60
            )

            do {
                _ = try await GeminiAuthService.completeOAuthCallback(
                    pending: pending,
                    callbackURL: "\(pending.redirectURI)?code=browser-success&state=\(pending.state)",
                    config: AppConfig(),
                    secretStore: secretStore,
                    tokenURLOverride: "http://localhost:\(client.port ?? 0)/token",
                    codeAssistBaseURLOverride: "http://localhost:\(client.port ?? 0)",
                    userInfoURLOverride: "http://localhost:\(client.port ?? 0)/userinfo"
                )
                XCTFail("Expected Workspace / project-required account to be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("组织 / Workspace"), error.localizedDescription)
            }
        }
    }

    func testCompleteGoogleGeminiOAuthCallbackAcceptsReturnedProjectForGoogleOneTier() async throws {
        let upstream = Self.makeGeminiOAuthProviderApplication(
            validationBody: """
            {
              "currentTier": {
                "id": "standard-tier",
                "name": "Gemini Code Assist",
                "userDefinedCloudaicompanionProject": true
              },
              "allowedTiers": [
                {
                  "id": "standard-tier",
                  "name": "Gemini Code Assist",
                  "isDefault": true,
                  "userDefinedCloudaicompanionProject": true
                }
              ],
              "cloudaicompanionProject": "substantial-vertex-tqb1d",
              "paidTier": {
                "id": "g1-pro-tier",
                "name": "Gemini Code Assist in Google One AI Pro"
              }
            }
            """
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let pending = PendingOAuthLogin(
                providerFamily: .gemini,
                redirectURI: "http://localhost:1455\(AuthService.geminiOAuthCallbackPath)",
                state: "state-test",
                codeVerifier: "code-verifier-test",
                expiresAt: Helpers.now() + 60
            )

            let authJSON = try await GeminiAuthService.completeOAuthCallback(
                pending: pending,
                callbackURL: "\(pending.redirectURI)?code=browser-success&state=\(pending.state)",
                config: AppConfig(),
                secretStore: secretStore,
                tokenURLOverride: "http://localhost:\(client.port ?? 0)/token",
                codeAssistBaseURLOverride: "http://localhost:\(client.port ?? 0)",
                userInfoURLOverride: "http://localhost:\(client.port ?? 0)/userinfo"
            )

            let extracted = try AuthService.extractAuth(from: authJSON, secretStore: secretStore)

            XCTAssertEqual(extracted.planType, "google_ai_pro")
            XCTAssertEqual(GeminiAuthService.projectID(fromAuthJSON: authJSON), "substantial-vertex-tqb1d")
        }
    }

    func testValidateConnectionForGeminiOAuthDoesNotTriggerOnboarding() async throws {
        let probe = GeminiOAuthProviderProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(
            loadCodeAssistResponses: [
                """
                {
                  "allowedTiers": [
                    {
                      "id": "personal_free",
                      "name": "Personal Free",
                      "isDefault": true,
                      "userDefinedCloudaicompanionProject": false
                    }
                  ]
                }
                """
            ],
            probe: probe
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let secretRef = try secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            let authJSON = Self.geminiOAuthAuthJSON(
                secretRef: secretRef,
                baseURL: "http://localhost:\(client.port ?? 0)",
                projectID: "stale-project"
            )
            let extracted = try AuthService.extractAuth(from: authJSON, secretStore: secretStore)

            do {
                _ = try await GeminiAuthService.validateConnection(
                    auth: extracted,
                    authJSON: authJSON,
                    config: AppConfig()
                )
                XCTFail("Expected validateConnection to fail without onboarding")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("尚未完成初始化"), error.localizedDescription)
            }

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.loadCodeAssistHits, 1)
            XCTAssertEqual(snapshot.onboardUserHits, 0)
            XCTAssertEqual(snapshot.operationPollHits, 0)
        }
    }

    func testValidateConnectionForGeminiOAuthAcceptsReturnedProjectForGoogleOneTier() async throws {
        let upstream = Self.makeGeminiOAuthProviderApplication(
            validationBody: """
            {
              "currentTier": {
                "id": "standard-tier",
                "name": "Gemini Code Assist",
                "userDefinedCloudaicompanionProject": true
              },
              "allowedTiers": [
                {
                  "id": "standard-tier",
                  "name": "Gemini Code Assist",
                  "isDefault": true,
                  "userDefinedCloudaicompanionProject": true
                }
              ],
              "cloudaicompanionProject": "substantial-vertex-tqb1d",
              "paidTier": {
                "id": "g1-pro-tier",
                "name": "Gemini Code Assist in Google One AI Pro"
              }
            }
            """
        )

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let secretRef = try secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            let authJSON = """
            {
              "auth_mode": "gemini_api_oauth",
              "provider_family": "gemini",
              "gemini_auth_backend": "\(GeminiAuthService.googleAIProBackend)",
              "secret_ref": "\(secretRef)",
              "principal_id": "gemini-principal",
              "account_id": "gemini-account",
              "email": "gemini@example.com",
              "plan_type": "free",
              "oauth_client_id": "\(GeminiAuthService.defaultOAuthClientID)",
              "oauth_scopes": "\(GeminiAuthService.defaultOAuthScopes)",
              "oauth_authorize_url": "\(GeminiAuthService.defaultAuthorizeURL)",
              "oauth_token_url": "http://localhost:\(client.port ?? 0)/token",
              "upstream_base_url": "http://localhost:\(client.port ?? 0)"
            }
            """
            let extracted = try AuthService.extractAuth(from: authJSON, secretStore: secretStore)

            let validated = try await GeminiAuthService.validateConnection(
                auth: extracted,
                authJSON: authJSON,
                config: AppConfig()
            )

            XCTAssertEqual(GeminiAuthService.projectID(fromAuthJSON: validated), "substantial-vertex-tqb1d")
            XCTAssertTrue(validated.contains(#""plan_type":"google_ai_pro""#), validated)
        }
    }

    func testRepairStoredManualAccountsRepairsLegacyGeminiPresetWithoutChangingIdentityOrCachedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try Self.makeLegacyGenericGeminiManualAPIKeyRecordFixture(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "sk-gemini-repair",
            label: "Legacy Gemini"
        )
        record.selectionOrder = 7
        record.usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "api_key",
            fiveHour: nil,
            oneWeek: nil,
            credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "21.00")
        )
        record.usageError = "previous error"
        XCTAssertFalse(try store.upsertAccount(record))

        XCTAssertEqual(try service.repairStoredManualAccountsIfNeeded(), 1)

        let repaired = try store.loadAccountRecord(id: record.id)
        XCTAssertEqual(repaired.id, record.id)
        XCTAssertEqual(repaired.accountKey, record.accountKey)
        XCTAssertEqual(repaired.selectionOrder, record.selectionOrder)
        XCTAssertEqual(repaired.usage, record.usage)
        XCTAssertEqual(repaired.usageError, record.usageError)
        XCTAssertEqual(repaired.providerPreset, .googleGeminiCompatible)
        XCTAssertEqual(AuthService.extractAuthMetadata(from: repaired.authJSON).providerPreset, .googleGeminiCompatible)
    }

    func testUpdateAccountLabelRenamesOAuthAccountWithoutChangingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try self.makeChatGPTAccountRecord(label: "Old OAuth Name")
        record.enabled = false
        record.usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "plus",
            fiveHour: UsageWindow(usedPercent: 30, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 40, windowSeconds: 604_800, resetAt: nil),
            credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "10.00")
        )
        record.usageError = "known usage issue"
        XCTAssertFalse(try store.upsertAccount(record))

        let updated = try await service.updateAccountLabel(
            id: record.id,
            input: UpdateAccountLabelRequest(label: "Renamed OAuth")
        )

        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.accountKey, record.accountKey)
        XCTAssertEqual(updated.label, "Renamed OAuth")
        XCTAssertEqual(updated.enabled, record.enabled)
        XCTAssertEqual(updated.usage, record.usage)
        XCTAssertEqual(updated.usageError, record.usageError)

        let stored = try store.loadAccountRecord(id: record.id)
        XCTAssertEqual(stored.id, record.id)
        XCTAssertEqual(stored.accountKey, record.accountKey)
        XCTAssertEqual(stored.label, "Renamed OAuth")
        XCTAssertEqual(stored.enabled, record.enabled)
        XCTAssertEqual(stored.usage, record.usage)
    }

    func testUpdateAccountLabelRejectsAPIKeyAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        let record = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-label-test",
            label: "API Key"
        )
        XCTAssertFalse(try store.upsertAccount(record))

        do {
            _ = try await service.updateAccountLabel(
                id: record.id,
                input: UpdateAccountLabelRequest(label: "Should Fail")
            )
            XCTFail("Expected API key rename to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("仅支持修改 OAuth 类型账号名称"))
        }
    }

    func testUpdateManualAPIKeyAccountKeepsIdentityAndCachedStateWhenNormalizedIdentityMatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-same-identity",
            label: "Original API"
        )
        record.usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "api_key",
            fiveHour: nil,
            oneWeek: nil,
            credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "12.34")
        )
        record.usageError = "previous usage error"
        record.authRefreshBlocked = true
        record.authRefreshError = "refresh blocked"
        record.selectionOrder = 4
        record.consecutiveFailureCount = 2
        record.cooldownUntil = Helpers.now() + 1_800
        XCTAssertFalse(try store.upsertAccount(record))

        let updated = try await service.updateManualAPIKeyAccount(
            id: record.id,
            input: UpdateManualAPIKeyAccountRequest(
                label: "Renamed API",
                baseURL: "https://api.openai.com/v1",
                apiKey: "sk-same-identity",
                enabled: false
            ),
            config: AppConfig()
        )

        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.accountKey, record.accountKey)
        XCTAssertEqual(updated.label, "Renamed API")
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.usage, record.usage)
        XCTAssertEqual(updated.usageError, record.usageError)
        XCTAssertEqual(updated.authRefreshBlocked, record.authRefreshBlocked)
        XCTAssertEqual(updated.authRefreshError, record.authRefreshError)
        XCTAssertEqual(updated.selectionOrder, record.selectionOrder)
        XCTAssertEqual(updated.consecutiveFailureCount, record.consecutiveFailureCount)
        XCTAssertEqual(updated.cooldownUntil, record.cooldownUntil)

        let stored = try store.loadAccountRecord(id: record.id)
        XCTAssertEqual(stored.accountKey, record.accountKey)
        XCTAssertEqual(stored.label, "Renamed API")
        XCTAssertFalse(stored.enabled)
        XCTAssertEqual(stored.usage, record.usage)
        XCTAssertEqual(stored.usageError, record.usageError)
        XCTAssertEqual(stored.authRefreshBlocked, record.authRefreshBlocked)
        XCTAssertEqual(stored.authRefreshError, record.authRefreshError)
        XCTAssertEqual(stored.selectionOrder, record.selectionOrder)
        XCTAssertEqual(stored.consecutiveFailureCount, record.consecutiveFailureCount)
        XCTAssertEqual(stored.cooldownUntil, record.cooldownUntil)
    }

    func testUpdateManualAPIKeyAccountReplacesIdentityWithoutMigratingExistingLogsOrStats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-old-identity",
            label: "Old API"
        )
        record.usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "api_key",
            fiveHour: nil,
            oneWeek: nil,
            credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "98.76")
        )
        record.usageError = "old usage error"
        record.authRefreshBlocked = true
        record.authRefreshError = "old refresh error"
        record.selectionOrder = 7
        record.consecutiveFailureCount = 3
        record.cooldownUntil = Helpers.now() + 3_600
        XCTAssertFalse(try store.upsertAccount(record))

        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("proxy-key-old"),
                accountKey: record.accountKey,
                accountLabel: record.label,
                model: "gpt-5.4",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 120, outputTokens: 45, totalTokens: 165, cacheHitTokens: nil),
                timestamp: Helpers.now(),
                apiKeyValue: "proxy-key-old"
            )
        )

        let updated = try await service.updateManualAPIKeyAccount(
            id: record.id,
            input: UpdateManualAPIKeyAccountRequest(
                label: "New API",
                baseURL: "https://example.com/proxy/v1",
                apiKey: "sk-new-identity",
                enabled: true
            ),
            config: AppConfig()
        )

        XCTAssertEqual(updated.id, record.id)
        XCTAssertNotEqual(updated.accountKey, record.accountKey)
        XCTAssertEqual(updated.label, "New API")
        XCTAssertNil(updated.usage)
        XCTAssertEqual(updated.todayTokenUsage, AccountTodayTokenUsage())
        XCTAssertNil(updated.usageError)
        XCTAssertFalse(updated.authRefreshBlocked)
        XCTAssertNil(updated.authRefreshError)
        XCTAssertEqual(updated.selectionOrder, record.selectionOrder)
        XCTAssertEqual(updated.consecutiveFailureCount, 0)
        XCTAssertNil(updated.cooldownUntil)

        let stored = try store.loadAccountRecord(id: record.id)
        XCTAssertEqual(stored.id, record.id)
        XCTAssertNotEqual(stored.accountKey, record.accountKey)
        XCTAssertNil(stored.usage)
        XCTAssertNil(stored.usageError)
        XCTAssertFalse(stored.authRefreshBlocked)
        XCTAssertNil(stored.authRefreshError)
        XCTAssertEqual(stored.selectionOrder, record.selectionOrder)
        XCTAssertEqual(stored.consecutiveFailureCount, 0)
        XCTAssertNil(stored.cooldownUntil)

        let logs = try store.loadAllRequestLogs(query: RequestLogQuery())
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].accountKey, record.accountKey)
    }

    func testUpdateManualAPIKeyAccountChangingBaseURLWithSameAPIKeyReplacesIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        var record = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-shared-secret",
            label: "Old Base URL"
        )
        record.usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "api_key",
            fiveHour: nil,
            oneWeek: nil,
            credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "55.00")
        )
        record.authRefreshBlocked = true
        record.authRefreshError = "refresh blocked"
        XCTAssertFalse(try store.upsertAccount(record))

        let updated = try await service.updateManualAPIKeyAccount(
            id: record.id,
            input: UpdateManualAPIKeyAccountRequest(
                label: "New Base URL",
                baseURL: "https://example.com/proxy/v1",
                apiKey: "sk-shared-secret",
                enabled: true
            ),
            config: AppConfig()
        )

        XCTAssertEqual(updated.id, record.id)
        XCTAssertNotEqual(updated.accountKey, record.accountKey)
        XCTAssertEqual(updated.label, "New Base URL")
        XCTAssertEqual(updated.upstreamBaseURL, "https://example.com/proxy/v1")
        XCTAssertNil(updated.usage)
        XCTAssertFalse(updated.authRefreshBlocked)
        XCTAssertNil(updated.authRefreshError)
    }

    func testUpdateManualAPIKeyAccountRejectsDuplicateReplacementIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let service = AccountService(store: store, secretStore: secretStore)
        let first = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-first",
            label: "First API"
        )
        let second = try self.makeManualAPIKeyRecord(
            baseURL: "https://example.com/proxy/v1",
            apiKey: "sk-second",
            label: "Second API"
        )
        XCTAssertFalse(try store.upsertAccount(first))
        XCTAssertFalse(try store.upsertAccount(second))

        do {
            _ = try await service.updateManualAPIKeyAccount(
                id: first.id,
                input: UpdateManualAPIKeyAccountRequest(
                    label: "Conflicting API",
                    baseURL: "https://example.com/proxy/v1",
                    apiKey: "sk-second",
                    enabled: true
                ),
                config: AppConfig()
            )
            XCTFail("Expected duplicate replacement identity to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已存在相同的 API Key 账号"))
        }

        let reloadedFirst = try store.loadAccountRecord(id: first.id)
        let reloadedSecond = try store.loadAccountRecord(id: second.id)
        XCTAssertEqual(reloadedFirst.accountKey, first.accountKey)
        XCTAssertEqual(reloadedSecond.accountKey, second.accountKey)
    }

    func testSQLiteStoreReorderAccountsRequiresFullUniqueIDsAndCompactsAfterDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let first = try self.makeManualAPIKeyRecord(baseURL: "https://api.openai.com/v1", apiKey: "sk-order-1", label: "First")
        let second = try self.makeManualAPIKeyRecord(baseURL: "https://api.openai.com/v1", apiKey: "sk-order-2", label: "Second")
        let third = try self.makeManualAPIKeyRecord(baseURL: "https://api.openai.com/v1", apiKey: "sk-order-3", label: "Third")

        XCTAssertFalse(try store.upsertAccount(first))
        XCTAssertFalse(try store.upsertAccount(second))
        XCTAssertFalse(try store.upsertAccount(third))

        do {
            try store.reorderAccounts(ids: [third.id, first.id])
            XCTFail("Expected incomplete order to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("必须包含全部账号"))
        }

        do {
            try store.reorderAccounts(ids: [third.id, first.id, first.id])
            XCTFail("Expected duplicate order IDs to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重复"))
        }

        try store.reorderAccounts(ids: [third.id, first.id, second.id])
        XCTAssertEqual(try store.listAccountRecords().map(\.id), [third.id, first.id, second.id])

        try store.deleteAccount(id: first.id)
        let remaining = try store.listAccountRecords()
        XCTAssertEqual(remaining.map(\.id), [third.id, second.id])
        XCTAssertEqual(remaining.map(\.selectionOrder), [0, 1])
    }

    func testSQLiteStoreMigrationBackfillsSelectionOrderFromLegacyDisplaySort() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)

        var disabled = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-legacy-disabled",
            label: "Zulu Disabled"
        )
        disabled.enabled = false
        disabled.updatedAt = 900
        disabled.addedAt = 100

        var bravo = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-legacy-bravo",
            label: "Bravo Enabled"
        )
        bravo.enabled = true
        bravo.updatedAt = 400
        bravo.addedAt = 110

        var alpha = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-legacy-alpha",
            label: "Alpha Enabled"
        )
        alpha.enabled = true
        alpha.updatedAt = 400
        alpha.addedAt = 120

        try Self.writeLegacyAccountsDatabase(dataDirectory: directory, secretStore: secretStore, records: [disabled, bravo, alpha])

        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let migrated = try store.listAccountRecords()

        XCTAssertEqual(migrated.map(\.label), ["Alpha Enabled", "Bravo Enabled", "Zulu Disabled"])
        XCTAssertEqual(migrated.map(\.selectionOrder), [0, 1, 2])
        XCTAssertEqual(migrated.map(\.consecutiveFailureCount), [0, 0, 0])
        XCTAssertEqual(migrated.map(\.cooldownUntil), [nil, nil, nil])
        XCTAssertEqual(
            migrated.map(\.providerPreset),
            [.genericOpenAICompatible, .genericOpenAICompatible, .genericOpenAICompatible]
        )
    }

    func testSQLiteStoreMigrationDefaultsManagedProxyNodeNameToNilForLegacyAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = SecretStore(dataDirectory: directory)
        let record = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-legacy-node",
            label: "Legacy Node Account"
        )

        try Self.writeLegacyAccountsDatabase(dataDirectory: directory, secretStore: secretStore, records: [record])

        let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
        let migratedRecords = try store.listAccountRecords()
        let migratedSummaries = try store.listAccountSummaries(currentAccountKey: nil)

        XCTAssertEqual(migratedRecords.count, 1)
        XCTAssertNil(migratedRecords[0].managedProxyNodeName)
        XCTAssertNil(migratedSummaries[0].managedProxyNodeName)
    }

    func testAccountServiceReorderAccountsReturnsUpdatedSummariesInSelectionOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try Self.makeAccountService(dataDirectory: directory)
        let first = try self.makeChatGPTAccountRecord(label: "First OAuth")
        let second = try self.makeManualAPIKeyRecord(baseURL: "https://api.openai.com/v1", apiKey: "sk-service-2", label: "Second API")

        _ = try await service.importAuthJSONAccounts(
            items: [
                .init(source: "oauth", content: first.authJSON, label: first.label),
                .init(source: "api", content: second.authJSON, label: second.label),
            ],
            config: AppConfig()
        )

        let initial = try await service.listAccounts()
        let reordered = try await service.reorderAccounts(ids: [initial[1].id, initial[0].id])

        XCTAssertEqual(reordered.map(\.id), [initial[1].id, initial[0].id])
        XCTAssertEqual(reordered.map(\.selectionOrder), [0, 1])
    }

    func testSQLiteStoreRequestLogsSupportEncryptedAPIKeysAndFiltering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let baseTime = Helpers.now()

        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("local-key-1"),
                accountKey: "principal-1|account-1",
                accountLabel: "Primary",
                model: "gpt-5.4",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15, cacheHitTokens: 3),
                timestamp: baseTime - 80,
                apiKeyValue: "local-key-1"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/chat/completions",
                apiKeyHash: Helpers.sha256("local-key-2"),
                accountKey: "principal-2|account-2",
                accountLabel: "Fallback",
                model: "gpt-5.4-mini",
                success: false,
                latencyMS: 245,
                usage: UpstreamUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0, cacheHitTokens: nil),
                failureCategory: .rateLimit,
                lastError: "rate limited",
                timestamp: baseTime - 30,
                apiKeyValue: "local-key-2"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("local-key-1"),
                accountKey: "principal-1|account-1",
                accountLabel: "Primary",
                model: "gpt-5.4",
                success: true,
                latencyMS: 95,
                usage: UpstreamUsage(inputTokens: 12, outputTokens: 8, totalTokens: 20, cacheHitTokens: 5),
                timestamp: baseTime - 10,
                apiKeyValue: "local-key-1"
            )
        )

        let paged = try store.loadRequestLogs(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 120,
                to: baseTime,
                page: 1,
                pageSize: 1
            )
        )
        XCTAssertEqual(paged.totalCount, 3)
        XCTAssertEqual(paged.entries.count, 1)
        XCTAssertEqual(paged.entries.first?.apiKey, "local-key-1")

        let filtered = try store.loadRequestLogs(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 120,
                to: baseTime,
                apiKey: "local-key-1",
                model: "gpt-5.4",
                page: 1,
                pageSize: 10
            )
        )
        XCTAssertEqual(filtered.totalCount, 2)
        XCTAssertEqual(filtered.entries.first?.apiKey, "local-key-1")
        XCTAssertEqual(filtered.entries.first?.cacheHitTokens, 5)
        XCTAssertEqual(filtered.entries.first?.accountLabel, "Primary")

        let latencySorted = try store.loadRequestLogs(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 120,
                to: baseTime,
                sortBy: .latency,
                sortDirection: .ascending,
                page: 1,
                pageSize: 10
            )
        )
        XCTAssertEqual(latencySorted.entries.map(\.latencyMS), [95, 120, 245])

        let accountSorted = try store.loadRequestLogs(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 120,
                to: baseTime,
                sortBy: .accountLabel,
                sortDirection: .ascending,
                page: 1,
                pageSize: 10
            )
        )
        XCTAssertEqual(accountSorted.entries.map(\.accountLabel), ["Fallback", "Primary", "Primary"])

        let filters = try store.loadRequestLogFilterOptions(
            query: RequestLogQuery(timePreset: .custom, from: baseTime - 120, to: baseTime)
        )
        XCTAssertEqual(filters.availableAPIKeys, ["local-key-1", "local-key-2"])
        XCTAssertEqual(filters.availableModels, ["gpt-5.4", "gpt-5.4-mini"])
    }

    func testSQLiteStoreCancelledRequestLogsRemainVisibleButDoNotCountAsFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let baseTime = Helpers.now()

        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("local-key-cancelled"),
                accountKey: "principal|account",
                accountLabel: "Primary",
                model: "gpt-5.5",
                success: true,
                latencyMS: 80,
                usage: UpstreamUsage(inputTokens: 8, outputTokens: 4, totalTokens: 12, cacheHitTokens: nil),
                timestamp: baseTime - 30,
                apiKeyValue: "local-key-cancelled"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("local-key-cancelled"),
                accountKey: "principal|account",
                accountLabel: "Primary",
                model: "gpt-5.5",
                success: false,
                latencyMS: 95,
                failureCategory: .cancelled,
                lastError: "Downstream client cancelled the streaming request. Stream end reason: client_cancelled.",
                timestamp: baseTime - 20,
                apiKeyValue: "local-key-cancelled"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("local-key-cancelled"),
                accountKey: "principal|account",
                accountLabel: "Primary",
                model: "gpt-5.5",
                success: false,
                latencyMS: 110,
                failureCategory: .upstream,
                lastError: "Upstream stream returned response.failed.",
                timestamp: baseTime - 10,
                apiKeyValue: "local-key-cancelled"
            )
        )

        let page = try store.loadRequestLogs(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 60,
                to: baseTime,
                page: 1,
                pageSize: 10
            )
        )
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertTrue(page.entries.contains(where: {
            $0.failureCategory == "cancelled" && $0.errorSummary?.contains("client_cancelled") == true
        }))

        let usageRows = try store.loadProxyAPIKeyUsage(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 60,
                to: baseTime
            )
        )
        let usageRow = try XCTUnwrap(usageRows.first)
        XCTAssertEqual(usageRow.requestCount, 3)
        XCTAssertEqual(usageRow.failureCount, 1)
        XCTAssertEqual(usageRow.authFailureCount, 0)
        XCTAssertEqual(usageRow.rateLimitCount, 0)
        XCTAssertEqual(usageRow.quotaFailureCount, 0)

        let summary = try store.loadStatsSummary()
        XCTAssertEqual(summary.totalRequests, 3)
        XCTAssertEqual(summary.totalFailures, 1)
        XCTAssertEqual(summary.totalAuthFailures, 0)
        XCTAssertEqual(summary.totalRateLimits, 0)
        XCTAssertEqual(summary.totalQuotaFailures, 0)
    }

    func testSQLiteStoreRequestLogsFiltersByAccountKeyWhenLabelsMatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let baseTime = Helpers.now()

        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("local-key-1"),
                accountKey: "principal-1|account-1",
                accountLabel: "Shared Label",
                model: "gpt-5.4",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15, cacheHitTokens: nil),
                timestamp: baseTime - 80,
                apiKeyValue: "local-key-1"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("local-key-2"),
                accountKey: "principal-2|account-2",
                accountLabel: "Shared Label",
                model: "gpt-5.4",
                success: true,
                latencyMS: 95,
                usage: UpstreamUsage(inputTokens: 12, outputTokens: 8, totalTokens: 20, cacheHitTokens: nil),
                timestamp: baseTime - 10,
                apiKeyValue: "local-key-2"
            )
        )

        let filtered = try store.loadRequestLogs(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 120,
                to: baseTime,
                accountKey: "principal-1|account-1",
                page: 1,
                pageSize: 10
            )
        )

        XCTAssertEqual(filtered.totalCount, 1)
        XCTAssertEqual(filtered.entries.map(\.accountKey), ["principal-1|account-1"])
        XCTAssertEqual(filtered.entries.map(\.accountLabel), ["Shared Label"])
    }

    func testRequestLogQueryTimeRangeOnlyClearsNonTimeFilters() {
        let query = RequestLogQuery(
            timePreset: .custom,
            from: 1_710_000_000,
            to: 1_710_003_600,
            apiKey: "sk-local-history",
            accountKey: "principal-1|account-1",
            model: "gpt-5.4",
            sortBy: .latency,
            sortDirection: .ascending,
            page: 3,
            pageSize: 25
        )

        let timeOnly = query.timeRangeOnly()

        XCTAssertEqual(timeOnly.timePreset, .custom)
        XCTAssertEqual(timeOnly.from, 1_710_000_000)
        XCTAssertEqual(timeOnly.to, 1_710_003_600)
        XCTAssertNil(timeOnly.apiKey)
        XCTAssertNil(timeOnly.accountKey)
        XCTAssertNil(timeOnly.model)
        XCTAssertEqual(timeOnly.sortBy, .latency)
        XCTAssertEqual(timeOnly.sortDirection, .ascending)
        XCTAssertEqual(timeOnly.page, 1)
        XCTAssertEqual(timeOnly.pageSize, 25)
    }

    func testRequestLogEntryDecodesLegacyPayloadWithoutActualModel() throws {
        let payload: [String: Any] = [
            "id": 1,
            "timestamp": 1_776_052_953,
            "endpoint": "/v1/responses",
            "model": "gpt-5.4",
            "apiKey": "sk-local-secret-1234",
            "accountKey": "principal|account",
            "accountLabel": "Primary",
            "success": true,
            "latencyMS": 245,
            "inputTokens": 10,
            "outputTokens": 20,
            "totalTokens": 30,
            "cacheHitTokens": 4,
            "failureCategory": ProxyRequestTrace.FailureCategory.none.rawValue,
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let entry = try Helpers.readJSON(RequestLogEntry.self, from: data)

        XCTAssertEqual(entry.model, "gpt-5.4")
        XCTAssertNil(entry.actualModel)
        XCTAssertNil(entry.reasoningEffort)
        XCTAssertNil(entry.upstreamURL)
        XCTAssertEqual(entry.clientSource, .other)
    }

    func testRequestLogEntryRoundTripsActualModelAndClientSource() throws {
        let entry = RequestLogEntry(
            id: 1,
            timestamp: 1_776_052_953,
            endpoint: "/v1/responses",
            upstreamURL: "https://api.deepseek.com/responses",
            clientSource: .codex,
            model: "claude-sonnet-4-5",
            actualModel: "gpt-5.4",
            reasoningEffort: "xhigh",
            apiKey: "sk-local-secret-1234",
            accountKey: "principal|account",
            accountLabel: "Primary",
            success: true,
            latencyMS: 245,
            inputTokens: 10,
            outputTokens: 20,
            totalTokens: 30,
            cacheHitTokens: 4,
            failureCategory: ProxyRequestTrace.FailureCategory.none.rawValue,
            errorSummary: nil
        )

        let data = try Helpers.encodeJSON(entry)
        let decoded = try Helpers.readJSON(RequestLogEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.actualModel, "gpt-5.4")
        XCTAssertEqual(decoded.reasoningEffort, "xhigh")
        XCTAssertEqual(decoded.upstreamURL, "https://api.deepseek.com/responses")
        XCTAssertEqual(decoded.clientSource, .codex)
    }

    func testRequestLogEntryDecodesMissingClientSourceAsOther() throws {
        let payload: [String: Any] = [
            "id": 1,
            "timestamp": 1_776_052_953,
            "endpoint": "/v1/responses",
            "model": "gpt-5.4",
            "actual_model": "gpt-5.4",
            "apiKey": "sk-local-secret-1234",
            "accountKey": "principal|account",
            "accountLabel": "Primary",
            "success": true,
            "latencyMS": 245,
            "inputTokens": 10,
            "outputTokens": 20,
            "totalTokens": 30,
            "cacheHitTokens": 4,
            "failureCategory": ProxyRequestTrace.FailureCategory.none.rawValue,
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let entry = try Helpers.readJSON(RequestLogEntry.self, from: data)

        XCTAssertEqual(entry.clientSource, .other)
    }

    func testRequestLogCSVExportMasksAPIKeysAndKeepsFullErrorSummary() throws {
        let entry = RequestLogEntry(
            id: 1,
            timestamp: 1_776_052_953,
            endpoint: "/v1/responses",
            upstreamURL: "https://api.deepseek.com/responses",
            clientSource: .claudeCode,
            model: "claude-sonnet-4-5",
            actualModel: "gpt-5.4",
            reasoningEffort: "medium",
            apiKey: "sk-local-secret-1234",
            accountKey: "principal|account",
            accountLabel: "Primary",
            success: false,
            latencyMS: 245,
            inputTokens: 10,
            outputTokens: 20,
            totalTokens: 30,
            cacheHitTokens: 4,
            failureCategory: ProxyRequestTrace.FailureCategory.rateLimit.rawValue,
            errorSummary: "rate limited\nrequest_id=req_123"
        )

        let data = RequestLogCSVExport.data(entries: [entry], maskAPIKeys: true)
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        let expectedTime = FixedDisplayDateTimeFormat.string(fromUnixSeconds: entry.timestamp)

        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(text.contains("client_source"))
        XCTAssertTrue(text.contains("upstream_url"))
        XCTAssertTrue(text.contains("https://api.deepseek.com/responses"))
        XCTAssertTrue(text.contains("actual_model"))
        XCTAssertTrue(text.contains("claude_code"))
        XCTAssertTrue(text.contains("claude-sonnet-4-5"))
        XCTAssertTrue(text.contains("gpt-5.4"))
        XCTAssertTrue(text.contains("reasoning_effort"))
        XCTAssertTrue(text.contains("medium"))
        XCTAssertTrue(text.contains(expectedTime))
        XCTAssertTrue(text.contains("sk-loc****1234"))
        XCTAssertFalse(text.contains("sk-local-secret-1234"))
        XCTAssertTrue(text.contains("\"rate limited\nrequest_id=req_123\""))
    }

    func testRequestLogQueryIncludesClientSourceInQueryItems() {
        let query = RequestLogQuery(
            timePreset: .last24Hours,
            clientSource: .gemini,
            page: 2,
            pageSize: 25
        )

        let items = Dictionary(uniqueKeysWithValues: query.queryItems.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(items["client_source"], RequestLogClientSource.gemini.rawValue)
    }

    func testSQLiteStoreMigratesLegacyRequestLogsWithoutActualModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Self.writeLegacyRequestLogsDatabase(dataDirectory: directory, timestamp: Helpers.now())

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let page = try store.loadRequestLogs(query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10))
        let columns = try Self.sqliteColumnNames(in: "request_logs", dataDirectory: directory)

        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertTrue(columns.contains("upstream_url"))
        XCTAssertEqual(page.entries.first?.model, "gpt-5.4")
        XCTAssertNil(page.entries.first?.actualModel)
        XCTAssertNil(page.entries.first?.reasoningEffort)
        XCTAssertNil(page.entries.first?.upstreamURL)
        XCTAssertEqual(page.entries.first?.clientSource, .other)
    }

    func testSQLiteStoreRoundTripsRequestLogClientSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                upstreamURL: "https://api.deepseek.com/responses",
                apiKeyHash: Helpers.sha256("sk-local-primary"),
                accountKey: "principal|account",
                accountLabel: "Primary",
                clientSource: .gemini,
                model: "gpt-5.4",
                reasoningEffort: "high",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 10, outputTokens: 6, totalTokens: 16, cacheHitTokens: 2),
                timestamp: Helpers.now(),
                apiKeyValue: "sk-local-primary"
            )
        )

        let page = try store.loadRequestLogs(query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10))
        let entry = try XCTUnwrap(page.entries.first)

        XCTAssertEqual(entry.clientSource, .gemini)
        XCTAssertEqual(entry.reasoningEffort, "high")
        XCTAssertEqual(entry.upstreamURL, "https://api.deepseek.com/responses")
    }

    func testSQLiteStoreRequestLogsFiltersByClientSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let baseTime = Helpers.now()

        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("sk-local-codex"),
                accountKey: "principal-codex|account-codex",
                accountLabel: "Codex",
                clientSource: .codex,
                model: "gpt-5.4",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 10, outputTokens: 6, totalTokens: 16, cacheHitTokens: 2),
                timestamp: baseTime - 30,
                apiKeyValue: "sk-local-codex"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("sk-local-gemini"),
                accountKey: "principal-gemini|account-gemini",
                accountLabel: "Gemini",
                clientSource: .gemini,
                model: "gpt-5.4",
                success: true,
                latencyMS: 95,
                usage: UpstreamUsage(inputTokens: 12, outputTokens: 8, totalTokens: 20, cacheHitTokens: nil),
                timestamp: baseTime - 10,
                apiKeyValue: "sk-local-gemini"
            )
        )

        let filtered = try store.loadRequestLogs(
            query: RequestLogQuery(
                timePreset: .custom,
                from: baseTime - 120,
                to: baseTime,
                clientSource: .gemini,
                page: 1,
                pageSize: 10
            )
        )

        XCTAssertEqual(filtered.totalCount, 1)
        XCTAssertEqual(filtered.entries.count, 1)
        XCTAssertEqual(filtered.entries.first?.clientSource, .gemini)
        XCTAssertEqual(filtered.entries.first?.accountLabel, "Gemini")
    }

    func testProxyResponsesMissingUsageRecordsSuccessDiagnosticAndZeroTokens() async throws {
        let responseBody = #"""
        {
          "id": "resp_missing_usage",
          "object": "response",
          "created_at": 1710000000,
          "status": "completed",
          "model": "gpt-5.4",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "done"
                }
              ]
            }
          ]
        }
        """#
        let upstream = Self.makeOpenAICompatibleResponsesApplication(nonStreamResponseBody: responseBody)

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-upstream-missing-usage",
                label: "Generic Upstream"
            )
            XCTAssertFalse(try store.upsertAccount(record))

            let controller = try Self.makeDaemonControllerFixture(dataDirectory: directory, secretStore: secretStore)
            let response = try await controller.proxyResponses(
                body: Data(#"{"model":"gpt-5.4","input":"hello"}"#.utf8),
                proxyKey: AuthenticatedProxyKeyContext(
                    apiKeyHash: Helpers.sha256("sk-local-proxy"),
                    proxyKeyID: "proxy-local",
                    dataSource: .openAI
                ),
                apiKeyValue: "sk-local-proxy"
            )

            let body = try await Self.data(from: response)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(payload["status"] as? String, "completed")

            let page = try store.loadRequestLogs(query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10))
            let entry = try XCTUnwrap(page.entries.first)
            XCTAssertTrue(entry.success)
            XCTAssertEqual(entry.inputTokens, 0)
            XCTAssertEqual(entry.outputTokens, 0)
            XCTAssertEqual(entry.totalTokens, 0)
            XCTAssertTrue(entry.errorSummary?.contains("without recognizable usage fields") == true)
            XCTAssertTrue(entry.errorSummary?.contains("recorded as 0") == true)
        }
    }

    func testProxyResponsesUsagePresentDoesNotRecordSuccessDiagnostic() async throws {
        let responseBody = #"""
        {
          "id": "resp_with_usage",
          "object": "response",
          "created_at": 1710000000,
          "status": "completed",
          "model": "gpt-5.4",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "done"
                }
              ]
            }
          ],
          "usage": {
            "input_tokens": 5,
            "output_tokens": 7,
            "total_tokens": 12
          }
        }
        """#
        let upstream = Self.makeOpenAICompatibleResponsesApplication(nonStreamResponseBody: responseBody)

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-upstream-complete-usage",
                label: "Generic Upstream"
            )
            XCTAssertFalse(try store.upsertAccount(record))

            let controller = try Self.makeDaemonControllerFixture(dataDirectory: directory, secretStore: secretStore)
            let response = try await controller.proxyResponses(
                body: Data(#"{"model":"gpt-5.4","input":"hello"}"#.utf8),
                proxyKey: AuthenticatedProxyKeyContext(
                    apiKeyHash: Helpers.sha256("sk-local-proxy"),
                    proxyKeyID: "proxy-local",
                    dataSource: .openAI
                ),
                apiKeyValue: "sk-local-proxy"
            )

            let body = try await Self.data(from: response)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(payload["status"] as? String, "completed")

            let page = try store.loadRequestLogs(query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10))
            let entry = try XCTUnwrap(page.entries.first)
            XCTAssertTrue(entry.success)
            XCTAssertEqual(entry.inputTokens, 5)
            XCTAssertEqual(entry.outputTokens, 7)
            XCTAssertEqual(entry.totalTokens, 12)
            XCTAssertNil(entry.errorSummary)
        }
    }

    func testProxyAnthropicMessagesPrematureStreamEndKeepsSuccessAndWritesDiagnostic() async throws {
        let streamChunks = [
            #"data: {"type":"response.created","response":{"id":"resp_claude_early","created_at":1710000000,"model":"gpt-5.4"}}"# + "\n\n",
            #"data: {"type":"response.output_text.delta","output_index":0,"delta":"Working"}"# + "\n\n",
        ]
        let upstream = Self.makeOpenAICompatibleResponsesApplication(streamChunks: streamChunks)

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-upstream-claude-early",
                label: "Generic Upstream"
            )
            XCTAssertFalse(try store.upsertAccount(record))

            let controller = try Self.makeDaemonControllerFixture(dataDirectory: directory, secretStore: secretStore)
            let response = try await controller.proxyAnthropicMessages(
                body: Data(#"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":true}"#.utf8),
                proxyKey: AuthenticatedProxyKeyContext(
                    apiKeyHash: Helpers.sha256("sk-local-proxy"),
                    proxyKeyID: "proxy-local",
                    dataSource: .openAI
                ),
                apiKeyValue: "sk-local-proxy",
                headers: ["x-claude-code-session-id": "claude-session-1"],
                anthropicVersion: AnthropicTranscoder.defaultAnthropicVersion,
                anthropicBeta: nil
            )

            let body = try await Self.data(from: response)
            let events = ProxyTranscoder.decodeSSE(body)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertFalse(events.compactMap(\.event).contains("message_stop"))

            let page = try store.loadRequestLogs(query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10))
            let entry = try XCTUnwrap(page.entries.first)
            XCTAssertTrue(entry.success)
            XCTAssertEqual(entry.clientSource, .claudeCode)
            XCTAssertEqual(entry.totalTokens, 0)
            XCTAssertTrue(entry.errorSummary?.contains("response.completed") == true)
            XCTAssertTrue(entry.errorSummary?.contains("message_stop") == true)
            XCTAssertTrue(entry.errorSummary?.contains("Claude Code") == true)
        }
    }

    func testProxyAnthropicMessagesMissingUsageStillFinishesAndWritesDiagnostic() async throws {
        let streamChunks = [
            #"data: {"type":"response.created","response":{"id":"resp_claude_usage","created_at":1710000000,"model":"gpt-5.4"}}"# + "\n\n",
            #"data: {"type":"response.output_text.delta","output_index":0,"delta":"Working"}"# + "\n\n",
            #"data: {"type":"response.completed","response":{"id":"resp_claude_usage","object":"response","created_at":1710000000,"status":"completed","model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working"}]}]}}"# + "\n\n",
        ]
        let upstream = Self.makeOpenAICompatibleResponsesApplication(streamChunks: streamChunks)

        try await upstream.test(TestingSetup.ahc()) { client in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let secretStore = SecretStore(dataDirectory: directory)
            let store = try SQLiteStore(dataDirectory: directory, secretStore: secretStore)
            let record = try Self.makeManualAPIKeyRecordFixture(
                baseURL: "http://localhost:\(client.port ?? 0)/v1",
                apiKey: "sk-upstream-claude-missing-usage",
                label: "Generic Upstream"
            )
            XCTAssertFalse(try store.upsertAccount(record))

            let controller = try Self.makeDaemonControllerFixture(dataDirectory: directory, secretStore: secretStore)
            let response = try await controller.proxyAnthropicMessages(
                body: Data(#"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":true}"#.utf8),
                proxyKey: AuthenticatedProxyKeyContext(
                    apiKeyHash: Helpers.sha256("sk-local-proxy"),
                    proxyKeyID: "proxy-local",
                    dataSource: .openAI
                ),
                apiKeyValue: "sk-local-proxy",
                headers: ["x-claude-code-session-id": "claude-session-1"],
                anthropicVersion: AnthropicTranscoder.defaultAnthropicVersion,
                anthropicBeta: nil
            )

            let body = try await Self.data(from: response)
            let events = ProxyTranscoder.decodeSSE(body)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(events.compactMap(\.event).contains("message_stop"))

            let page = try store.loadRequestLogs(query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10))
            let entry = try XCTUnwrap(page.entries.first)
            XCTAssertTrue(entry.success)
            XCTAssertEqual(entry.clientSource, .claudeCode)
            XCTAssertEqual(entry.inputTokens, 0)
            XCTAssertEqual(entry.outputTokens, 0)
            XCTAssertEqual(entry.totalTokens, 0)
            XCTAssertTrue(entry.errorSummary?.contains("without recognizable usage fields") == true)
            XCTAssertTrue(entry.errorSummary?.contains("recorded as 0") == true)
        }
    }

    func testSQLiteStoreSerializesConcurrentRequestLogQueries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let baseTime = Helpers.now()

        for offset in 0..<12 {
            try store.recordTrace(
                ProxyRequestTrace(
                    endpoint: offset.isMultiple(of: 2) ? "/v1/responses" : "/v1/chat/completions",
                    apiKeyHash: Helpers.sha256(offset.isMultiple(of: 2) ? "local-key-a" : "local-key-b"),
                    accountKey: "principal-\(offset)|account-\(offset)",
                    accountLabel: offset.isMultiple(of: 2) ? "Primary" : "Fallback",
                    model: offset.isMultiple(of: 2) ? "gpt-5.4" : "gpt-5.4-mini",
                    success: !offset.isMultiple(of: 3),
                    latencyMS: Int64(100 + offset),
                    usage: UpstreamUsage(
                        inputTokens: Int64(10 + offset),
                        outputTokens: Int64(5 + offset),
                        totalTokens: Int64(15 + (offset * 2)),
                        cacheHitTokens: offset.isMultiple(of: 2) ? Int64(offset) : nil
                    ),
                    failureCategory: offset.isMultiple(of: 3) ? .rateLimit : .none,
                    lastError: offset.isMultiple(of: 3) ? "rate limited \(offset)" : nil,
                    timestamp: baseTime - Int64(120 - offset),
                    apiKeyValue: offset.isMultiple(of: 2) ? "local-key-a" : "local-key-b"
                )
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for _ in 0..<20 {
                        if worker.isMultiple(of: 2) {
                            let page = try store.loadRequestLogs(
                                query: RequestLogQuery(
                                    timePreset: .custom,
                                    from: baseTime - 300,
                                    to: baseTime,
                                    page: 1,
                                    pageSize: 50
                                )
                            )
                            XCTAssertEqual(page.totalCount, 12)
                            XCTAssertFalse(page.availableAPIKeys.isEmpty)
                        } else {
                            let filters = try store.loadRequestLogFilterOptions(
                                query: RequestLogQuery(
                                    timePreset: .custom,
                                    from: baseTime - 300,
                                    to: baseTime
                                )
                            )
                            XCTAssertEqual(filters.availableAPIKeys, ["local-key-b", "local-key-a"])
                            XCTAssertEqual(filters.availableModels, ["gpt-5.4-mini", "gpt-5.4"])
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    func testSQLiteStoreAccountSummariesIncludeTodayTokenUsageForAPIKeyAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let activeAPIRecord = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-active-account",
            label: "Active API"
        )
        let idleAPIRecord = try self.makeManualAPIKeyRecord(
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-idle-account",
            label: "Idle API"
        )
        let chatGPTRecord = AccountRecord(
            label: "ChatGPT",
            principalID: "principal-chatgpt",
            email: "chatgpt@example.com",
            accountID: "account-chatgpt",
            planType: "plus",
            authMode: .chatGPT,
            authJSON: "{}"
        )

        XCTAssertFalse(try store.upsertAccount(activeAPIRecord))
        XCTAssertFalse(try store.upsertAccount(idleAPIRecord))
        XCTAssertFalse(try store.upsertAccount(chatGPTRecord))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        func makeDate(
            year: Int,
            month: Int,
            day: Int,
            hour: Int,
            minute: Int,
            second: Int = 0
        ) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 14, hour: 12, minute: 0)
        let todayEarly = Int64(try makeDate(year: 2026, month: 4, day: 14, hour: 1, minute: 15).timeIntervalSince1970)
        let todayLate = Int64(try makeDate(year: 2026, month: 4, day: 14, hour: 11, minute: 45).timeIntervalSince1970)
        let yesterdayLate = Int64(try makeDate(year: 2026, month: 4, day: 13, hour: 23, minute: 30).timeIntervalSince1970)

        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("sk-active-account"),
                accountKey: activeAPIRecord.accountKey,
                accountLabel: activeAPIRecord.label,
                model: "gpt-4.1",
                success: true,
                latencyMS: 100,
                usage: UpstreamUsage(inputTokens: 120, outputTokens: 80, totalTokens: 200, cacheHitTokens: nil),
                timestamp: todayEarly,
                apiKeyValue: "sk-active-account"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/chat/completions",
                apiKeyHash: Helpers.sha256("sk-active-account"),
                accountKey: activeAPIRecord.accountKey,
                accountLabel: activeAPIRecord.label,
                model: "gpt-4.1-mini",
                success: true,
                latencyMS: 140,
                usage: UpstreamUsage(inputTokens: 30, outputTokens: 50, totalTokens: 80, cacheHitTokens: nil),
                timestamp: todayLate,
                apiKeyValue: "sk-active-account"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("sk-active-account"),
                accountKey: activeAPIRecord.accountKey,
                accountLabel: activeAPIRecord.label,
                model: "gpt-4.1",
                success: true,
                latencyMS: 90,
                usage: UpstreamUsage(inputTokens: 999, outputTokens: 999, totalTokens: 1_998, cacheHitTokens: nil),
                timestamp: yesterdayLate,
                apiKeyValue: "sk-active-account"
            )
        )

        let summaries = try store.listAccountSummaries(currentAccountKey: nil, now: now, calendar: calendar)
        let activeSummary = try XCTUnwrap(summaries.first(where: { $0.accountKey == activeAPIRecord.accountKey }))
        let idleSummary = try XCTUnwrap(summaries.first(where: { $0.accountKey == idleAPIRecord.accountKey }))
        let chatGPTSummary = try XCTUnwrap(summaries.first(where: { $0.accountKey == chatGPTRecord.accountKey }))

        XCTAssertEqual(activeSummary.todayTokenUsage, AccountTodayTokenUsage(inputTokens: 150, outputTokens: 130))
        XCTAssertEqual(idleSummary.todayTokenUsage, AccountTodayTokenUsage())
        XCTAssertNil(chatGPTSummary.todayTokenUsage)
    }

    func testSQLiteStoreAccountSummariesIncludeTodayTokenUsageForAnthropicOAuthAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let activeAnthropicRecord = self.makeAnthropicOAuthAccountRecord(
            label: "Active Anthropic OAuth",
            principalID: "principal-anthropic-active",
            accountID: "account-anthropic-active"
        )
        let idleAnthropicRecord = self.makeAnthropicOAuthAccountRecord(
            label: "Idle Anthropic OAuth",
            principalID: "principal-anthropic-idle",
            accountID: "account-anthropic-idle"
        )
        let chatGPTRecord = AccountRecord(
            label: "ChatGPT",
            principalID: "principal-chatgpt",
            email: "chatgpt@example.com",
            accountID: "account-chatgpt",
            planType: "plus",
            authMode: .chatGPT,
            authJSON: "{}"
        )

        XCTAssertFalse(try store.upsertAccount(activeAnthropicRecord))
        XCTAssertFalse(try store.upsertAccount(idleAnthropicRecord))
        XCTAssertFalse(try store.upsertAccount(chatGPTRecord))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        func makeDate(
            year: Int,
            month: Int,
            day: Int,
            hour: Int,
            minute: Int,
            second: Int = 0
        ) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 14, hour: 12, minute: 0)
        let todayMorning = Int64(try makeDate(year: 2026, month: 4, day: 14, hour: 9, minute: 5).timeIntervalSince1970)
        let todayLate = Int64(try makeDate(year: 2026, month: 4, day: 14, hour: 11, minute: 20).timeIntervalSince1970)
        let yesterdayLate = Int64(try makeDate(year: 2026, month: 4, day: 13, hour: 23, minute: 40).timeIntervalSince1970)

        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/messages",
                apiKeyHash: Helpers.sha256("sk-anthropic-local"),
                accountKey: activeAnthropicRecord.accountKey,
                accountLabel: activeAnthropicRecord.label,
                model: "claude-sonnet-4-5",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 210, outputTokens: 80, totalTokens: 290, cacheHitTokens: nil),
                timestamp: todayMorning,
                apiKeyValue: "sk-anthropic-local"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/messages",
                apiKeyHash: Helpers.sha256("sk-anthropic-local"),
                accountKey: activeAnthropicRecord.accountKey,
                accountLabel: activeAnthropicRecord.label,
                model: "claude-sonnet-4-5",
                success: true,
                latencyMS: 140,
                usage: UpstreamUsage(inputTokens: 25, outputTokens: 55, totalTokens: 80, cacheHitTokens: nil),
                timestamp: todayLate,
                apiKeyValue: "sk-anthropic-local"
            )
        )
        try store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/messages",
                apiKeyHash: Helpers.sha256("sk-anthropic-local"),
                accountKey: activeAnthropicRecord.accountKey,
                accountLabel: activeAnthropicRecord.label,
                model: "claude-sonnet-4-5",
                success: true,
                latencyMS: 90,
                usage: UpstreamUsage(inputTokens: 999, outputTokens: 999, totalTokens: 1_998, cacheHitTokens: nil),
                timestamp: yesterdayLate,
                apiKeyValue: "sk-anthropic-local"
            )
        )

        let summaries = try store.listAccountSummaries(currentAccountKey: nil, now: now, calendar: calendar)
        let activeSummary = try XCTUnwrap(summaries.first(where: { $0.accountKey == activeAnthropicRecord.accountKey }))
        let idleSummary = try XCTUnwrap(summaries.first(where: { $0.accountKey == idleAnthropicRecord.accountKey }))
        let chatGPTSummary = try XCTUnwrap(summaries.first(where: { $0.accountKey == chatGPTRecord.accountKey }))

        XCTAssertEqual(activeSummary.todayTokenUsage, AccountTodayTokenUsage(inputTokens: 235, outputTokens: 135))
        XCTAssertEqual(idleSummary.todayTokenUsage, AccountTodayTokenUsage())
        XCTAssertNil(chatGPTSummary.todayTokenUsage)
    }

    func testSQLiteStoreLoadStatsSummaryUsesLocalNaturalTokenRanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        func makeDate(
            year: Int,
            month: Int,
            day: Int,
            hour: Int,
            minute: Int,
            second: Int = 0
        ) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 15, hour: 12, minute: 30)
        let today = Int64(try makeDate(year: 2026, month: 4, day: 15, hour: 9, minute: 0).timeIntervalSince1970)
        let yesterday = Int64(try makeDate(year: 2026, month: 4, day: 14, hour: 23, minute: 30).timeIntervalSince1970)
        let monday = Int64(try makeDate(year: 2026, month: 4, day: 13, hour: 8, minute: 0).timeIntervalSince1970)
        let sundayLastWeek = Int64(try makeDate(year: 2026, month: 4, day: 12, hour: 21, minute: 0).timeIntervalSince1970)
        let previousMonth = Int64(try makeDate(year: 2026, month: 3, day: 31, hour: 20, minute: 0).timeIntervalSince1970)

        let traces: [(timestamp: Int64, input: Int64, output: Int64)] = [
            (today, 10, 5),
            (yesterday, 20, 6),
            (monday, 30, 7),
            (sundayLastWeek, 40, 8),
            (previousMonth, 50, 9),
        ]

        for (index, trace) in traces.enumerated() {
            try store.recordTrace(
                ProxyRequestTrace(
                    endpoint: "/v1/responses",
                    apiKeyHash: Helpers.sha256("local-key-\(index)"),
                    accountKey: "principal-\(index)|account-\(index)",
                    accountLabel: "Account \(index)",
                    model: "gpt-5.4",
                    success: true,
                    latencyMS: 100 + Int64(index),
                    usage: UpstreamUsage(
                        inputTokens: trace.input,
                        outputTokens: trace.output,
                        totalTokens: trace.input + trace.output,
                        cacheHitTokens: nil
                    ),
                    timestamp: trace.timestamp,
                    apiKeyValue: "local-key-\(index)"
                )
            )
        }

        let summary = try store.loadStatsSummary(now: now, calendar: calendar)

        XCTAssertEqual(summary.naturalTokenUsage.today.requestCount, 1)
        XCTAssertEqual(summary.naturalTokenUsage.today.inputTokens, 10)
        XCTAssertEqual(summary.naturalTokenUsage.today.outputTokens, 5)
        XCTAssertEqual(summary.naturalTokenUsage.week.requestCount, 3)
        XCTAssertEqual(summary.naturalTokenUsage.week.inputTokens, 60)
        XCTAssertEqual(summary.naturalTokenUsage.week.outputTokens, 18)
        XCTAssertEqual(summary.naturalTokenUsage.month.requestCount, 4)
        XCTAssertEqual(summary.naturalTokenUsage.month.inputTokens, 100)
        XCTAssertEqual(summary.naturalTokenUsage.month.outputTokens, 26)
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend.count, 5)
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend.map(\.requestCount), [1, 1, 1, 1, 1])
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend.map(\.inputTokens), [50, 40, 30, 20, 10])
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend.map(\.outputTokens), [9, 8, 7, 6, 5])
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend.count, 4)
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend.map(\.requestCount), [0, 1, 1, 3])
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend.map(\.inputTokens), [0, 50, 40, 60])
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend.map(\.outputTokens), [0, 9, 8, 18])
    }

    func testSQLiteStoreLoadStatsSummaryDefaultsNaturalTokenRangesToZeroWithoutLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        let summary = try store.loadStatsSummary()

        XCTAssertEqual(summary.naturalTokenUsage.today.requestCount, 0)
        XCTAssertEqual(summary.naturalTokenUsage.week.requestCount, 0)
        XCTAssertEqual(summary.naturalTokenUsage.month.requestCount, 0)
        XCTAssertEqual(summary.naturalTokenUsage.today, .init())
        XCTAssertEqual(summary.naturalTokenUsage.week, .init())
        XCTAssertEqual(summary.naturalTokenUsage.month, .init())
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend, [])
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend.count, 4)
        XCTAssertTrue(summary.naturalTokenUsage.weeklyTrend.allSatisfy {
            $0.requestCount == 0 && $0.inputTokens == 0 && $0.outputTokens == 0
        })
    }

    func testSQLiteStoreAccountSummariesPreferUsagePlanTypeOverStoredPlanType() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(dataDirectory: directory, secretStore: SecretStore(dataDirectory: directory))
        var record = try self.makeChatGPTAccountRecord(label: "Upgraded OAuth")
        record.planType = "free"
        record.usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "plus",
            fiveHour: UsageWindow(usedPercent: 15, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
            credits: nil
        )
        XCTAssertFalse(try store.upsertAccount(record))

        let summary = try XCTUnwrap(store.listAccountSummaries(currentAccountKey: nil).first)
        let loadedRecord = try XCTUnwrap(store.listAccountRecords().first)

        XCTAssertEqual(summary.planType, "plus")
        XCTAssertEqual(summary.effectivePlanType, "plus")
        XCTAssertEqual(loadedRecord.planType, "plus")
        XCTAssertEqual(loadedRecord.effectivePlanType, "plus")
    }

    func testAccountSummaryDecodesSnakeCaseAccountID() throws {
        let payload = #"""
        {
          "id": "account-1",
          "label": "Primary",
          "email": "user@example.com",
          "account_key": "principal|acct",
          "account_id": "acct",
          "plan_type": "free",
          "added_at": 1,
          "updated_at": 2,
          "enabled": false,
          "auth_refresh_blocked": false,
          "is_current": true
        }
        """#

        let account = try Helpers.readJSON(AccountSummary.self, from: Data(payload.utf8))
        XCTAssertEqual(account.accountID, "acct")
        XCTAssertFalse(account.enabled)
        XCTAssertTrue(account.isCurrent)
    }

    func testProxyStatusDecodesSnakeCaseURLAndIDKeys() throws {
        let payload = #"""
        {
          "running": true,
          "public_base_url": "http://127.0.0.1:8787/v1",
          "anthropic_base_url": "http://127.0.0.1:8787",
          "gemini_base_url": "http://127.0.0.1:8787",
          "admin_base_url": "http://127.0.0.1:8788/admin",
          "api_key": "proxy-key",
          "active_account_key": "principal|acct",
          "active_account_id": "acct",
          "active_account_label": "Primary",
          "last_error": "boom",
          "daemon_version": "1.0.0 Beta版"
        }
        """#

        let status = try Helpers.readJSON(ProxyStatus.self, from: Data(payload.utf8))
        XCTAssertEqual(status.publicBaseURL, "http://127.0.0.1:8787/v1")
        XCTAssertEqual(status.anthropicBaseURL, "http://127.0.0.1:8787")
        XCTAssertEqual(status.geminiBaseURL, "http://127.0.0.1:8787")
        XCTAssertEqual(status.adminBaseURL, "http://127.0.0.1:8788/admin")
        XCTAssertEqual(status.activeAccountID, "acct")
        XCTAssertEqual(status.apiKey, "proxy-key")
        XCTAssertEqual(status.daemonVersion, "1.0.0 Beta版")
    }

    func testProxyTestModelCatalogDecodesSnakeCaseKeys() throws {
        let payload = #"""
        {
          "chat_completions": {
            "family": "gpt",
            "models": ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-5.4-mini", "gpt-5.2"],
            "default_model": "gpt-5.5"
          },
          "responses": {
            "family": "gpt",
            "models": ["gpt-5.5", "gpt-5.4"],
            "default_model": "gpt-5.5"
          },
          "anthropic_messages": {
            "family": "anthropic",
            "models": ["claude-sonnet-4-6"],
            "default_model": "claude-sonnet-4-6"
          },
          "gemini_generate_content": {
            "family": "gemini",
            "models": ["gemini-2.5-flash", "gemini-2.5-pro"],
            "default_model": "gemini-2.5-flash"
          }
        }
        """#

        let catalog = try Helpers.readJSON(ProxyTestModelCatalog.self, from: Data(payload.utf8))
        XCTAssertEqual(catalog.chatCompletions.family, .gpt)
        XCTAssertEqual(catalog.chatCompletions.models, ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-5.4-mini", "gpt-5.2"])
        XCTAssertEqual(catalog.chatCompletions.defaultModel, "gpt-5.5")
        XCTAssertEqual(catalog.anthropicMessages.family, .anthropic)
        XCTAssertEqual(catalog.anthropicMessages.defaultModel, "claude-sonnet-4-6")
        XCTAssertEqual(catalog.geminiGenerateContent.family, .gemini)
        XCTAssertEqual(catalog.geminiGenerateContent.defaultModel, "gemini-2.5-flash")
    }

    func testRequestMetricBucketDecodesSnakeCaseLatencyKeys() throws {
        let payload = #"""
        {
          "granularity": "hour",
          "bucket_start": 1710000000,
          "endpoint": "/v1/responses",
          "api_key_hash": "hash",
          "account_key": "principal|acct",
          "account_label": "OAuth",
          "model": "gpt-5.4",
          "success_count": 6,
          "failure_count": 1,
          "auth_failure_count": 0,
          "rate_limit_count": 0,
          "quota_failure_count": 0,
          "total_latency_ms": 31000,
          "p95_latency_ms": 5000,
          "total_input_tokens": 181,
          "total_output_tokens": 90,
          "total_tokens": 271,
          "last_error": null
        }
        """#

        let bucket = try Helpers.readJSON(RequestMetricBucket.self, from: Data(payload.utf8))
        XCTAssertEqual(bucket.totalLatencyMS, 31_000)
        XCTAssertEqual(bucket.p95LatencyMS, 5_000)
        XCTAssertEqual(bucket.totalInputTokens, 181)
    }

    func testAdminStatsSummaryDecodesNestedBucketsWithLatencyKeys() throws {
        let payload = #"""
        {
          "total_requests": 26,
          "total_failures": 1,
          "total_auth_failures": 0,
          "total_rate_limits": 0,
          "total_quota_failures": 0,
          "total_input_tokens": 181,
          "total_output_tokens": 90,
          "total_tokens": 271,
          "natural_token_usage": {
            "today": {
              "request_count": 2,
              "input_tokens": 12,
              "output_tokens": 8
            },
            "week": {
              "request_count": 6,
              "input_tokens": 48,
              "output_tokens": 16
            },
            "month": {
              "request_count": 26,
              "input_tokens": 181,
              "output_tokens": 90
            }
          },
          "latest_buckets": [
            {
              "granularity": "hour",
              "bucket_start": 1710000000,
              "endpoint": "/v1/responses",
              "api_key_hash": "hash",
              "account_key": "principal|acct",
              "account_label": "OAuth",
              "model": "gpt-5.4",
              "success_count": 6,
              "failure_count": 1,
              "auth_failure_count": 0,
              "rate_limit_count": 0,
              "quota_failure_count": 0,
              "total_latency_ms": 31000,
              "p95_latency_ms": 5000,
              "total_input_tokens": 181,
              "total_output_tokens": 90,
              "total_tokens": 271,
              "last_error": null
            }
          ]
        }
        """#

        let summary = try Helpers.readJSON(AdminStatsSummary.self, from: Data(payload.utf8))
        XCTAssertEqual(summary.totalRequests, 26)
        XCTAssertEqual(summary.naturalTokenUsage.today.requestCount, 2)
        XCTAssertEqual(summary.naturalTokenUsage.today.inputTokens, 12)
        XCTAssertEqual(summary.naturalTokenUsage.week.requestCount, 6)
        XCTAssertEqual(summary.naturalTokenUsage.week.outputTokens, 16)
        XCTAssertEqual(summary.naturalTokenUsage.month.requestCount, 26)
        XCTAssertEqual(summary.naturalTokenUsage.month.inputTokens, 181)
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend, [])
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend, [])
        XCTAssertEqual(summary.latestBuckets.count, 1)
        XCTAssertEqual(summary.latestBuckets[0].totalLatencyMS, 31_000)
        XCTAssertEqual(summary.latestBuckets[0].p95LatencyMS, 5_000)
    }

    func testAdminStatsSummaryNaturalTokenUsageDefaultsMissingRequestCountToZero() throws {
        let payload = #"""
        {
          "total_requests": 26,
          "total_failures": 1,
          "total_auth_failures": 0,
          "total_rate_limits": 0,
          "total_quota_failures": 0,
          "total_input_tokens": 181,
          "total_output_tokens": 90,
          "total_tokens": 271,
          "natural_token_usage": {
            "today": {
              "input_tokens": 12,
              "output_tokens": 8
            },
            "week": {
              "input_tokens": 48,
              "output_tokens": 16
            },
            "month": {
              "input_tokens": 181,
              "output_tokens": 90
            }
          },
          "latest_buckets": []
        }
        """#

        let summary = try Helpers.readJSON(AdminStatsSummary.self, from: Data(payload.utf8))

        XCTAssertEqual(summary.naturalTokenUsage.today.requestCount, 0)
        XCTAssertEqual(summary.naturalTokenUsage.week.requestCount, 0)
        XCTAssertEqual(summary.naturalTokenUsage.month.requestCount, 0)
        XCTAssertEqual(summary.naturalTokenUsage.today.inputTokens, 12)
        XCTAssertEqual(summary.naturalTokenUsage.week.outputTokens, 16)
        XCTAssertEqual(summary.naturalTokenUsage.month.inputTokens, 181)
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend, [])
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend, [])
    }

    func testAdminStatsSummaryDefaultsMissingNaturalTokenUsageToZero() throws {
        let payload = #"""
        {
          "total_requests": 1,
          "total_failures": 0,
          "total_auth_failures": 0,
          "total_rate_limits": 0,
          "total_quota_failures": 0,
          "total_input_tokens": 11,
          "total_output_tokens": 7,
          "total_tokens": 18,
          "latest_buckets": []
        }
        """#

        let summary = try Helpers.readJSON(AdminStatsSummary.self, from: Data(payload.utf8))

        XCTAssertEqual(summary.naturalTokenUsage.today, .init())
        XCTAssertEqual(summary.naturalTokenUsage.week, .init())
        XCTAssertEqual(summary.naturalTokenUsage.month, .init())
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend, [])
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend, [])
    }

    func testAdminStatsSummaryDecodesNaturalTrendBuckets() throws {
        let payload = #"""
        {
          "total_requests": 4,
          "total_failures": 0,
          "total_auth_failures": 0,
          "total_rate_limits": 0,
          "total_quota_failures": 0,
          "total_input_tokens": 44,
          "total_output_tokens": 22,
          "total_tokens": 66,
          "natural_token_usage": {
            "today": {
              "request_count": 1,
              "input_tokens": 11,
              "output_tokens": 6
            },
            "week": {
              "request_count": 4,
              "input_tokens": 44,
              "output_tokens": 22
            },
            "month": {
              "request_count": 4,
              "input_tokens": 44,
              "output_tokens": 22
            },
            "daily_trend": [
              {
                "bucket_start": 1776038400,
                "window_seconds": 86400,
                "request_count": 1,
                "input_tokens": 11,
                "output_tokens": 6
              }
            ],
            "weekly_trend": [
              {
                "bucket_start": 1775865600,
                "window_seconds": 604800,
                "request_count": 4,
                "input_tokens": 44,
                "output_tokens": 22
              }
            ]
          },
          "latest_buckets": []
        }
        """#

        let summary = try Helpers.readJSON(AdminStatsSummary.self, from: Data(payload.utf8))

        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend.count, 1)
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend[0].windowSeconds, 86_400)
        XCTAssertEqual(summary.naturalTokenUsage.dailyTrend[0].inputTokens, 11)
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend.count, 1)
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend[0].windowSeconds, 604_800)
        XCTAssertEqual(summary.naturalTokenUsage.weeklyTrend[0].requestCount, 4)
    }

    func testRemoteDeployStatusDecodesSnakeCaseURLAndIDKeys() throws {
        let payload = #"""
        {
          "host_id": "host-1",
          "installed": true,
          "service_installed": true,
          "running": false,
          "enabled": true,
          "architecture": "arm64",
          "base_url": "http://host:8787/v1",
          "api_key": "remote-key",
          "last_error": "offline",
          "logs": "sample"
        }
        """#

        let status = try Helpers.readJSON(RemoteDeployStatus.self, from: Data(payload.utf8))
        XCTAssertEqual(status.hostID, "host-1")
        XCTAssertEqual(status.baseURL, "http://host:8787/v1")
        XCTAssertEqual(status.apiKey, "remote-key")
        XCTAssertEqual(status.logs, "sample")
    }

    func testRemoteConnectionCheckDecodesSnakeCaseHostIDKey() throws {
        let payload = #"""
        {
          "host_id": "host-1",
          "architecture": "arm64",
          "remote_user": "deploy",
          "remote_directory_writable": true,
          "systemctl_available": true,
          "sudo_available": false,
          "local_artifact_available": true
        }
        """#

        let check = try Helpers.readJSON(RemoteConnectionCheck.self, from: Data(payload.utf8))

        XCTAssertEqual(check.hostID, "host-1")
        XCTAssertEqual(check.architecture, "arm64")
        XCTAssertEqual(check.remoteUser, "deploy")
        XCTAssertTrue(check.remoteDirectoryWritable)
        XCTAssertTrue(check.systemctlAvailable)
        XCTAssertFalse(check.sudoAvailable)
        XCTAssertTrue(check.localArtifactAvailable)
    }

    func testDesktopPreferencesStorePersistsValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DesktopPreferencesStore(dataDirectory: directory)
        XCTAssertEqual(store.load(), DesktopPreferences())

        let saved = DesktopPreferences(
            languageMode: .english,
            themeMode: .dark,
            accountPoolDisplayMode: .list,
            hasSeenHelpWindow: true
        )
        try store.save(saved)

        XCTAssertEqual(store.load(), saved)
    }

    func testDesktopPreferencesStoreLoadsLegacyFileWithoutHelpWindowFlag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyPayload = """
        {
          "languageMode": "english",
          "themeMode": "dark"
        }
        """
        try Data(legacyPayload.utf8).write(to: Paths.desktopPreferencesURL(in: directory))

        let store = DesktopPreferencesStore(dataDirectory: directory)

        XCTAssertEqual(
            store.load(),
            DesktopPreferences(
                languageMode: .english,
                themeMode: .dark,
                interfaceMode: .full,
                accountPoolDisplayMode: .cards,
                hasSeenHelpWindow: false
            )
        )
    }

    func testDesktopPreferencesStoreFallsBackWhenFileIsCorrupted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("not-json".utf8).write(to: Paths.desktopPreferencesURL(in: directory))

        let store = DesktopPreferencesStore(dataDirectory: directory)
        XCTAssertEqual(store.load(), DesktopPreferences())
    }

    func testLocalizationStoreResolvesSystemChineseAndEnglish() {
        let chinese = LocalizationStore(mode: .system, preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(chinese.resolvedLanguage, .zhHans)
        XCTAssertEqual(chinese.text(.overviewTitle), "总览")

        let english = LocalizationStore(mode: .system, preferredLanguages: ["en-US"])
        XCTAssertEqual(english.resolvedLanguage, .english)
        XCTAssertEqual(english.text(.overviewTitle), "Overview")
    }

    func testLocalizationStoreLocalizesCommonErrorDetails() {
        let chinese = LocalizationStore(mode: .zhHans)
        XCTAssertEqual(
            chinese.errorDetail(for: #"{"error":{"message":"Invalid admin token.","type":"authentication_error"}}"#, context: .loadAll),
            "本地管理令牌无效，请刷新本地服务状态后重试。"
        )

        let english = LocalizationStore(mode: .english)
        XCTAssertEqual(
            english.errorDetail(for: "OAuth callback 缺少 code", context: .completeOAuth),
            "The callback URL is missing the `code` parameter. Complete the browser authorization again."
        )

        XCTAssertEqual(
            chinese.errorDetail(
                for: #"OAuth: {"detail":"Unsupported parameter: max_output_tokens"}"#,
                context: .runProxyTest
            ),
            "当前官方 OAuth 上游不支持参数 `max_output_tokens`，本地代理已加入兼容清洗。请重新发起这次请求。"
        )

        XCTAssertEqual(
            chinese.errorDetail(
                for: #"OAuth: {"detail":"The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account."}"#,
                context: .runProxyTest
            ),
            "当前 Anthropic 映射目标模型不兼容官方 OAuth 上游，本地代理会自动回退到 `gpt-5.5`。请重试，或在代理页调整模型映射规则。"
        )

        XCTAssertEqual(
            chinese.errorDetail(
                for: #"OAuth: {"detail":"Invalid value: 'input_text'. Supported values are: 'output_text' and 'refusal'."}"#,
                context: .runProxyTest
            ),
            "上游拒绝了 assistant 历史消息的内容块类型。本地代理已按角色兼容 assistant 文本为 `output_text`；如果仍出现这个错误，请更新到最新构建后重试。"
        )

        XCTAssertEqual(
            chinese.errorDetail(
                for: "Upstream stream returned response.failed. Raw upstream error: terminated",
                context: .runProxyTest
            ),
            "上游响应没有正常完成，建议稍后重试。"
        )

        XCTAssertEqual(
            english.errorDetail(
                for: "Upstream Gemini stream terminated before a final finishReason was received.",
                context: .runProxyTest
            ),
            "The upstream response did not complete normally. Try again in a moment."
        )
    }

    func testLocalizationStoreExplainsDecodingDiagnostics() {
        let chinese = LocalizationStore(mode: .zhHans)
        let detail = chinese.errorDetail(
            for: "Decoding GET /admin/stats/summary as AdminStatsSummary failed: missing key `latest_buckets` at `$.latest_buckets`. Missing auth_url Response body: {\"latest_buckets\":[]}",
            context: .loadAll
        )

        XCTAssertEqual(
            detail,
            """
            接口返回的数据字段和当前桌面端预期不一致。
            接口: GET /admin/stats/summary
            对象: AdminStatsSummary
            字段路径: $.latest_buckets
            问题: 缺少字段 `latest_buckets`
            """
        )
        XCTAssertEqual(
            chinese.errorTitle(
                for: "Decoding GET /admin/stats/summary as AdminStatsSummary failed: missing key `latest_buckets` at `$.latest_buckets`. Missing auth_url",
                context: .loadAll
            ),
            "统计数据读取失败"
        )
    }

    func testDecodingDiagnosticsIncludesEndpointAndCodingPath() {
        struct NestedPayload: Decodable {
            var root: Root

            struct Root: Decodable {
                var items: [Item]

                struct Item: Decodable {
                    var name: String
                }
            }
        }

        let body = Data(#"{"root":{"items":[{}]}}"#.utf8)

        do {
            _ = try Helpers.readJSON(NestedPayload.self, from: body)
            XCTFail("Expected decoding to fail")
        } catch {
            let message = DecodingDiagnostics.describe(
                error,
                endpoint: "/admin/example",
                method: "GET",
                targetType: NestedPayload.self,
                responseBody: body
            )

            XCTAssertNotNil(message)
            XCTAssertTrue(message?.contains("GET /admin/example") == true)
            XCTAssertTrue(message?.contains("missing key `name`") == true)
            XCTAssertTrue(message?.contains("$.root.items[0].name") == true)
        }
    }

    func testLocalizationStoreFormatsSuccessDetails() {
        let chinese = LocalizationStore(mode: .zhHans)
        XCTAssertEqual(
            chinese.successDetail(for: .startOAuth, rawDetail: "http://localhost:8788/auth/callback"),
            "本地浏览器回调地址：http://localhost:8788/auth/callback"
        )

        let english = LocalizationStore(mode: .english)
        XCTAssertEqual(
            english.successDetail(for: .completeOAuth, rawDetail: "Primary Account"),
            "Imported account: Primary Account"
        )
    }

    func testAppConfigDecodesSnakeCaseKeysWithDefaults() throws {
        let json = """
        {
          "public_host": "127.0.0.1",
          "public_port": 8787,
          "admin_port": 8788,
          "auto_start": true,
          "outbound_proxy": {
            "scheme": "http",
            "host": "127.0.0.1",
            "port": 7897,
            "username": "",
            "password": ""
          },
          "proxy_api_key": "sk-local-test",
          "admin_token": "adm-local-test",
          "stats_retention_days": 30,
          "window_close_behavior": "hideToMenuBar",
          "chat_gpt_base_url": "https://chatgpt.com",
          "daemon_binary_override": "/tmp/codex-proxyd"
        }
        """
        let config = try Helpers.readJSON(AppConfig.self, from: Data(json.utf8))
        let normalized = config.normalizedAnthropicModelConfig()

        XCTAssertEqual(config.proxyAPIKey, "sk-local-test")
        XCTAssertEqual(normalized.proxyAPIKeys.count, 1)
        XCTAssertEqual(normalized.primaryProxyAPIKeyRecord?.key, "sk-local-test")
        XCTAssertEqual(normalized.proxyAPIKeys.first?.dataSource, .openAI)
        XCTAssertEqual(config.adminToken, "adm-local-test")
        XCTAssertEqual(config.outboundProxy.scheme, .http)
        XCTAssertEqual(config.outboundProxy.port, 7897)
        XCTAssertEqual(config.daemonBinaryOverride, "/tmp/codex-proxyd")
        XCTAssertEqual(config.anthropicDefaultTargetModel, "gpt-5.5")
        XCTAssertEqual(config.anthropicModelMappings, [])
    }

    func testAppConfigIgnoresLegacyGeminiModelMappingFieldsAndDropsThemOnEncode() throws {
        let json = """
        {
          "proxy_api_key": "sk-local-test",
          "gemini_default_target_model": "gpt-5-mini",
          "gemini_model_mappings": [
            {
              "source_model": "gemini-2.5-pro",
              "target_model": "gpt-5.4"
            }
          ]
        }
        """

        let decoded = try Helpers.readJSON(AppConfig.self, from: Data(json.utf8))
        let encodedText = String(decoding: try Helpers.encodeJSON(decoded), as: UTF8.self)

        XCTAssertEqual(decoded.proxyAPIKey, "sk-local-test")
        XCTAssertEqual(decoded.anthropicDefaultTargetModel, AppConfig.defaultAnthropicTargetModel)
        XCTAssertEqual(decoded.anthropicModelMappings, [])
        XCTAssertFalse(encodedText.contains("gemini_default_target_model"))
        XCTAssertFalse(encodedText.contains("gemini_model_mappings"))
        XCTAssertFalse(encodedText.contains("geminiDefaultTargetModel"))
        XCTAssertFalse(encodedText.contains("geminiModelMappings"))
    }

    func testAppConfigIgnoresLegacyGeminiOAuthSettingsAndDropsThemOnEncode() throws {
        let json = """
        {
          "proxy_api_key": "sk-local-test",
          "gemini_oauth": {
            "client_id": " gemini-client-id ",
            "client_secret": " gemini-client-secret ",
            "scopes": "scope.one   scope.two",
            "user_project_id": " gemini-project ",
            "authorize_url": " https://accounts.google.com/o/oauth2/v2/auth ",
            "token_url": " https://oauth2.googleapis.com/token ",
            "api_base_url": " https://generativelanguage.googleapis.com "
          }
        }
        """

        let decoded = try Helpers.readJSON(AppConfig.self, from: Data(json.utf8))
        let encodedText = String(decoding: try Helpers.encodeJSON(decoded), as: UTF8.self)

        XCTAssertEqual(decoded.proxyAPIKey, "sk-local-test")
        XCTAssertFalse(encodedText.contains("gemini_oauth"))
        XCTAssertFalse(encodedText.contains("geminiOAuth"))
        XCTAssertFalse(encodedText.contains("client_secret"))
    }

    func testAppConfigNormalizesPrimaryProxyAPIKeySelection() {
        let first = ProxyAPIKeyRecord(id: "key-1", label: "Alpha", key: " sk-local-alpha ", enabled: false, createdAt: 1)
        let second = ProxyAPIKeyRecord(id: "key-2", label: "", key: "sk-local-beta", enabled: true, createdAt: 2)
        let config = AppConfig(
            proxyAPIKey: "legacy",
            proxyAPIKeys: [first, second],
            primaryProxyAPIKeyID: "key-1"
        ).normalizedAnthropicModelConfig()

        XCTAssertEqual(config.proxyAPIKeys.count, 2)
        XCTAssertEqual(config.primaryProxyAPIKeyID, "key-2")
        XCTAssertEqual(config.primaryProxyAPIKeyRecord?.key, "sk-local-beta")
        XCTAssertEqual(config.proxyAPIKey, "sk-local-beta")
        XCTAssertEqual(config.proxyAPIKeys[1].label, "API Key 2")
    }

    func testAppConfigNormalizationPreservesEmptyAllowedAccountKeysAsUnrestricted() {
        let config = AppConfig(
            proxyAPIKeys: [
                ProxyAPIKeyRecord(
                    id: "primary",
                    label: "Primary",
                    key: "sk-local-primary",
                    dataSource: .all,
                    allowedAccountKeys: [],
                    enabled: true,
                    createdAt: 1
                ),
            ],
            primaryProxyAPIKeyID: "primary"
        ).normalizedAnthropicModelConfig()

        XCTAssertEqual(config.proxyAPIKeys.first?.allowedAccountKeys, [])
    }

    func testAppConfigMigratesLegacyEnabledOutboundProxyToManualMode() throws {
        let json = """
        {
          "outbound_proxy": {
            "scheme": "socks5",
            "host": "127.0.0.1",
            "port": 7890,
            "username": "",
            "password": ""
          }
        }
        """

        let config = try Helpers.readJSON(AppConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.outboundProxyMode, .manual)
        XCTAssertEqual(config.outboundProxy.scheme, .socks5)
        XCTAssertEqual(config.managedProxySummary.providerName, ManagedProxyConfigSummary.defaultProviderName)
        XCTAssertEqual(config.managedProxySummary.autoUpdateIntervalHours, 24)
        XCTAssertEqual(config.managedProxySummary.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
    }

    func testAppConfigDefaultsOutboundProxyModeToDisabledWhenLegacyProxyIsDisabled() throws {
        let json = """
        {
          "outbound_proxy": {
            "scheme": "disabled",
            "host": "",
            "port": 0,
            "username": "",
            "password": ""
          }
        }
        """

        let config = try Helpers.readJSON(AppConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.outboundProxyMode, .disabled)
        XCTAssertEqual(config.outboundProxy.scheme, .disabled)
        XCTAssertFalse(config.managedProxySummary.subscriptionConfigured)
    }

    func testSecretStorePersistsAndClearsMihomoSubscriptionURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SecretStore(dataDirectory: directory)
        try store.setMihomoSubscriptionURL(nil)
        XCTAssertNil(try store.mihomoSubscriptionURL())

        try store.setMihomoSubscriptionURL("https://example.com/subscription")
        XCTAssertEqual(try store.mihomoSubscriptionURL(), "https://example.com/subscription")

        try store.setMihomoSubscriptionURL(nil)
        XCTAssertNil(try store.mihomoSubscriptionURL())
    }

    func testManagedProxyRuntimeValidatesSubscriptionURLSchemeAndHost() throws {
        XCTAssertEqual(
            try ManagedProxyRuntime.validatedSubscriptionURL("https://example.com/subscription"),
            "https://example.com/subscription"
        )
        XCTAssertNil(try ManagedProxyRuntime.validatedSubscriptionURL("   "))

        XCTAssertThrowsError(try ManagedProxyRuntime.validatedSubscriptionURL("ftp://example.com/subscription")) { error in
            XCTAssertTrue(error.localizedDescription.contains("HTTP"))
        }
        XCTAssertThrowsError(try ManagedProxyRuntime.validatedSubscriptionURL("/relative/path")) { error in
            XCTAssertTrue(error.localizedDescription.contains("HTTP"))
        }
    }

    func testManagedProxyRuntimeUsesPlannedDefaultHealthcheckURL() {
        XCTAssertEqual(ManagedProxyRuntime.defaultHealthcheckURL, "http://cp.cloudflare.com/generate_204")
    }

    func testManagedProxyConfigSummaryDefaultsHealthcheckURLWhenMissingOrInvalid() throws {
        let missing = try Helpers.readJSON(
            ManagedProxyConfigSummary.self,
            from: Data(#"{"subscriptionConfigured":true,"selectedNodeName":"Tokyo"}"#.utf8)
        )
        XCTAssertEqual(missing.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)

        let invalid = try Helpers.readJSON(
            ManagedProxyConfigSummary.self,
            from: Data(#"{"subscriptionConfigured":true,"healthcheckURL":"ftp://example.com"}"#.utf8)
        )
        XCTAssertEqual(invalid.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
    }

    func testManagedProxyConfigSummaryMigratesLegacyGoogleHealthcheckURLs() throws {
        let legacyHTTP = try Helpers.readJSON(
            ManagedProxyConfigSummary.self,
            from: Data(#"{"subscriptionConfigured":true,"healthcheckURL":"http://www.google.com/generate_204"}"#.utf8)
        )
        let legacyHTTPS = try Helpers.readJSON(
            ManagedProxyConfigSummary.self,
            from: Data(#"{"subscriptionConfigured":true,"healthcheckURL":"https://www.google.com/generate_204"}"#.utf8)
        )

        XCTAssertEqual(legacyHTTP.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertEqual(legacyHTTPS.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertEqual(
            try ManagedProxyRuntime.validatedHealthcheckURL("https://www.google.com/generate_204"),
            ManagedProxyConfigSummary.defaultHealthcheckURL
        )
    }

    func testManagedProxyPayloadsRoundTripURLFieldsWithSnakeCaseJSON() throws {
        let configPayload = ManagedProxyConfigPayload(subscriptionURL: "https://example.com/subscription")
        let configData = try Helpers.encodeJSON(configPayload, pretty: false)
        let configObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: configData) as? [String: Any])
        XCTAssertEqual(configObject["subscription_url"] as? String, "https://example.com/subscription")
        let decodedConfig = try Helpers.readJSON(ManagedProxyConfigPayload.self, from: configData)
        XCTAssertEqual(decodedConfig.subscriptionURL, "https://example.com/subscription")

        let healthcheckPayload = ManagedProxyHealthcheckConfigPayload(
            healthcheckURL: "https://latency.example.com/generate_204"
        )
        let healthcheckData = try Helpers.encodeJSON(healthcheckPayload, pretty: false)
        let healthcheckObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: healthcheckData) as? [String: Any])
        XCTAssertEqual(healthcheckObject["healthcheck_url"] as? String, "https://latency.example.com/generate_204")
        let decodedHealthcheck = try Helpers.readJSON(ManagedProxyHealthcheckConfigPayload.self, from: healthcheckData)
        XCTAssertEqual(decodedHealthcheck.healthcheckURL, "https://latency.example.com/generate_204")
    }

    func testManagedProxyRuntimeSnapshotKeepsRunningOutsideSubscriptionMode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerResponse = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let groupResponse = Self.managedProxyRuntimeGroupResponse(currentNodeName: "Tokyo")
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let sequence = ManagedProxyRuntimeRequestSequence(steps: [
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
        ])
        let runtime = try Self.makeManagedProxyRuntime(dataDirectory: directory, sequence: sequence)

        var config = AppConfig()
        config.outboundProxyMode = .manual

        let snapshot = try await runtime.snapshot(
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.mode, .manual)
        XCTAssertTrue(snapshot.subscriptionConfigured)
        XCTAssertEqual(snapshot.runtimeState, .running)
        XCTAssertTrue(snapshot.controllerReachable)
        XCTAssertEqual(snapshot.currentNodeName, "Tokyo")
        XCTAssertEqual(
            snapshot.listeners,
            [ManagedProxyListener(kind: .mixedPort, listenHost: "127.0.0.1", port: 8_890, nodeName: "Tokyo")]
        )
        sequence.assertDrained()
    }

    func testManagedProxyRuntimeApplyConfigurationStopsWhenSubscriptionClearsOutsideSubscriptionMode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let sequence = ManagedProxyRuntimeRequestSequence(steps: [])
        let runtime = try Self.makeManagedProxyRuntime(dataDirectory: directory, sequence: sequence)

        var config = AppConfig()
        config.outboundProxyMode = .manual

        let snapshot = try await runtime.applyConfiguration(
            config: config,
            subscriptionURL: nil
        )

        XCTAssertEqual(snapshot.mode, .manual)
        XCTAssertFalse(snapshot.subscriptionConfigured)
        XCTAssertEqual(snapshot.runtimeState, .stopped)
        XCTAssertFalse(snapshot.controllerReachable)
        XCTAssertTrue(snapshot.listeners.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.mihomoRuntimeStateURL(in: directory).path) == false)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckMergesImmediateDelayWhenProviderHistoryHasNotCaughtUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, url, proxySettings, timeoutMilliseconds in
                XCTAssertEqual(nodeName, "Tokyo")
                XCTAssertEqual(url, ManagedProxyRuntime.defaultHealthcheckURL)
                XCTAssertEqual(timeoutMilliseconds, ManagedProxyRuntime.defaultHealthcheckTimeoutMS)
                XCTAssertEqual(proxySettings.host, "127.0.0.1")
                XCTAssertEqual(proxySettings.scheme, .http)
                XCTAssertTrue(proxySettings.isEnabled)
                return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 84)
            },
            healthcheckTimestampProvider: { 1_710_000_500 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 84)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_500)
        XCTAssertEqual(snapshot.currentNodeName, "Tokyo")
        XCTAssertTrue(snapshot.listeners.allSatisfy { $0.kind != .nodeListener })
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckUsesDirectDelayAsAuthoritativeResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let providerWithFreshHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": [["delay": 71, "time": 1_710_000_300]]],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithFreshHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                XCTAssertEqual(nodeName, "Tokyo")
                return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 84)
            },
            healthcheckTimestampProvider: { 1_710_000_500 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 84)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_500)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckUsesFreshProviderDelayWhenDirectProbeFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let providerWithFreshHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": [["delay": 281, "time": 1_710_000_600]]],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithFreshHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                XCTAssertEqual(nodeName, "Tokyo")
                throw URLError(.timedOut)
            },
            healthcheckTimestampProvider: { 1_710_000_500 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 281)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_601)
        XCTAssertNil(snapshot.lastHealthcheckFeedbackDetail)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckKeepsProviderDelayWhenDirectProbeFlakes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": [["delay": 245, "time": 1_710_000_400]]],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithHistory,
            refreshedProviderResponse: providerWithHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                XCTAssertEqual(nodeName, "Tokyo")
                throw URLError(.cannotConnectToHost)
            },
            healthcheckTimestampProvider: { 1_710_000_500 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 245)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_500)
        XCTAssertNil(snapshot.lastHealthcheckFeedbackDetail)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckHandlesEmojiCJKSlashAndSpaceInNodeName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let nodeName = "🇯🇵日本/东京 01"
        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": nodeName, "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = Self.managedProxyRuntimeGroupResponse(currentNodeName: nodeName)
        let sequence = ManagedProxyRuntimeRequestSequence(
            steps: [
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                Self.managedProxyRuntimeDelayStep(
                    nodeName: nodeName,
                    responseBody: #"{"delay":96}"#
                ),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
            ]
        )
        let secretStore = try Self.makeManagedProxyRuntimeSecretStore(dataDirectory: directory)
        try Self.writeManagedProxyRuntimeState(dataDirectory: directory, controllerPort: 9_090)
        let runtime = ManagedProxyRuntime(
            dataDirectory: directory,
            secretStore: secretStore,
            session: Self.makeManagedProxyRuntimeSession(sequence: sequence),
            healthcheckTimestampProvider: { 1_710_000_600 },
            batchHealthcheckConcurrencyLimit: 1
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: nodeName,
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == nodeName })?.lastDelayMS, 96)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == nodeName })?.lastHealthcheckStatus, .success)
        XCTAssertTrue(snapshot.listeners.allSatisfy { $0.kind != .nodeListener })
        sequence.assertDrained()
    }

    func testManagedProxyHealthcheckSkipsSubscriptionMetadataNodes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerResponse = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "剩余流量：823.83 GB", "type": "ss", "alive": false, "history": []],
            ]
        )
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = Self.managedProxyRuntimeGroupResponse(currentNodeName: "Tokyo")
        let sequence = ManagedProxyRuntimeRequestSequence(
            steps: [
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerResponse),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerResponse),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                Self.managedProxyRuntimeDelayStep(
                    nodeName: "Tokyo",
                    responseBody: #"{"delay":88}"#
                ),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerResponse),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
            ]
        )
        let secretStore = try Self.makeManagedProxyRuntimeSecretStore(dataDirectory: directory)
        try Self.writeManagedProxyRuntimeState(dataDirectory: directory, controllerPort: 9_090)
        let runtime = ManagedProxyRuntime(
            dataDirectory: directory,
            secretStore: secretStore,
            session: Self.makeManagedProxyRuntimeSession(sequence: sequence),
            healthcheckTimestampProvider: { 1_710_000_800 },
            batchHealthcheckConcurrencyLimit: 1
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: nil,
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.map(\.name), ["Tokyo"])
        XCTAssertEqual(snapshot.nodes.first?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first?.lastDelayMS, 88)
        XCTAssertNil(snapshot.lastHealthcheckFeedbackDetail)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckFallsBackWhenPrimaryTargetFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let customHealthcheckURL = "https://latency.example.com/generate_204"
        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
            ]
        )
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = Self.managedProxyRuntimeGroupResponse(currentNodeName: "Tokyo")
        let sequence = ManagedProxyRuntimeRequestSequence(
            steps: [
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                Self.managedProxyRuntimeDelayStep(
                    nodeName: "Tokyo",
                    responseBody: #"{"message":"dial timeout"}"#,
                    statusCode: 504,
                    healthcheckURL: customHealthcheckURL
                ),
                Self.managedProxyRuntimeDelayStep(
                    nodeName: "Tokyo",
                    responseBody: #"{"delay":128}"#,
                    healthcheckURL: ManagedProxyRuntime.defaultHealthcheckURL
                ),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
                .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
                .init(method: "GET", path: groupPath, responseBody: groupResponse),
            ]
        )
        let secretStore = try Self.makeManagedProxyRuntimeSecretStore(dataDirectory: directory)
        try Self.writeManagedProxyRuntimeState(dataDirectory: directory, controllerPort: 9_090)
        let runtime = ManagedProxyRuntime(
            dataDirectory: directory,
            secretStore: secretStore,
            session: Self.makeManagedProxyRuntimeSession(sequence: sequence),
            healthcheckTimestampProvider: { 1_710_000_700 },
            batchHealthcheckConcurrencyLimit: 1
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.healthcheckURL = customHealthcheckURL

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 128)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertNil(snapshot.lastHealthcheckFeedbackDetail)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckReportsFailedFallbackTargets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let customHealthcheckURL = "https://latency.example.com/generate_204"
        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
            ]
        )
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = Self.managedProxyRuntimeGroupResponse(currentNodeName: "Tokyo")
        var steps: [ManagedProxyRuntimeRequestSequence.Step] = [
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
        ]
        for targetURL in [
            customHealthcheckURL,
            ManagedProxyRuntime.defaultHealthcheckURL,
            "http://www.gstatic.com/generate_204",
            "https://www.gstatic.com/generate_204",
        ] {
            steps.append(
                Self.managedProxyRuntimeDelayStep(
                    nodeName: "Tokyo",
                    responseBody: #"{"message":"dial timeout"}"#,
                    statusCode: 504,
                    healthcheckURL: targetURL
                )
            )
        }
        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))
        steps.append(.init(method: "GET", path: providerPath, responseBody: providerWithoutHistory))
        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))

        let sequence = ManagedProxyRuntimeRequestSequence(steps: steps)
        let secretStore = try Self.makeManagedProxyRuntimeSecretStore(dataDirectory: directory)
        try Self.writeManagedProxyRuntimeState(dataDirectory: directory, controllerPort: 9_090)
        let runtime = ManagedProxyRuntime(
            dataDirectory: directory,
            secretStore: secretStore,
            session: Self.makeManagedProxyRuntimeSession(sequence: sequence),
            healthcheckTimestampProvider: { 1_710_000_701 },
            batchHealthcheckConcurrencyLimit: 1
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.healthcheckURL = customHealthcheckURL

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .failure)
        XCTAssertNil(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS)
        XCTAssertTrue(snapshot.lastHealthcheckFeedbackDetail?.contains(customHealthcheckURL) == true)
        XCTAssertTrue(snapshot.lastHealthcheckFeedbackDetail?.contains(ManagedProxyRuntime.defaultHealthcheckURL) == true)
        XCTAssertTrue(snapshot.lastHealthcheckFeedbackDetail?.contains("http://www.gstatic.com/generate_204") == true)
        XCTAssertTrue(snapshot.lastHealthcheckFeedbackDetail?.contains("+1 target") == true)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckSummarizesControllerJSONErrors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
            ]
        )
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = Self.managedProxyRuntimeGroupResponse(currentNodeName: "Tokyo")
        var steps: [ManagedProxyRuntimeRequestSequence.Step] = [
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerWithoutHistory),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
        ]
        for targetURL in [
            ManagedProxyRuntime.defaultHealthcheckURL,
            "http://www.gstatic.com/generate_204",
            "https://www.gstatic.com/generate_204",
        ] {
            steps.append(
                Self.managedProxyRuntimeDelayStep(
                    nodeName: "Tokyo",
                    responseBody: #"{"message":"An error occurred in the delay test"}"#,
                    statusCode: 500,
                    healthcheckURL: targetURL
                )
            )
        }
        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))
        steps.append(.init(method: "GET", path: providerPath, responseBody: providerWithoutHistory))
        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))

        let sequence = ManagedProxyRuntimeRequestSequence(steps: steps)
        let secretStore = try Self.makeManagedProxyRuntimeSecretStore(dataDirectory: directory)
        try Self.writeManagedProxyRuntimeState(dataDirectory: directory, controllerPort: 9_090)
        let runtime = ManagedProxyRuntime(
            dataDirectory: directory,
            secretStore: secretStore,
            session: Self.makeManagedProxyRuntimeSession(sequence: sequence),
            healthcheckTimestampProvider: { 1_710_000_801 },
            batchHealthcheckConcurrencyLimit: 1
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first?.lastHealthcheckStatus, .failure)
        XCTAssertTrue(snapshot.lastHealthcheckFeedbackDetail?.contains("mihomo delay test failed") == true)
        XCTAssertFalse(snapshot.lastHealthcheckFeedbackDetail?.contains(#""message""#) == true)
        sequence.assertDrained()
    }

    func testManagedProxyHealthcheckDoesNotRewriteSavedNodeListenerPortMappings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let mappingURL = Paths.mihomoNodeListenerPortsURL(in: directory)
        try Helpers.writeFile(
            mappingURL,
            data: Data(#"{"portsByNodeName":{"Persistent Node":45678}}"#.utf8)
        )

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { _, _, _, _ in
                ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 80)
            },
            healthcheckTimestampProvider: { 1_710_000_600 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        _ = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        let mappingText = try String(contentsOf: mappingURL, encoding: .utf8)
        XCTAssertTrue(mappingText.contains(#""Persistent Node""#))
        XCTAssertTrue(mappingText.contains("45678"))
        XCTAssertFalse(mappingText.contains(#""Tokyo""#))
        sequence.assertDrained()
    }

    func testManagedProxyHealthcheckUsesConfiguredHealthcheckURLForRuntimeAndDirectChecks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let customHealthcheckURL = "https://latency.example.com/generate_204"
        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, url, _, _ in
                XCTAssertEqual(url, customHealthcheckURL)
                switch nodeName {
                case "Tokyo":
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 71)
                case "Seoul":
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 302, latencyMS: 88)
                default:
                    XCTFail("Unexpected node name: \(nodeName)")
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 1)
                }
            },
            healthcheckTimestampProvider: { 1_710_000_300 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.healthcheckURL = customHealthcheckURL

        let snapshot = try await runtime.healthcheck(
            nodeName: nil,
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.healthcheckURL, customHealthcheckURL)
        sequence.assertDrained()
    }

    func testManagedProxyHealthcheckPreservesCurrentNodeWhenPinnedDefaultDiffers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Seoul"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                XCTAssertEqual(nodeName, "Seoul")
                return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 92)
            },
            healthcheckTimestampProvider: { 1_710_000_300 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"

        let snapshot = try await runtime.healthcheck(
            nodeName: "Seoul",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.currentNodeName, "Seoul")
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastDelayMS, 92)
        XCTAssertTrue(snapshot.listeners.allSatisfy { $0.kind != .nodeListener })
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckUpdatesTimestampWhenDelayMatchesPreviousResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": [["delay": 84, "time": 1_710_000_300]]],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithHistory,
            refreshedProviderResponse: providerWithHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                XCTAssertEqual(nodeName, "Tokyo")
                return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 84)
            },
            healthcheckTimestampProvider: { 1_710_000_300 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 84)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_301)
        sequence.assertDrained()
    }

    func testManagedProxyBatchHealthcheckMergesDirectResultsWithoutWaitingForProviderHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let checkedAt = LockedInt64Counter(initialValue: 1_710_000_300)
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                switch nodeName {
                case "Tokyo":
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 71)
                case "Seoul":
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 88)
                default:
                    XCTFail("Unexpected node name: \(nodeName)")
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 1)
                }
            },
            healthcheckTimestampProvider: { checkedAt.next() }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: nil,
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 71)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_300)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastDelayMS, 88)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastHealthcheckAt, 1_710_000_301)
        XCTAssertTrue(snapshot.listeners.allSatisfy { $0.kind != .nodeListener })
        sequence.assertDrained()
    }

    func testManagedProxyBatchHealthcheckMarksOnlySuccessfulDirectResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                switch nodeName {
                case "Tokyo":
                    throw URLError(.timedOut)
                case "Seoul":
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 88)
                default:
                    XCTFail("Unexpected node name: \(nodeName)")
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 1)
                }
            },
            healthcheckTimestampProvider: { 1_710_000_300 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: nil,
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertNil(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .failure)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_300)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastDelayMS, 88)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastHealthcheckAt, 1_710_000_300)
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckTreatsUnexpectedHTTPStatusAsSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                XCTAssertEqual(nodeName, "Tokyo")
                return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 503, latencyMS: 265)
            },
            healthcheckTimestampProvider: { 1_710_000_500 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS, 265)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .success)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_500)
        sequence.assertDrained()
    }

    func testManagedProxyBatchHealthcheckReturnsSnapshotWhenAllDirectResultsFail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { _, _, _, _ in
                throw URLError(.timedOut)
            },
            healthcheckTimestampProvider: { 1_710_000_300 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: nil,
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertNil(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastDelayMS)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .failure)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckAt, 1_710_000_300)
        XCTAssertNil(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastDelayMS)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastHealthcheckStatus, .failure)
        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Seoul" })?.lastHealthcheckAt, 1_710_000_300)
        XCTAssertEqual(snapshot.currentNodeName, "Tokyo")
        sequence.assertDrained()
    }

    func testManagedProxySingleNodeHealthcheckReportsListenerNotReadyFeedbackDetail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { _, _, _, _ in
                throw HTTPProxyProbeError.listenerUnavailable()
            },
            healthcheckTimestampProvider: { 1_710_000_500 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: "Tokyo",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(snapshot.nodes.first(where: { $0.name == "Tokyo" })?.lastHealthcheckStatus, .failure)
        XCTAssertEqual(
            snapshot.lastHealthcheckFeedbackDetail,
            "http://cp.cloudflare.com/generate_204: Node listener is not ready; "
                + "http://www.gstatic.com/generate_204: Node listener is not ready; "
                + "https://www.gstatic.com/generate_204: Node listener is not ready"
        )
        sequence.assertDrained()
    }

    func testManagedProxyBatchHealthcheckAggregatesFailureFeedbackDetail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerWithoutHistory = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Osaka", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
                ["name": "Singapore", "type": "trojan", "alive": true, "history": []],
            ]
        )
        let sequence = Self.managedProxyRuntimeHealthcheckSequence(
            initialProviderResponse: providerWithoutHistory,
            refreshedProviderResponse: providerWithoutHistory,
            currentNodeName: "Tokyo"
        )
        let runtime = try Self.makeManagedProxyRuntime(
            dataDirectory: directory,
            sequence: sequence,
            nodeHealthcheckProbeHandler: { nodeName, _, _, _ in
                switch nodeName {
                case "Tokyo":
                    throw HTTPProxyProbeError(kind: .timeout)
                case "Osaka":
                    throw HTTPProxyProbeError(kind: .proxyConnectionFailed)
                case "Seoul":
                    throw HTTPProxyProbeError(kind: .tlsHandshakeFailed)
                case "Singapore":
                    throw HTTPProxyProbeError(kind: .invalidHTTPResponse)
                default:
                    XCTFail("Unexpected node name: \(nodeName)")
                    return ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 1)
                }
            },
            healthcheckTimestampProvider: { 1_710_000_300 }
        )

        var config = AppConfig()
        config.outboundProxyMode = .subscription

        let snapshot = try await runtime.healthcheck(
            nodeName: nil,
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(
            snapshot.lastHealthcheckFeedbackDetail,
            "Tokyo: http://cp.cloudflare.com/generate_204: Probe timed out; "
                + "http://www.gstatic.com/generate_204: Probe timed out; "
                + "https://www.gstatic.com/generate_204: Probe timed out; "
                + "Osaka: http://cp.cloudflare.com/generate_204: Proxy connection failed; "
                + "http://www.gstatic.com/generate_204: Proxy connection failed; "
                + "https://www.gstatic.com/generate_204: Proxy connection failed; "
                + "Seoul: http://cp.cloudflare.com/generate_204: TLS handshake failed; "
                + "http://www.gstatic.com/generate_204: TLS handshake failed; "
                + "https://www.gstatic.com/generate_204: TLS handshake failed; +1 more"
        )
        sequence.assertDrained()
    }

    func testHTTPProxyProbeTreatsAnyHTTPResponseAsSuccess() async throws {
        let server = try LocalHTTPProbeServer(response: .http(statusCode: 503))
        defer { server.stop() }

        let response = try await HTTPProxyProbe.probe(
            url: "http://127.0.0.1:\(server.port)/probe",
            proxySettings: .init(),
            timeoutMilliseconds: 1_000
        )

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertGreaterThan(response.latencyMilliseconds, 0)
    }

    func testHTTPProxyProbeClassifiesTimeout() async {
        let server = try! LocalHTTPProbeServer(response: .stall(milliseconds: 200))
        defer { server.stop() }

        do {
            _ = try await HTTPProxyProbe.probe(
                url: "http://127.0.0.1:\(server.port)/timeout",
                proxySettings: .init(),
                timeoutMilliseconds: 50
            )
            XCTFail("Expected timeout")
        } catch let error as HTTPProxyProbeError {
            XCTAssertEqual(error.kind, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTPProxyProbeClassifiesProxyConnectionFailure() async {
        let unavailablePort = try! XCTUnwrap(POSIXCompat.availableTCPIPv4LoopbackPort(preferred: 0))

        do {
            _ = try await HTTPProxyProbe.probe(
                url: "http://example.com/probe",
                proxySettings: OutboundProxySettings(
                    scheme: .http,
                    host: "127.0.0.1",
                    port: unavailablePort
                ),
                timeoutMilliseconds: 100
            )
            XCTFail("Expected proxy connection failure")
        } catch let error as HTTPProxyProbeError {
            XCTAssertEqual(error.kind, .proxyConnectionFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManagedProxyBatchHealthcheckConcurrencyLimitClampsToTen() {
        XCTAssertEqual(ManagedProxyRuntime.batchHealthcheckConcurrencyLimit(nodeCount: 0), 0)
        XCTAssertEqual(ManagedProxyRuntime.batchHealthcheckConcurrencyLimit(nodeCount: 2), 2)
        XCTAssertEqual(ManagedProxyRuntime.batchHealthcheckConcurrencyLimit(nodeCount: 24), 10)
        XCTAssertEqual(ManagedProxyRuntime.batchHealthcheckConcurrencyLimit(nodeCount: 24, maxLimit: 4), 4)
    }

    func testManagedProxyAccountNodeListenerWritesListenerConfigAndReturnsDedicatedPort() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { ManagedProxyRuntimeMockURLProtocol.resetHandler() }

        let providerResponse = try Self.managedProxyRuntimeProviderResponse(
            proxies: [
                ["name": "Tokyo", "type": "ss", "alive": true, "history": []],
                ["name": "Seoul", "type": "vmess", "alive": true, "history": []],
            ]
        )
        let groupResponse = Self.managedProxyRuntimeGroupResponse(currentNodeName: "Tokyo")
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let sequence = ManagedProxyRuntimeRequestSequence(steps: [
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "PUT", path: "/configs", query: ["force": "true"], responseBody: "{}"),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: providerResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
        ])
        let runtime = try Self.makeManagedProxyRuntime(dataDirectory: directory, sequence: sequence)

        var config = AppConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        config.managedProxySummary.healthcheckURL = "https://latency.example.com/generate_204"

        let settings = try await runtime.effectiveProxySettingsForAccountNode(
            name: "Seoul",
            config: config,
            subscriptionURL: "https://example.com/subscription"
        )

        XCTAssertEqual(settings.scheme, .http)
        XCTAssertEqual(settings.host, "127.0.0.1")
        XCTAssertGreaterThan(settings.port, 0)
        XCTAssertNotEqual(settings.port, ManagedProxyRuntime.defaultMixedPort)
        XCTAssertNotEqual(settings.port, ManagedProxyRuntime.defaultControllerPort)

        let configText = try String(
            contentsOf: Paths.mihomoConfigURL(in: directory),
            encoding: .utf8
        )
        let expectedHash = String(Helpers.sha256("Seoul").prefix(16))
        XCTAssertTrue(configText.contains("listeners:"))
        XCTAssertTrue(configText.contains(#"filter: "^Seoul$""#))
        XCTAssertTrue(configText.contains(#"url: "https://latency.example.com/generate_204""#))
        XCTAssertTrue(configText.contains(#"proxy: "CodexProxyNodeGroup_\#(expectedHash)""#))
        XCTAssertTrue(configText.contains(#"name: "CodexProxyNodeListener_\#(expectedHash)""#))

        let portMappingsData = try Data(contentsOf: Paths.mihomoNodeListenerPortsURL(in: directory))
        let portMappingsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: portMappingsData) as? [String: Any]
        )
        let persistedPorts = try XCTUnwrap(portMappingsObject["ports_by_node_name"] as? [String: Any])
        XCTAssertEqual(persistedPorts["Seoul"] as? Int, settings.port)
        sequence.assertDrained()
    }

    func testManagedProxyNodeCodablePreservesCurrentPinnedAndLegacySelectedFields() throws {
        let node = ManagedProxyNode(
            name: "Tokyo",
            type: "ss",
            isCurrent: true,
            isPinned: true,
            alive: true,
            lastDelayMS: 80,
            lastHealthcheckStatus: .success,
            lastHealthcheckAt: 1_710_000_100
        )

        let encoded = try Helpers.encodeJSON(node, pretty: false)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["is_current"] as? Bool, true)
        XCTAssertEqual(object["is_pinned"] as? Bool, true)
        XCTAssertEqual(object["selected"] as? Bool, true)
        XCTAssertEqual(object["last_delay_ms"] as? Int, 80)
        XCTAssertEqual(object["last_healthcheck_status"] as? String, "success")

        let encodedDecoded = try Helpers.readJSON(ManagedProxyNode.self, from: encoded)
        XCTAssertEqual(encodedDecoded.lastDelayMS, 80)

        let legacyDecoded = try Helpers.readJSON(
            ManagedProxyNode.self,
            from: Data(#"{"name":"Seoul","type":"vmess","selected":true}"#.utf8)
        )
        XCTAssertTrue(legacyDecoded.isCurrent)
        XCTAssertFalse(legacyDecoded.isPinned)

        let decoded = try Helpers.readJSON(
            ManagedProxyNode.self,
            from: Data(
                #"{"name":"Osaka","type":"trojan","last_delay_ms":84,"last_healthcheck_status":"failure","last_healthcheck_at":1710000100}"#.utf8
            )
        )
        XCTAssertEqual(decoded.lastDelayMS, 84)
        XCTAssertEqual(decoded.lastHealthcheckStatus, .failure)
        XCTAssertEqual(decoded.lastHealthcheckAt, 1_710_000_100)
    }

    func testManagedProxySnapshotCodablePreservesPinnedAndLegacySelectedFields() throws {
        let snapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            healthcheckURL: "https://latency.example.com/generate_204",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Seoul",
            pinnedNodeAvailable: true,
            listeners: [
                ManagedProxyListener(kind: .mixedPort, listenHost: "127.0.0.1", port: 7_897, nodeName: "Tokyo"),
                ManagedProxyListener(kind: .nodeListener, listenHost: "127.0.0.1", port: 7_898, nodeName: "Seoul"),
            ],
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: false, alive: true, lastDelayMS: 88),
                ManagedProxyNode(name: "Seoul", type: "vmess", isCurrent: false, isPinned: true, alive: true, lastDelayMS: 110),
            ],
            lastHealthcheckFeedbackDetail: "Tokyo: Probe timed out"
        )

        let encoded = try Helpers.encodeJSON(snapshot, pretty: false)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["pinned_node_name"] as? String, "Seoul")
        XCTAssertEqual(object["selected_node_name"] as? String, "Seoul")
        XCTAssertEqual(object["pinned_node_available"] as? Bool, true)
        XCTAssertEqual(object["selected_node_available"] as? Bool, true)
        XCTAssertEqual(object["healthcheck_url"] as? String, "https://latency.example.com/generate_204")
        XCTAssertEqual(object["last_healthcheck_feedback_detail"] as? String, "Tokyo: Probe timed out")
        let listeners = try XCTUnwrap(object["listeners"] as? [[String: Any]])
        XCTAssertEqual(listeners.count, 2)
        XCTAssertEqual(listeners[0]["kind"] as? String, "mixed-port")
        XCTAssertEqual(listeners[0]["listen_host"] as? String, "127.0.0.1")
        XCTAssertEqual(listeners[0]["port"] as? Int, 7_897)
        XCTAssertEqual(listeners[0]["node_name"] as? String, "Tokyo")
        XCTAssertEqual(listeners[1]["kind"] as? String, "node-listener")
        XCTAssertEqual(listeners[1]["listen_host"] as? String, "127.0.0.1")
        XCTAssertEqual(listeners[1]["port"] as? Int, 7_898)
        XCTAssertEqual(listeners[1]["node_name"] as? String, "Seoul")

        let legacyDecoded = try Helpers.readJSON(
            ManagedProxySnapshot.self,
            from: Data(#"{"mode":"subscription","currentNodeName":"Tokyo","selectedNodeName":"Seoul","selectedNodeAvailable":true}"#.utf8)
        )
        XCTAssertEqual(legacyDecoded.pinnedNodeName, "Seoul")
        XCTAssertTrue(legacyDecoded.pinnedNodeAvailable)
        XCTAssertEqual(legacyDecoded.selectedNodeName, "Seoul")
        XCTAssertTrue(legacyDecoded.selectedNodeAvailable)
        XCTAssertEqual(legacyDecoded.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertTrue(legacyDecoded.listeners.isEmpty)
        XCTAssertNil(legacyDecoded.lastHealthcheckFeedbackDetail)
    }

    func testSecretStorePersistsAndDeletesAnthropicOAuthSecretBundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SecretStore(dataDirectory: directory)
        let bundle = AnthropicOAuthSecretBundle(
            accessToken: "anthropic-access",
            refreshToken: "anthropic-refresh",
            expiresAt: Helpers.now() + 3_600,
            tokenType: "Bearer",
            scope: "user:profile user:inference"
        )

        let ref = try store.saveAnthropicOAuthSecret(bundle)
        XCTAssertEqual(try store.loadAnthropicOAuthSecret(ref: ref), bundle)

        try store.deleteAnthropicOAuthSecret(ref: ref)
        XCTAssertNil(store.loadAnthropicOAuthSecretIfPresent(ref: ref))
    }

    #if os(macOS)
    func testMihomoControllerSecretUsesFileWhenKeychainReadAuthFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Helpers.writeFile(
            Paths.mihomoControllerSecretURL(in: directory),
            data: Data("controller-from-file".utf8)
        )

        let keychain = TestKeychainAdapter(
            readStatusByAccount: ["mihomo-controller-secret": errSecAuthFailed]
        )
        let store = SecretStore(
            dataDirectory: directory,
            keychainAdapter: keychain,
            keychainEnabledOverride: true
        )

        XCTAssertEqual(try store.mihomoControllerSecret(), "controller-from-file")
        XCTAssertEqual(keychain.readAttempts(), [])
    }

    func testMihomoControllerSecretRegeneratesWhenKeychainReadAuthFailsAndMirrorWriteFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = TestKeychainAdapter(
            readStatusByAccount: ["mihomo-controller-secret": errSecAuthFailed],
            addStatusByAccount: ["mihomo-controller-secret": errSecAuthFailed]
        )
        let store = SecretStore(
            dataDirectory: directory,
            keychainAdapter: keychain,
            keychainEnabledOverride: true
        )

        let generated = try store.mihomoControllerSecret()
        let persisted = try String(
            contentsOf: Paths.mihomoControllerSecretURL(in: directory),
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertFalse(generated.isEmpty)
        XCTAssertEqual(persisted, generated)
        XCTAssertEqual(try store.mihomoControllerSecret(), generated)
    }

    func testAdminTokenUsesFileWhenKeychainReadAuthFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Helpers.writeFile(
            Paths.adminTokenURL(in: directory),
            data: Data("adm-local-file".utf8)
        )

        let keychain = TestKeychainAdapter(
            readStatusByAccount: ["admin-token": errSecAuthFailed]
        )
        let store = SecretStore(
            dataDirectory: directory,
            keychainAdapter: keychain,
            keychainEnabledOverride: true
        )

        XCTAssertEqual(try store.adminToken(), "adm-local-file")
        XCTAssertEqual(keychain.readAttempts(), [])
    }

    func testStableSecretsDoNotSilentlyRotateWhenKeychainAuthFailsWithoutFallbackFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = TestKeychainAdapter(
            readStatusByAccount: [
                "admin-token": errSecAuthFailed,
                "proxy-api-key": errSecAuthFailed,
                "master-key": errSecAuthFailed,
            ]
        )
        let store = SecretStore(
            dataDirectory: directory,
            keychainAdapter: keychain,
            keychainEnabledOverride: true
        )

        XCTAssertThrowsError(try store.adminToken()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Keychain read failed"))
        }
        XCTAssertThrowsError(try store.proxyAPIKey()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Keychain read failed"))
        }
        XCTAssertThrowsError(try store.masterKey()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Keychain read failed"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.adminTokenURL(in: directory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.proxyAPIKeyURL(in: directory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.keyFileURL(in: directory).path))
    }

    func testAnthropicOAuthSecretBundleLoadsFromFileWhenKeychainAddAndReadFail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = TestKeychainAdapter(
            readStatusByAccount: ["anthropic-oauth-test-ref": errSecAuthFailed],
            addStatusByAccount: ["anthropic-oauth-test-ref": errSecAuthFailed]
        )
        let store = SecretStore(
            dataDirectory: directory,
            keychainAdapter: keychain,
            keychainEnabledOverride: true
        )
        let bundle = AnthropicOAuthSecretBundle(
            accessToken: "anthropic-access",
            refreshToken: "anthropic-refresh",
            expiresAt: Helpers.now() + 3_600,
            tokenType: "Bearer",
            scope: "user:profile user:inference"
        )

        let ref = try store.saveAnthropicOAuthSecret(bundle, ref: "test-ref")
        XCTAssertEqual(ref, "test-ref")
        XCTAssertEqual(try store.loadAnthropicOAuthSecret(ref: ref), bundle)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: Paths.anthropicOAuthSecretURL(ref: ref, in: directory).path
            )
        )
    }
    #endif

    func testSecretStoreFallsBackToFilesWhenKeychainIsDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await Self.withEnvironment(["CODEX_PROXY_DISABLE_KEYCHAIN": "1"]) {
            let store = SecretStore(dataDirectory: directory)

            let adminToken = try store.adminToken()
            XCTAssertEqual(
                try String(contentsOf: Paths.adminTokenURL(in: directory), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                adminToken
            )

            let proxyAPIKey = try store.proxyAPIKey()
            XCTAssertEqual(
                try String(contentsOf: Paths.proxyAPIKeyURL(in: directory), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                proxyAPIKey
            )

            let bundle = GeminiOAuthSecretBundle(
                accessToken: "gemini-access",
                refreshToken: "gemini-refresh",
                expiresAt: Helpers.now() + 3_600,
                tokenType: "Bearer",
                scope: "scope-a scope-b"
            )
            let ref = try store.saveGeminiOAuthSecret(bundle)
            XCTAssertEqual(try store.loadGeminiOAuthSecret(ref: ref), bundle)
            XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.geminiOAuthSecretURL(ref: ref, in: directory).path))
        }
    }

    func testAppConfigNormalizesAnthropicModelMappings() {
        let config = AppConfig(
            anthropicDefaultTargetModel: "future-default-model",
            anthropicModelMappings: [
                .init(sourceModel: "", targetModel: "gpt-5.4-mini"),
                .init(sourceModel: "claude-sonnet-4-5", targetModel: "gpt-5.4-mini"),
                .init(sourceModel: "claude-sonnet-4-5", targetModel: "future-target-model"),
                .init(sourceModel: "claude-empty-target", targetModel: " "),
                .init(sourceModel: "claude-3-5-haiku-latest", targetModel: "gpt-5.4-mini"),
            ]
        ).normalizedAnthropicModelConfig()

        XCTAssertEqual(config.anthropicDefaultTargetModel, "future-default-model")
        XCTAssertEqual(
            config.anthropicModelMappings,
            [
                .init(sourceModel: "claude-sonnet-4-5", targetModel: "future-target-model"),
                .init(sourceModel: "claude-empty-target", targetModel: "future-default-model"),
                .init(sourceModel: "claude-3-5-haiku-latest", targetModel: "gpt-5.4-mini"),
            ]
        )
    }

    func testRemoteHostConfigDecodesSnakeCaseKeys() throws {
        let json = """
        {
          "id": "host-1",
          "label": "Prod",
          "host": "192.168.0.8",
          "ssh_port": 2222,
          "ssh_user": "deploy",
          "auth_mode": "password",
          "identity_file": "",
          "private_key": "",
          "password": "secret",
          "remote_directory": "/opt/codex-proxy",
          "public_port": 9000,
          "admin_port": 9001
        }
        """
        let host = try Helpers.readJSON(RemoteHostConfig.self, from: Data(json.utf8))

        XCTAssertEqual(host.id, "host-1")
        XCTAssertEqual(host.sshPort, 2222)
        XCTAssertEqual(host.sshUser, "deploy")
        XCTAssertEqual(host.authMode, .password)
        XCTAssertEqual(host.publicPort, 9000)
        XCTAssertEqual(host.adminPort, 9001)
    }

    private static func fetchLocalHTML(from urlString: String, acceptLanguage: String? = nil) async throws -> (Int, String) {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        if let acceptLanguage {
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (httpResponse.statusCode, String(decoding: data, as: UTF8.self))
    }

    private static func string(from buffer: ByteBuffer) -> String {
        String(buffer: buffer)
    }

    private static func string(from requestBody: RequestBody) async throws -> String {
        var data = Data()
        for try await chunk in requestBody {
            data.append(contentsOf: chunk.readableBytesView)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeAccountService(dataDirectory: URL) throws -> AccountService {
        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let store = try SQLiteStore(dataDirectory: dataDirectory, secretStore: secretStore)
        return AccountService(store: store, secretStore: secretStore)
    }

    private static func writeLegacyAccountsDatabase(
        dataDirectory: URL,
        secretStore: SecretStore,
        records: [AccountRecord]
    ) throws {
        var db: OpaquePointer?
        let path = Paths.databaseURL(in: dataDirectory).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw ProxyError.message("failed to open legacy sqlite database")
        }
        guard let db else {
            throw ProxyError.message("legacy sqlite database handle unavailable")
        }
        defer { sqlite3_close(db) }

        try Self.execSQLite(
            """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                principal_id TEXT NOT NULL,
                email TEXT,
                account_id TEXT NOT NULL,
                plan_type TEXT,
                auth_blob BLOB NOT NULL,
                added_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                usage_json BLOB,
                usage_error TEXT,
                auth_refresh_blocked INTEGER NOT NULL DEFAULT 0,
                auth_refresh_error TEXT,
                auth_mode TEXT NOT NULL DEFAULT 'chatgpt',
                upstream_base_url TEXT
            );
            """,
            db: db
        )
        try Self.execSQLite(
            "CREATE UNIQUE INDEX idx_accounts_account_key ON accounts(principal_id, account_id);",
            db: db
        )

        let key = try secretStore.masterKey()
        let sql = """
        INSERT INTO accounts (
            id, label, principal_id, email, account_id, plan_type, auth_blob, added_at, updated_at,
            enabled, usage_json, usage_error, auth_refresh_blocked, auth_refresh_error, auth_mode, upstream_base_url
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProxyError.message("failed to prepare legacy account insert")
        }
        defer { sqlite3_finalize(statement) }

        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            let authBlob = try CryptoBox.seal(Data(record.authJSON.utf8), using: key)
            let usageData = try record.usage.map { try Helpers.encodeJSON($0) }

            try Self.bindText(record.id, at: 1, to: statement)
            try Self.bindText(record.label, at: 2, to: statement)
            try Self.bindText(record.principalID, at: 3, to: statement)
            try Self.bindOptionalText(record.email, at: 4, to: statement)
            try Self.bindText(record.accountID, at: 5, to: statement)
            try Self.bindOptionalText(record.planType, at: 6, to: statement)
            try Self.bindBlob(authBlob, at: 7, to: statement)
            sqlite3_bind_int64(statement, 8, record.addedAt)
            sqlite3_bind_int64(statement, 9, record.updatedAt)
            sqlite3_bind_int64(statement, 10, record.enabled ? 1 : 0)
            if let usageData {
                try Self.bindBlob(usageData, at: 11, to: statement)
            } else {
                sqlite3_bind_null(statement, 11)
            }
            try Self.bindOptionalText(record.usageError, at: 12, to: statement)
            sqlite3_bind_int64(statement, 13, record.authRefreshBlocked ? 1 : 0)
            try Self.bindOptionalText(record.authRefreshError, at: 14, to: statement)
            try Self.bindText(record.authMode.rawValue, at: 15, to: statement)
            try Self.bindOptionalText(record.upstreamBaseURL, at: 16, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ProxyError.message("failed to insert legacy account row")
            }
        }
    }

    private static func writeLegacyRequestLogsDatabase(
        dataDirectory: URL,
        timestamp: Int64
    ) throws {
        var db: OpaquePointer?
        let path = Paths.databaseURL(in: dataDirectory).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw ProxyError.message("failed to open legacy request log sqlite database")
        }
        guard let db else {
            throw ProxyError.message("legacy request log sqlite database handle unavailable")
        }
        defer { sqlite3_close(db) }

        try Self.execSQLite(
            """
            CREATE TABLE request_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                endpoint TEXT NOT NULL,
                api_key_hash TEXT NOT NULL,
                api_key_cipher BLOB,
                account_key TEXT NOT NULL,
                account_label TEXT NOT NULL,
                model TEXT NOT NULL,
                success INTEGER NOT NULL,
                latency_ms INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                total_tokens INTEGER NOT NULL DEFAULT 0,
                cache_hit_tokens INTEGER,
                failure_category TEXT NOT NULL,
                last_error TEXT
            );
            """,
            db: db
        )
        try Self.execSQLite(
            """
            INSERT INTO request_logs (
                id, created_at, endpoint, api_key_hash, api_key_cipher, account_key, account_label,
                model, success, latency_ms, input_tokens, output_tokens, total_tokens, cache_hit_tokens,
                failure_category, last_error
            ) VALUES (
                1, \(timestamp), '/v1/responses', 'legacy-hash', NULL, 'principal|account', 'Legacy Account',
                'gpt-5.4', 1, 120, 10, 6, 16, 2, 'none', NULL
            );
            """,
            db: db
        )
    }

    private static func execSQLite(_ sql: String, db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ProxyError.message("legacy sqlite exec failed")
        }
    }

    private static func sqliteColumnNames(in table: String, dataDirectory: URL) throws -> Set<String> {
        var db: OpaquePointer?
        let path = Paths.databaseURL(in: dataDirectory).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw ProxyError.message("failed to open sqlite database for column inspection")
        }
        guard let db else {
            throw ProxyError.message("sqlite database handle unavailable for column inspection")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let pragma = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, pragma, -1, &statement, nil) == SQLITE_OK else {
            throw ProxyError.message("failed to inspect sqlite columns")
        }
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawName = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: rawName))
            }
        }
        return names
    }

    private static func bindText(_ value: String, at index: Int32, to statement: OpaquePointer?) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor) == SQLITE_OK else {
            throw ProxyError.message("legacy sqlite text bind failed")
        }
    }

    private static func bindOptionalText(_ value: String?, at index: Int32, to statement: OpaquePointer?) throws {
        if let value {
            try self.bindText(value, at: index, to: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func bindBlob(_ data: Data, at index: Int32, to statement: OpaquePointer?) throws {
        let status = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, index, rawBuffer.baseAddress, Int32(data.count), sqliteTransientDestructor)
        }
        guard status == SQLITE_OK else {
            throw ProxyError.message("legacy sqlite blob bind failed")
        }
    }

    private static func makeOpenAICompatibleModelsApplication(
        status: HTTPResponse.Status = .ok,
        models: [String] = ["gpt-5.4"],
        errorMessage: String = "models unavailable"
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("v1/models") { _, _ in
            let body: String
            if status == .ok {
                let modelsJSON = models.map {
                    #"{"id":"\#($0)","object":"model","created":0,"owned_by":"openai"}"#
                }
                .joined(separator: ",")
                body = #"{"object":"list","data":[\#(modelsJSON)]}"#
            } else {
                body = #"{"error":{"message":"\#(errorMessage)"}}"#
            }
            return Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
        router.post("v1/responses") { _, _ in
            let body = #"{"id":"resp_validation","status":"completed","output":[]}"#
            return Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
        return Application(router: router)
    }

    private static func makeDelayedOpenAICompatibleModelsApplication(
        probe: ConcurrentRequestProbe,
        delayMS: Int64 = 100
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("v1/models") { _, _ async throws in
            await probe.begin()
            do {
                try await Task.sleep(for: .milliseconds(delayMS))
                await probe.end()
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5.4","object":"model","created":0,"owned_by":"openai"}]}"#))
                )
            } catch {
                await probe.end()
                throw error
            }
        }
        router.post("v1/responses") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"id":"resp_validation","status":"completed","output":[]}"#))
            )
        }
        return Application(router: router)
    }

    private static func makeAnthropicValidationFallbackApplication(
        modelsStatus: HTTPResponse.Status = .ok,
        modelsBody: String? = nil,
        messagesStatus: HTTPResponse.Status = .ok,
        messagesBody: String? = nil,
        expectedMessagesModel: String? = nil,
        expectedProbeText: String? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("v1/models") { _, _ in
            let body: String
            if modelsStatus == .ok {
                body = modelsBody ?? #"{"data":[{"id":"claude-sonnet-4-5","type":"model","display_name":"Claude Sonnet 4.5"}]}"#
            } else {
                body = modelsBody ?? ""
            }
            return Response(
                status: modelsStatus,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
        router.post("v1/messages") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? ""

            if let expectedMessagesModel, model != expectedMessagesModel {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"expected model \#(expectedMessagesModel), got \#(model)"}}"#
                        )
                    )
                )
            }
            if let expectedProbeText, body.contains(expectedProbeText) == false {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"expected probe text \#(expectedProbeText)"}}"#
                        )
                    )
                )
            }

            let responseBody = messagesBody ?? """
            {
              "id": "msg_validation_probe",
              "type": "message",
              "role": "assistant",
              "model": "\(model)",
              "content": [
                {
                  "type": "text",
                  "text": "Validation probe ok"
                }
              ],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 2,
                "output_tokens": 1
              }
            }
            """
            return Response(
                status: messagesStatus,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: responseBody))
            )
        }
        return Application(router: router)
    }

    private static func makeOpenAICompatibleValidationFallbackApplication(
        probe: ManualValidationProbe,
        providerPreset: OpenAICompatibleProviderPreset,
        modelsStatus: HTTPResponse.Status = .notFound,
        modelsBody: String? = nil,
        unsupportedModels: Set<String> = []
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        switch providerPreset {
        case .genericOpenAICompatible:
            router.get("v1/models") { _, _ async throws -> Response in
                await probe.recordModelsHit()
                return Response(
                    status: modelsStatus,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: modelsStatus == .ok
                                ? #"{"object":"list","data":[{"id":"gpt-5.4","object":"model","created":0,"owned_by":"openai"}]}"#
                                : (modelsBody ?? #"{"error":{"message":"models missing"}}"#)
                        )
                    )
                )
            }
            router.post("v1/responses") { request, _ async throws -> Response in
                let body = try await Self.string(from: request.body)
                let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
                let model = payload["model"] as? String ?? ""
                await probe.recordResponsesHit(body)
                if unsupportedModels.contains(model) {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: #"{"error":{"message":"model `\#(model)` is not supported."}}"#
                            )
                        )
                    )
                }
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"id":"resp_validation","status":"completed","output":[]}"#))
                )
            }
        case .googleGeminiCompatible:
            router.get("v1beta/openai/models") { _, _ async throws -> Response in
                await probe.recordModelsHit()
                return Response(
                    status: modelsStatus,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: modelsStatus == .ok
                                ? #"{"object":"list","data":[{"id":"gemini-2.5-flash","object":"model","created":0,"owned_by":"google"}]}"#
                                : (modelsBody ?? #"{"error":{"message":"models missing"}}"#)
                        )
                    )
                )
            }
            router.post("v1beta/openai/chat/completions") { request, _ async throws -> Response in
                let body = try await Self.string(from: request.body)
                let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
                let model = payload["model"] as? String ?? ""
                await probe.recordChatHit(body)
                if unsupportedModels.contains(model) {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: #"{"error":{"message":"model `\#(model)` is not supported."}}"#
                            )
                        )
                    )
                }
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"id":"chatcmpl_validation","object":"chat.completion","created":1710000000,"model":"\#(model)","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#
                        )
                    )
                )
            }
        case .aliyunQwenCodingPlan:
            router.post("v1/chat/completions") { request, _ async throws -> Response in
                let body = try await Self.string(from: request.body)
                let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
                let model = payload["model"] as? String ?? ""
                await probe.recordChatHit(body)
                if unsupportedModels.contains(model) {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: #"{"error":{"message":"model `\#(model)` is not supported."}}"#
                            )
                        )
                    )
                }
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"id":"chatcmpl_validation","object":"chat.completion","created":1710000000,"model":"\#(model)","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#
                        )
                    )
                )
            }
        case .anthropicAPICompatible:
            break
        }

        return Application(router: router)
    }

    private static func makeOpenAICompatibleResponsesApplication(
        models: [String] = ["gpt-5.4"],
        nonStreamResponseBody: String? = nil,
        streamChunks: [String]? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("v1/models") { _, _ in
            let modelsJSON = models.map {
                #"{"id":"\#($0)","object":"model","created":0,"owned_by":"openai"}"#
            }
            .joined(separator: ",")
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[\#(modelsJSON)]}"#))
            )
        }
        router.post("v1/responses") { request, _ async throws -> Response in
            _ = try await Self.string(from: request.body)
            if let streamChunks {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return Response(
                    status: .ok,
                    headers: headers,
                    body: .init { writer in
                        var writer = writer
                        for chunk in streamChunks {
                            try await writer.write(ByteBuffer(string: chunk))
                        }
                        try await writer.finish(nil)
                    }
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: nonStreamResponseBody ?? #"{"status":"completed","output":[]}"#))
            )
        }
        return Application(router: router)
    }

    private static func makeDaemonControllerFixture(
        dataDirectory: URL,
        secretStore: SecretStore
    ) throws -> DaemonController {
        try DaemonController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false,
            publicBaseURLProvider: { "http://127.0.0.1:8787" },
            adminBaseURLProvider: { "http://127.0.0.1:8788" },
            secretStore: secretStore,
            managedProxyRuntimeOverride: nil
        )
    }

    private static func data(from response: ProxyHTTPResponse) async throws -> Data {
        switch response.body {
        case .bytes(let data):
            return data
        case .stream(let stream):
            var data = Data()
            for try await chunk in stream {
                data.append(chunk)
            }
            return data
        }
    }

    private static func makeChatGPTUsageApplication(
        usagePlanType: String = "free"
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload(planType: usagePlanType)
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        return Application(router: router)
    }

    private static func makeChatGPTUsageLimitApplication(
        resetAt: Int64
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let payload = """
        {"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"free","resets_at":\(resetAt)}}
        """
        let status = HTTPResponse.Status(code: 402, reasonPhrase: "Payment Required")
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: payload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: payload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: payload))
            )
        }
        return Application(router: router)
    }

    private static func mockUsagePayload(planType: String = "free") -> String {
        """
        {
          "plan_type": "\(planType)",
          "rate_limit": {
            "primary_window": {
              "used_percent": 15,
              "limit_window_seconds": 18000,
              "reset_at": 1776000000
            },
            "secondary_window": {
              "used_percent": 20,
              "limit_window_seconds": 604800,
              "reset_at": 1776674887
            }
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "5"
          }
        }
        """
    }

    private static func jsonHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers.append(.init(name: .contentType, value: "application/json; charset=utf-8"))
        return headers
    }

    private static func makeAnthropicOAuthMetadataApplication(
        authorizeURL: String,
        tokenURL: String,
        clientID: String,
        requestedScope: String,
        betaHeader: String = AnthropicAuthService.defaultOAuthBetaHeader,
        apiBaseURL: String = AnthropicAuthService.defaultAPIBaseURL
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("oauth/claude-code-client-metadata") { _, _ in
            let body = """
            {
              "authorization_endpoint": "\(authorizeURL)",
              "token_endpoint": "\(tokenURL)",
              "client_id": "\(clientID)",
              "scope": "\(requestedScope)",
              "oauth_beta_header": "\(betaHeader)",
              "api_base_url": "\(apiBaseURL)"
            }
            """
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
        return Application(router: router)
    }

    private static func makeAnthropicOAuthTokenApplication(
        scopeProbe: AnthropicOAuthScopeProbe? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.post("v1/oauth/token") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            let grantType = payload["grant_type"] as? String ?? ""
            if grantType == "refresh_token" {
                await scopeProbe?.record(payload["scope"] as? String)
            }
            let suffix: String
            switch grantType {
            case "authorization_code":
                suffix = payload["code"] as? String ?? "unknown"
            case "refresh_token":
                suffix = payload["refresh_token"] as? String ?? "unknown"
            default:
                suffix = "unknown"
            }
            let scope = payload["scope"] as? String ?? "user:profile user:inference"
            let response = """
            {
              "access_token": "anthropic-access-\(suffix)",
              "refresh_token": "anthropic-refresh-\(suffix)",
              "token_type": "Bearer",
              "scope": "\(scope)",
              "sub": "anthropic-principal",
              "account_id": "anthropic-account",
              "email": "claude@example.com",
              "name": "Claude OAuth"
            }
            """
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: response))
            )
        }
        return Application(router: router)
    }

    private static func withEnvironment<T>(
        _ values: [String: String?],
        operation: () async throws -> T
    ) async throws -> T {
        let previous = values.reduce(into: [String: String?]()) { partialResult, entry in
            partialResult[entry.key] = ProcessInfo.processInfo.environment[entry.key]
            if let value = entry.value {
                setenv(entry.key, value, 1)
            } else {
                unsetenv(entry.key)
            }
        }
        defer {
            for (key, value) in previous {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        return try await operation()
    }

    private static func setGeminiOAuthTestCredentials() {
        setenv(GeminiAuthService.oauthClientIDEnvironmentVariable, testGeminiOAuthClientID, 1)
        setenv(GeminiAuthService.oauthClientSecretEnvironmentVariable, testGeminiOAuthClientSecret, 1)
    }

    private static func makeManualAPIKeyRecordFixture(
        baseURL: String,
        apiKey: String,
        label: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil
    ) throws -> AccountRecord {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: providerPreset,
            baseURLMode: providerPreset == .genericOpenAICompatible
                ? (baseURLMode ?? .exactAPIPrefix)
                : baseURLMode
        )
        let extracted = try AuthService.extractAuth(from: normalized)
        return AccountRecord(
            label: label,
            principalID: extracted.principalID,
            email: nil,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            providerPreset: extracted.providerPreset,
            upstreamBaseURL: extracted.upstreamBaseURL,
            authJSON: normalized
        )
    }

    private static func makeLegacyGenericGeminiManualAPIKeyRecordFixture(
        baseURL: String,
        apiKey: String,
        label: String
    ) throws -> AccountRecord {
        let normalizedBaseURL = try OpenAICompatibleUpstream.normalizeBaseURL(
            baseURL,
            providerPreset: .genericOpenAICompatible
        )
        let accountID = OpenAICompatibleUpstream.syntheticAccountID(apiKey: apiKey, baseURL: normalizedBaseURL)
        let authJSON = """
        {
          "auth_mode": "openai_api_key",
          "provider_preset": "generic_openai_compatible",
          "upstream_base_url": "\(normalizedBaseURL)",
          "tokens": {
            "access_token": "\(apiKey)",
            "provider_preset": "generic_openai_compatible",
            "account_id": "\(accountID)"
          }
        }
        """
        let extracted = try AuthService.extractAuth(from: authJSON)
        return AccountRecord(
            label: label,
            principalID: extracted.principalID,
            email: nil,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            providerPreset: .genericOpenAICompatible,
            upstreamBaseURL: normalizedBaseURL,
            authJSON: authJSON
        )
    }

    private static func makeGeminiOAuthAccountRecordFixture(
        secretRef: String,
        baseURL: String,
        label: String,
        projectID: String,
        clientID: String = GeminiAuthService.defaultOAuthClientID
    ) throws -> AccountRecord {
        let authJSON = Self.geminiOAuthAuthJSON(
            secretRef: secretRef,
            baseURL: baseURL,
            projectID: projectID,
            clientID: clientID
        )
        return AccountRecord(
            label: label,
            principalID: "gemini-principal",
            email: "gemini@example.com",
            accountID: "gemini-account",
            planType: "google_ai_pro",
            authMode: .geminiOAuth,
            upstreamBaseURL: baseURL,
            authJSON: authJSON
        )
    }

    private func makeManualAPIKeyRecord(
        baseURL: String,
        apiKey: String,
        label: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil
    ) throws -> AccountRecord {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: providerPreset,
            baseURLMode: providerPreset == .genericOpenAICompatible
                ? (baseURLMode ?? .exactAPIPrefix)
                : baseURLMode
        )
        let extracted = try AuthService.extractAuth(from: normalized)
        return AccountRecord(
            label: label,
            principalID: extracted.principalID,
            email: nil,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            providerPreset: extracted.providerPreset,
            upstreamBaseURL: extracted.upstreamBaseURL,
            authJSON: normalized
        )
    }

    private func makeChatGPTAccountRecord(label: String) throws -> AccountRecord {
        let raw = """
        {
          "access_token": "access-\(UUID().uuidString)",
          "refresh_token": "refresh-\(UUID().uuidString)",
          "id_token": "header.\(Self.base64URL(["sub": "principal-\(UUID().uuidString)", "https://api.openai.com/auth": ["chatgpt_account_id": "account-\(UUID().uuidString)"]])).sig"
        }
        """
        let normalized = try AuthService.normalizeImportedAuthJSON(raw)
        let extracted = try AuthService.extractAuth(from: normalized)
        return AccountRecord(
            label: label,
            principalID: extracted.principalID,
            email: extracted.email,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            upstreamBaseURL: extracted.upstreamBaseURL,
            authJSON: normalized
        )
    }

    private func makeAnthropicOAuthAccountRecord(label: String, principalID: String, accountID: String) -> AccountRecord {
        let authJSON = """
        {
          "auth_mode": "anthropic_subscription_oauth",
          "provider_family": "anthropic",
          "account_id": "\(accountID)",
          "principal_id": "\(principalID)",
          "upstream_base_url": "https://api.anthropic.com"
        }
        """
        return AccountRecord(
            label: label,
            principalID: principalID,
            email: "\(principalID)@example.com",
            accountID: accountID,
            planType: "pro",
            authMode: .anthropicSubscriptionOAuth,
            upstreamBaseURL: "https://api.anthropic.com",
            authJSON: authJSON
        )
    }

    private static func makeGeminiOAuthProviderApplication(
        validationStatus: HTTPResponse.Status = .ok,
        validationBody: String? = nil,
        loadCodeAssistResponses: [String]? = nil,
        onboardResponse: String? = nil,
        operationResponses: [String] = [],
        probe: GeminiOAuthProviderProbe? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let resolvedValidationBody = validationBody ?? Self.mockGeminiLoadCodeAssistPayload()
        let sequence = GeminiOAuthResponseSequence(
            loadResponses: loadCodeAssistResponses ?? [resolvedValidationBody],
            operationResponses: operationResponses
        )

        router.post("v1internal:loadCodeAssist") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe?.recordLoadCodeAssist(body)
            return Response(
                status: validationStatus,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: await sequence.nextLoadResponse()))
            )
        }

        router.post("v1internal:onboardUser") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe?.recordOnboardUser(body)
            guard let onboardResponse else {
                return Response(
                    status: .notFound,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"missing_onboard_stub"}"#))
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: onboardResponse))
            )
        }

        router.get("v1internal/operations/**") { _, _ async throws -> Response in
            await probe?.recordOperationPollHit()
            guard operationResponses.isEmpty == false else {
                return Response(
                    status: .notFound,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"missing_operation_stub"}"#))
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: await sequence.nextOperationResponse()))
            )
        }

        router.post("token") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let contentType = request.headers[.contentType] ?? ""
            guard contentType == "application/x-www-form-urlencoded" else {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_content_type"}"#))
                )
            }
            let grantType = Self.formValue("grant_type", from: body) ?? ""
            switch grantType {
            case "authorization_code":
                let code = Self.formValue("code", from: body) ?? ""
                let redirectURI = Self.formValue("redirect_uri", from: body) ?? ""
                let clientID = Self.formValue("client_id", from: body) ?? ""
                let clientSecret = Self.formValue("client_secret", from: body) ?? ""
                let codeVerifier = Self.formValue("code_verifier", from: body) ?? ""
                guard !code.isEmpty,
                      redirectURI.hasPrefix("http://localhost:"),
                      redirectURI.hasSuffix(AuthService.geminiOAuthCallbackPath),
                      clientID == GeminiAuthService.defaultOAuthClientID,
                      clientSecret == GeminiAuthService.defaultOAuthClientSecret,
                      !codeVerifier.isEmpty
                else {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_request"}"#))
                    )
                }
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: """
                            {
                              "access_token": "gemini-access-\(code)",
                              "refresh_token": "gemini-refresh-\(code)",
                              "expires_in": 3600,
                              "token_type": "Bearer",
                              "scope": "\(GeminiAuthService.defaultOAuthScopes)"
                            }
                            """
                        )
                    )
                )
            case "refresh_token":
                let refreshToken = Self.formValue("refresh_token", from: body) ?? "missing-refresh"
                let clientID = Self.formValue("client_id", from: body) ?? ""
                let clientSecret = Self.formValue("client_secret", from: body) ?? ""
                guard clientID == GeminiAuthService.defaultOAuthClientID,
                      clientSecret == GeminiAuthService.defaultOAuthClientSecret
                else {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_client"}"#))
                    )
                }
                let response = """
                {
                  "access_token": "gemini-access-refresh-\(refreshToken)",
                  "refresh_token": "gemini-refresh-rotated-\(refreshToken)",
                  "expires_in": 3600,
                  "token_type": "Bearer",
                  "scope": "\(GeminiAuthService.defaultOAuthScopes)"
                }
                """
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: response))
                )
            default:
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"unsupported_grant_type"}"#))
                )
            }
        }

        router.get("userinfo") { request, _ async throws -> Response in
            let authorization = request.headers[.authorization] ?? ""
            guard authorization.hasPrefix("Bearer gemini-access-") else {
                return Response(
                    status: .unauthorized,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"unauthorized"}"#))
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: #"{"id":"gemini-principal","email":"gemini@example.com","name":"Gemini Example"}"#
                    )
                )
            )
        }

        return Application(router: router)
    }

    private static func makeManagedProxyRuntime(
        dataDirectory: URL,
        sequence: ManagedProxyRuntimeRequestSequence,
        nodeHealthcheckProbeHandler: @escaping @Sendable (String, String, OutboundProxySettings, Int) async throws -> ManagedProxyRuntime.NodeHealthcheckProbeResponse = { _, _, _, _ in
            ManagedProxyRuntime.NodeHealthcheckProbeResponse(statusCode: 204, latencyMS: 1)
        },
        healthcheckTimestampProvider: @escaping @Sendable () -> Int64 = Helpers.now,
        batchHealthcheckConcurrencyLimit: Int = 1
    ) throws -> ManagedProxyRuntime {
        let secretStore = try self.makeManagedProxyRuntimeSecretStore(dataDirectory: dataDirectory)
        try self.writeManagedProxyRuntimeState(dataDirectory: dataDirectory, controllerPort: 9_090)
        return ManagedProxyRuntime(
            dataDirectory: dataDirectory,
            secretStore: secretStore,
            session: self.makeManagedProxyRuntimeSession(sequence: sequence),
            nodeHealthcheckProbeHandler: nodeHealthcheckProbeHandler,
            healthcheckTimestampProvider: healthcheckTimestampProvider,
            batchHealthcheckConcurrencyLimit: batchHealthcheckConcurrencyLimit
        )
    }

    private static func makeManagedProxyRuntimeSession(
        sequence: ManagedProxyRuntimeRequestSequence
    ) -> URLSession {
        ManagedProxyRuntimeMockURLProtocol.setHandler { request in
            try sequence.handle(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagedProxyRuntimeMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeManagedProxyRuntimeSecretStore(dataDirectory: URL) throws -> SecretStore {
        try Helpers.writeFile(
            Paths.mihomoControllerSecretURL(in: dataDirectory),
            data: Data("controller-secret".utf8)
        )
        #if os(macOS)
        return SecretStore(
            dataDirectory: dataDirectory,
            keychainAdapter: TestKeychainAdapter(),
            keychainEnabledOverride: false
        )
        #else
        return SecretStore(dataDirectory: dataDirectory)
        #endif
    }

    private static func writeManagedProxyRuntimeState(
        dataDirectory: URL,
        controllerPort: Int
    ) throws {
        let payload = """
        {
          "mixedPort": 8890,
          "controllerPort": \(controllerPort),
          "startedAt": 1710000000
        }
        """
        try Helpers.writeFile(
            Paths.mihomoRuntimeStateURL(in: dataDirectory),
            data: Data(payload.utf8)
        )
    }

    private static func managedProxyRuntimeSingleNodeSequence(
        initialProviderResponse: String,
        healthcheckResponse: String,
        refreshedProviderResponse: String,
        nodeName: String,
        currentNodeName: String
    ) -> ManagedProxyRuntimeRequestSequence {
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = self.managedProxyRuntimeGroupResponse(currentNodeName: currentNodeName)

        return ManagedProxyRuntimeRequestSequence(steps: [
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: initialProviderResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: initialProviderResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(
                method: "GET",
                path: "\(providerPath)/\(nodeName)/healthcheck",
                query: self.managedProxyRuntimeHealthcheckQuery(),
                responseBody: healthcheckResponse
            ),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: refreshedProviderResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
        ])
    }

    private static func managedProxyRuntimeHealthcheckSequence(
        initialProviderResponse: String,
        refreshedProviderResponse: String,
        currentNodeName: String,
        configReloadCount: Int = 2
    ) -> ManagedProxyRuntimeRequestSequence {
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = self.managedProxyRuntimeGroupResponse(currentNodeName: currentNodeName)

        var steps: [ManagedProxyRuntimeRequestSequence.Step] = [
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: initialProviderResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: initialProviderResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
        ]

        _ = configReloadCount

        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))
        steps.append(.init(method: "GET", path: providerPath, responseBody: refreshedProviderResponse))
        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))

        return ManagedProxyRuntimeRequestSequence(steps: steps)
    }

    private static func managedProxyRuntimeNodeHealthcheckStep(
        nodeName: String,
        responseBody: String,
        statusCode: Int = 200,
        healthcheckURL: String = ManagedProxyRuntime.defaultHealthcheckURL
    ) -> ManagedProxyRuntimeRequestSequence.Step {
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        return .init(
            method: "GET",
            path: "\(providerPath)/\(nodeName)/healthcheck",
            query: self.managedProxyRuntimeHealthcheckQuery(healthcheckURL: healthcheckURL),
            statusCode: statusCode,
            responseBody: responseBody
        )
    }

    private static func managedProxyRuntimeDelayStep(
        nodeName: String,
        responseBody: String,
        statusCode: Int = 200,
        healthcheckURL: String = ManagedProxyRuntime.defaultHealthcheckURL
    ) -> ManagedProxyRuntimeRequestSequence.Step {
        .init(
            method: "GET",
            path: "/proxies/\(nodeName)/delay",
            percentEncodedPath: "/proxies/\(self.encodedPathComponent(nodeName))/delay",
            query: self.managedProxyRuntimeHealthcheckQuery(healthcheckURL: healthcheckURL),
            statusCode: statusCode,
            responseBody: responseBody
        )
    }

    private static func managedProxyRuntimeBatchDirectSequence(
        initialProviderResponse: String,
        nodeHealthcheckSteps: [ManagedProxyRuntimeRequestSequence.Step],
        refreshedProviderResponse: String,
        currentNodeName: String,
        healthcheckURL: String = ManagedProxyRuntime.defaultHealthcheckURL
    ) -> ManagedProxyRuntimeRequestSequence {
        let providerPath = "/providers/proxies/\(ManagedProxyRuntime.providerName)"
        let groupPath = "/proxies/\(ManagedProxyRuntime.selectGroupName)"
        let groupResponse = self.managedProxyRuntimeGroupResponse(currentNodeName: currentNodeName)

        var steps: [ManagedProxyRuntimeRequestSequence.Step] = [
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: initialProviderResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
            .init(method: "GET", path: providerPath, responseBody: initialProviderResponse),
            .init(method: "GET", path: groupPath, responseBody: groupResponse),
        ]
        steps.append(contentsOf: nodeHealthcheckSteps)
        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))
        steps.append(.init(method: "GET", path: providerPath, responseBody: refreshedProviderResponse))
        steps.append(.init(method: "GET", path: groupPath, responseBody: groupResponse))

        return ManagedProxyRuntimeRequestSequence(steps: steps)
    }

    private static func managedProxyRuntimeProviderResponse(
        proxies: [[String: Any]],
        updatedAt: Int64 = 1_710_000_000
    ) throws -> String {
        let object: [String: Any] = [
            "name": ManagedProxyRuntime.providerName,
            "updatedAt": updatedAt,
            "proxies": proxies,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func managedProxyRuntimeGroupResponse(currentNodeName: String) -> String {
        #"{"now":"\#(currentNodeName)"}"#
    }

    private static func managedProxyRuntimeHealthcheckQuery() -> [String: String] {
        self.managedProxyRuntimeHealthcheckQuery(healthcheckURL: ManagedProxyRuntime.defaultHealthcheckURL)
    }

    private static func managedProxyRuntimeHealthcheckQuery(
        healthcheckURL: String
    ) -> [String: String] {
        [
            "url": healthcheckURL,
            "timeout": "\(ManagedProxyRuntime.defaultHealthcheckTimeoutMS)",
        ]
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func geminiOAuthAuthJSON(
        secretRef: String,
        baseURL: String,
        principalID: String = "gemini-principal",
        accountID: String = "gemini-account",
        email: String = "gemini@example.com",
        projectID: String,
        clientID: String = GeminiAuthService.defaultOAuthClientID,
        scopes: String = GeminiAuthService.defaultOAuthScopes,
        tokenURL: String? = nil,
        authorizeURL: String = GeminiAuthService.defaultAuthorizeURL
    ) -> String {
        let resolvedTokenURL = tokenURL ?? "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/token"
        return """
        {
          "auth_mode": "gemini_api_oauth",
          "provider_family": "gemini",
          "gemini_auth_backend": "\(GeminiAuthService.googleAIProBackend)",
          "secret_ref": "\(secretRef)",
          "principal_id": "\(principalID)",
          "account_id": "\(accountID)",
          "email": "\(email)",
          "plan_type": "google_ai_pro",
          "oauth_client_id": "\(clientID)",
          "oauth_scopes": "\(scopes)",
          "oauth_authorize_url": "\(authorizeURL)",
          "oauth_token_url": "\(resolvedTokenURL)",
          "upstream_base_url": "\(baseURL)",
          "gemini_code_assist_project": "\(projectID)",
          "gemini_current_tier_id": "google_ai_pro",
          "gemini_current_tier_name": "Google AI Pro",
          "gemini_paid_tier_id": "google_ai_pro",
          "gemini_paid_tier_name": "Google AI Pro",
          "gemini_google_one_ai_credit_balance": "99"
        }
        """
    }

    private static func mockGeminiLoadCodeAssistPayload(projectID: String = "gemini-project") -> String {
        """
        {
          "currentTier": {
            "id": "google_ai_pro",
            "name": "Google AI Pro",
            "userDefinedCloudaicompanionProject": false
          },
          "paidTier": {
            "id": "google_ai_pro",
            "name": "Google AI Pro",
            "availableCredits": [
              {
                "creditType": "GOOGLE_ONE_AI",
                "creditAmount": "99"
              }
            ]
          },
          "cloudaicompanionProject": "\(projectID)"
        }
        """
    }

    private static func formValue(_ name: String, from body: String) -> String? {
        body
            .split(separator: "&")
            .compactMap { component -> String? in
                let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == name else { return nil }
                return parts[1].removingPercentEncoding ?? parts[1]
            }
            .first
    }
}

private final class ManagedProxyRuntimeMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping Handler) {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        self.state.handler = handler
    }

    static func resetHandler() {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        self.state.handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.lock.lock()
        let handler = Self.state.handler
        Self.state.lock.unlock()

        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if data.isEmpty == false {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ManagedProxyRuntimeRequestSequence: @unchecked Sendable {
    struct Step {
        let method: String
        let path: String
        let percentEncodedPath: String?
        let query: [String: String]
        let statusCode: Int
        let responseBody: String

        init(
            method: String,
            path: String,
            percentEncodedPath: String? = nil,
            query: [String: String] = [:],
            statusCode: Int = 200,
            responseBody: String
        ) {
            self.method = method
            self.path = path
            self.percentEncodedPath = percentEncodedPath
            self.query = query
            self.statusCode = statusCode
            self.responseBody = responseBody
        }
    }

    private let lock = NSLock()
    private var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let step: Step
        self.lock.lock()
        guard self.steps.isEmpty == false else {
            self.lock.unlock()
            throw ManagedProxyRuntimeRequestSequenceError("Received unexpected request: \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>")")
        }
        step = self.steps.removeFirst()
        self.lock.unlock()

        guard request.httpMethod == step.method else {
            throw ManagedProxyRuntimeRequestSequenceError(
                "Expected method \(step.method), got \(request.httpMethod ?? "<nil>") for \(request.url?.absoluteString ?? "<nil>")"
            )
        }
        guard let url = request.url else {
            throw ManagedProxyRuntimeRequestSequenceError("Expected request URL")
        }
        if let percentEncodedPath = step.percentEncodedPath {
            let actualPercentEncodedPath = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath ?? url.path
            guard actualPercentEncodedPath == percentEncodedPath else {
                throw ManagedProxyRuntimeRequestSequenceError(
                    "Expected encoded path \(percentEncodedPath), got \(actualPercentEncodedPath)"
                )
            }
        } else if url.path != step.path {
            throw ManagedProxyRuntimeRequestSequenceError("Expected path \(step.path), got \(url.path)")
        }

        let actualQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { partialResult, item in
                partialResult[item.name] = item.value ?? ""
            } ?? [:]
        guard actualQuery == step.query else {
            throw ManagedProxyRuntimeRequestSequenceError(
                "Expected query \(step.query), got \(actualQuery) for \(url.absoluteString)"
            )
        }

        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: step.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, Data(step.responseBody.utf8))
    }

    func assertDrained(file: StaticString = #filePath, line: UInt = #line) {
        self.lock.lock()
        defer { self.lock.unlock() }
        XCTAssertTrue(self.steps.isEmpty, "Expected request sequence to be fully consumed, remaining: \(self.steps.count)", file: file, line: line)
    }
}

private struct ManagedProxyRuntimeRequestSequenceError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { self.message }
}

private final class LockedInt64Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(initialValue: Int64) {
        self.value = initialValue
    }

    func next() -> Int64 {
        self.lock.lock()
        defer {
            self.value += 1
            self.lock.unlock()
        }
        return self.value
    }
}

#if os(macOS)
private final class TestKeychainAdapter: SecretStoreKeychainAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]
    private let readStatusByAccount: [String: OSStatus]
    private let addStatusByAccount: [String: OSStatus]
    private let updateStatusByAccount: [String: OSStatus]
    private let deleteStatusByAccount: [String: OSStatus]
    private var reads: [String] = []

    init(
        storage: [String: Data] = [:],
        readStatusByAccount: [String: OSStatus] = [:],
        addStatusByAccount: [String: OSStatus] = [:],
        updateStatusByAccount: [String: OSStatus] = [:],
        deleteStatusByAccount: [String: OSStatus] = [:]
    ) {
        self.storage = storage
        self.readStatusByAccount = readStatusByAccount
        self.addStatusByAccount = addStatusByAccount
        self.updateStatusByAccount = updateStatusByAccount
        self.deleteStatusByAccount = deleteStatusByAccount
    }

    func read(service: String, account: String) throws -> Data? {
        _ = service
        self.lock.lock()
        defer { self.lock.unlock() }

        self.reads.append(account)
        let status = self.readStatusByAccount[account]
            ?? (self.storage[account] == nil ? errSecItemNotFound : errSecSuccess)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .read, status: status, account: account)
        }
        return self.storage[account]
    }

    func write(service: String, account: String, data: Data) throws {
        _ = service
        self.lock.lock()
        defer { self.lock.unlock() }

        let itemExists = self.storage[account] != nil
        let updateStatus = self.updateStatusByAccount[account]
            ?? (itemExists ? errSecSuccess : errSecItemNotFound)
        if updateStatus == errSecSuccess {
            self.storage[account] = data
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainOperationError(operation: .update, status: updateStatus, account: account)
        }

        let addStatus = self.addStatusByAccount[account] ?? errSecSuccess
        guard addStatus == errSecSuccess else {
            throw KeychainOperationError(operation: .add, status: addStatus, account: account)
        }
        self.storage[account] = data
    }

    func delete(service: String, account: String) throws {
        _ = service
        self.lock.lock()
        defer { self.lock.unlock() }

        let status = self.deleteStatusByAccount[account]
            ?? (self.storage[account] == nil ? errSecItemNotFound : errSecSuccess)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainOperationError(operation: .delete, status: status, account: account)
        }
        self.storage[account] = nil
    }

    func readAttempts() -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.reads
    }
}
#endif

private actor AnthropicOAuthScopeProbe {
    private var scope: String?

    func record(_ scope: String?) {
        self.scope = scope
    }

    func snapshot() -> String? {
        self.scope
    }
}

private actor GeminiOAuthProviderProbe {
    private var loadCodeAssistHits = 0
    private var onboardUserHits = 0
    private var operationPollHits = 0

    func recordLoadCodeAssist(_ body: String) {
        _ = body
        self.loadCodeAssistHits += 1
    }

    func recordOnboardUser(_ body: String) {
        _ = body
        self.onboardUserHits += 1
    }

    func recordOperationPollHit() {
        self.operationPollHits += 1
    }

    func snapshot() -> (loadCodeAssistHits: Int, onboardUserHits: Int, operationPollHits: Int) {
        (self.loadCodeAssistHits, self.onboardUserHits, self.operationPollHits)
    }
}

private actor GeminiOAuthResponseSequence {
    private let loadResponses: [String]
    private let operationResponses: [String]
    private var loadIndex = 0
    private var operationIndex = 0

    init(loadResponses: [String], operationResponses: [String]) {
        self.loadResponses = loadResponses
        self.operationResponses = operationResponses
    }

    func nextLoadResponse() -> String {
        let index = min(self.loadIndex, max(self.loadResponses.count - 1, 0))
        self.loadIndex += 1
        return self.loadResponses[index]
    }

    func nextOperationResponse() -> String {
        let index = min(self.operationIndex, max(self.operationResponses.count - 1, 0))
        self.operationIndex += 1
        return self.operationResponses[index]
    }
}

private actor ManualValidationProbe {
    private var modelsHits = 0
    private var responsesBodies: [String] = []
    private var chatBodies: [String] = []

    func recordModelsHit() {
        self.modelsHits += 1
    }

    func recordResponsesHit(_ body: String) {
        self.responsesBodies.append(body)
    }

    func recordChatHit(_ body: String) {
        self.chatBodies.append(body)
    }

    func snapshot() -> (modelsHits: Int, responsesBodies: [String], chatBodies: [String]) {
        (self.modelsHits, self.responsesBodies, self.chatBodies)
    }
}

private actor ConcurrentRequestProbe {
    private var activeHits = 0
    private var maxActiveHits = 0
    private var totalHits = 0

    func begin() {
        self.activeHits += 1
        self.totalHits += 1
        self.maxActiveHits = max(self.maxActiveHits, self.activeHits)
    }

    func end() {
        self.activeHits -= 1
    }

    func snapshot() -> (totalHits: Int, maxActiveHits: Int) {
        (self.totalHits, self.maxActiveHits)
    }
}

private final class LocalHTTPProbeServer: @unchecked Sendable {
    enum Response: Sendable {
        case http(statusCode: Int, body: String = "")
        case stall(milliseconds: UInt32)
    }

    let port: Int

    private let socketFD: Int32
    private let response: Response
    private var stopped = false

    init(response: Response) throws {
        self.response = response
        let socketFD = POSIXCompat.makeTCPIPv4StreamSocket()
        guard socketFD >= 0 else {
            throw ProxyError.message("Failed to create local HTTP probe socket")
        }
        self.socketFD = socketFD
        _ = POSIXCompat.setReuseAddress(socketFD)
        guard POSIXCompat.bindLoopback(socketFD, port: 0) else {
            POSIXCompat.closeDescriptor(socketFD)
            throw ProxyError.message("Failed to bind local HTTP probe socket")
        }
        guard POSIXCompat.listen(socketFD, backlog: 1) else {
            POSIXCompat.closeDescriptor(socketFD)
            throw ProxyError.message("Failed to listen on local HTTP probe socket")
        }
        self.port = try XCTUnwrap(POSIXCompat.localPort(for: socketFD))
        self.startWorker()
    }

    deinit {
        self.stop()
    }

    func stop() {
        guard self.stopped == false else { return }
        self.stopped = true
        POSIXCompat.shutdownReadWrite(self.socketFD)
        POSIXCompat.closeDescriptor(self.socketFD)
    }

    private func startWorker() {
        let socketFD = self.socketFD
        let response = self.response
        Thread.detachNewThread {
            let clientFD = POSIXCompat.accept(socketFD)
            guard clientFD >= 0 else { return }
            defer {
                POSIXCompat.shutdownReadWrite(clientFD)
                POSIXCompat.closeDescriptor(clientFD)
            }
            POSIXCompat.configureClientSocket(clientFD)
            switch response {
            case .http(let statusCode, let body):
                let responseText = """
                HTTP/1.1 \(statusCode) Probe
                Content-Length: \(body.utf8.count)
                Connection: close

                \(body)
                """
                _ = POSIXCompat.sendAll(clientFD, data: Data(responseText.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            case .stall(let milliseconds):
                usleep(milliseconds * 1_000)
            }
        }
    }
}
