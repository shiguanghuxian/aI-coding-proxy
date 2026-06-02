import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

public struct PendingOAuthLogin: Sendable, Equatable {
    public var providerFamily: AccountProviderFamily
    public var redirectURI: String
    public var state: String
    public var codeVerifier: String
    public var expiresAt: Int64
    public var anthropicOAuthConfigSnapshot: AnthropicAuthService.OAuthConfigSnapshot?

    public init(
        providerFamily: AccountProviderFamily = .openAI,
        redirectURI: String,
        state: String,
        codeVerifier: String,
        expiresAt: Int64,
        anthropicOAuthConfigSnapshot: AnthropicAuthService.OAuthConfigSnapshot? = nil
    ) {
        self.providerFamily = providerFamily
        self.redirectURI = redirectURI
        self.state = state
        self.codeVerifier = codeVerifier
        self.expiresAt = expiresAt
        self.anthropicOAuthConfigSnapshot = anthropicOAuthConfigSnapshot
    }
}

public enum AuthService {
    public static let defaultIssuer = "https://auth.openai.com"
    public static let defaultOAuthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let defaultOAuthScope = "openid profile email offline_access"
    public static let defaultOAuthOriginator = "codex_vscode"
    public static let defaultOAuthRedirectPort = 1455
    public static let openAIOAuthCallbackPath = "/auth/callback"
    // Anthropic's official public OAuth client is currently registered for /callback only.
    public static let anthropicOAuthCallbackPath = "/callback"
    public static let geminiOAuthCallbackPath = "/gemini/callback"
    public static let defaultOAuthTimeoutSeconds: Int64 = 300

    public static func currentCodexAuthPath() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
    }

    public static func readCurrentCodexAuth() throws -> String {
        try String(contentsOf: self.currentCodexAuthPath(), encoding: .utf8)
    }

    public static func readCurrentCodexAuthOptional() -> String? {
        try? self.readCurrentCodexAuth()
    }

    public static func writeCurrentCodexAuth(_ text: String) throws {
        try Helpers.writeFile(self.currentCodexAuthPath(), data: Data(text.utf8), posixMode: 0o600)
    }

    public static func normalizeImportedAuthJSON(_ text: String) throws -> String {
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let authMode = self.authMode(from: payload)
        if authMode == .anthropicSubscriptionOAuth || authMode == .geminiOAuth {
            return text
        }
        if authMode.isManualAPIKey || self.containsExplicitManualAPIKey(payload) {
            return try self.normalizeManualAPIKeyAuthPayload(payload)
        }
        if payload["tokens"] != nil {
            return try self.jsonString(payload)
        }
        if let accessToken = payload["access_token"] as? String, !accessToken.isEmpty {
            var tokens: [String: Any] = [
                "access_token": accessToken,
            ]
            if let idToken = payload["id_token"] as? String, !idToken.isEmpty {
                tokens["id_token"] = idToken
            }
            if let refreshToken = payload["refresh_token"] as? String {
                tokens["refresh_token"] = refreshToken
            }
            if let accountID = payload["account_id"] as? String {
                tokens["account_id"] = accountID
            }
            if let email = payload["email"] as? String, !email.isEmpty {
                tokens["email"] = email
            }
            var normalized: [String: Any] = [
                "auth_mode": payload["auth_mode"] as? String ?? AccountAuthMode.chatGPT.rawValue,
                "tokens": tokens,
            ]
            if let lastRefresh = payload["last_refresh"] {
                normalized["last_refresh"] = lastRefresh
            }
            if let expiresAt = self.importedAuthExpiration(from: payload, tokens: tokens) {
                normalized["expires_at"] = expiresAt
            }
            return try self.jsonString(normalized)
        }
        return text
    }

    public static func extractAuth(from text: String, secretStore: SecretStore? = nil) throws -> ExtractedAuth {
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        let tokens = (payload["tokens"] as? [String: Any]) ?? payload
        let authMode = self.authMode(from: payload)
        let providerFamily = self.providerFamily(from: payload, authMode: authMode)
        if authMode.isManualAPIKey {
            let providerPreset = self.extractManualProviderPreset(from: payload, authMode: authMode)
            let baseURLMode = self.resolvedManualAPIKeyBaseURLMode(
                from: payload,
                providerPreset: providerPreset
            )
            let upstreamAdapter = self.resolvedManualAPIKeyUpstreamAdapter(
                from: payload,
                providerPreset: providerPreset
            )
            let chatCompatibilityProfile = self.extractChatCompletionsCompatibilityProfile(from: payload)
            let apiKey = (tokens["access_token"] as? String) ?? self.extractManualAPIKey(from: payload, providerPreset: providerPreset)
            guard let apiKey, !apiKey.isEmpty else {
                throw ProxyError.message("auth.json 缺少 API Key")
            }
            let upstreamBaseURL = try self.normalizeManualAPIKeyBaseURL(
                self.extractManualAPIKeyBaseURL(from: payload) ?? providerPreset.defaultBaseURL,
                providerPreset: providerPreset
            )
            let resolvedAuthMode = providerPreset.manualAuthMode
            let accountID = (tokens["account_id"] as? String)
                ?? self.syntheticAPIKeyAccountID(apiKey, baseURL: upstreamBaseURL, authMode: resolvedAuthMode)
            return ExtractedAuth(
                providerFamily: providerFamily,
                authMode: resolvedAuthMode,
                providerPreset: providerPreset,
                baseURLMode: baseURLMode,
                upstreamAdapter: upstreamAdapter,
                chatCompatibilityProfile: chatCompatibilityProfile,
                principalID: accountID,
                accountID: accountID,
                accessToken: apiKey,
                upstreamBaseURL: upstreamBaseURL,
                refreshToken: nil,
                idToken: nil,
                email: nil,
                planType: "api_key"
            )
        }
        if authMode == .anthropicSubscriptionOAuth {
            let bundle = try self.resolveAnthropicTokenBundle(payload: payload, secretStore: secretStore)
            let principalID = self.extractAnthropicValue(from: payload, primaryKey: "principal_id", fallbackKeys: ["principalId", "sub"])
                ?? self.syntheticAnthropicPrincipalID(bundle.accessToken)
            let accountID = self.extractAnthropicValue(from: payload, primaryKey: "account_id", fallbackKeys: ["accountId"])
                ?? principalID
            let upstreamBaseURL = self.extractAnthropicBaseURL(from: payload)
            return ExtractedAuth(
                providerFamily: providerFamily,
                authMode: .anthropicSubscriptionOAuth,
                providerPreset: .genericOpenAICompatible,
                principalID: principalID,
                accountID: accountID,
                accessToken: bundle.accessToken,
                upstreamBaseURL: upstreamBaseURL,
                refreshToken: bundle.refreshToken,
                idToken: nil,
                email: self.extractAnthropicValue(from: payload, primaryKey: "email", fallbackKeys: []),
                planType: self.extractAnthropicValue(from: payload, primaryKey: "plan_type", fallbackKeys: ["planType"])
            )
        }
        if authMode == .geminiOAuth {
            let bundle = try self.resolveGeminiTokenBundle(payload: payload, secretStore: secretStore)
            let seed = bundle.refreshToken ?? bundle.accessToken
            let principalID = self.extractGeminiValue(from: payload, primaryKey: "principal_id", fallbackKeys: ["principalId", "sub"])
                ?? self.syntheticGeminiPrincipalID(seed)
            let accountID = self.extractGeminiValue(from: payload, primaryKey: "account_id", fallbackKeys: ["accountId"])
                ?? principalID
            return ExtractedAuth(
                providerFamily: providerFamily,
                authMode: .geminiOAuth,
                providerPreset: .genericOpenAICompatible,
                principalID: principalID,
                accountID: accountID,
                accessToken: bundle.accessToken,
                upstreamBaseURL: self.extractGeminiBaseURL(from: payload),
                refreshToken: bundle.refreshToken,
                idToken: nil,
                email: self.extractGeminiValue(from: payload, primaryKey: "email", fallbackKeys: []),
                planType: self.extractGeminiValue(from: payload, primaryKey: "plan_type", fallbackKeys: ["planType"])
            )
        }
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            throw ProxyError.message("auth.json 缺少 access_token")
        }
        let refreshToken = tokens["refresh_token"] as? String
        let idToken = tokens["id_token"] as? String
        var accountID = tokens["account_id"] as? String
        var principalID = accountID
        var email = (tokens["email"] as? String) ?? (payload["email"] as? String)
        var planType: String?
        if let idToken, let claims = try? self.decodeJWTPayload(idToken) {
            email = (claims["email"] as? String) ?? email
            if let authClaim = claims["https://api.openai.com/auth"] as? [String: Any] {
                if accountID == nil {
                    accountID = authClaim["chatgpt_account_id"] as? String
                }
                principalID = authClaim["chatgpt_account_id"] as? String ?? principalID
                planType = authClaim["chatgpt_plan_type"] as? String ?? authClaim["plan_type"] as? String
            }
            principalID = (claims["sub"] as? String) ?? principalID
        }
        guard let resolvedAccountID = accountID, !resolvedAccountID.isEmpty else {
            throw ProxyError.message("无法从 auth.json 识别 account_id")
        }
        let resolvedPrincipal = principalID ?? resolvedAccountID
        return ExtractedAuth(
            providerFamily: providerFamily,
            authMode: .chatGPT,
            providerPreset: .genericOpenAICompatible,
            principalID: resolvedPrincipal,
            accountID: resolvedAccountID,
            accessToken: accessToken,
            upstreamBaseURL: nil,
            refreshToken: refreshToken,
            idToken: idToken,
            email: email,
            planType: planType
        )
    }

    public static func extractAuthMetadata(
        from text: String
    ) -> (
        providerFamily: AccountProviderFamily,
        authMode: AccountAuthMode,
        providerPreset: OpenAICompatibleProviderPreset,
        upstreamBaseURL: String?,
        baseURLMode: ManualAPIKeyBaseURLMode?,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter?,
        chatCompatibilityProfile: ChatCompletionsCompatibilityProfile
    ) {
        let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        let authMode = self.authMode(from: payload)
        let providerFamily = self.providerFamily(from: payload, authMode: authMode)
        let providerPreset = authMode.isManualAPIKey
            ? self.extractManualProviderPreset(from: payload, authMode: authMode)
            : .genericOpenAICompatible
        let upstreamBaseURL: String?
        let baseURLMode: ManualAPIKeyBaseURLMode?
        let upstreamAdapter: ManualAPIKeyUpstreamAdapter?
        let chatCompatibilityProfile: ChatCompletionsCompatibilityProfile
        switch authMode {
        case .chatGPT:
            upstreamBaseURL = nil
            baseURLMode = nil
            upstreamAdapter = nil
            chatCompatibilityProfile = .auto
        case .openAIAPIKey, .anthropicAPIKey:
            upstreamBaseURL = self.extractManualAPIKeyBaseURL(from: payload)
            baseURLMode = self.resolvedManualAPIKeyBaseURLMode(from: payload, providerPreset: providerPreset)
            upstreamAdapter = self.resolvedManualAPIKeyUpstreamAdapter(from: payload, providerPreset: providerPreset)
            chatCompatibilityProfile = self.extractChatCompletionsCompatibilityProfile(from: payload)
        case .anthropicSubscriptionOAuth:
            upstreamBaseURL = self.extractAnthropicBaseURL(from: payload)
            baseURLMode = nil
            upstreamAdapter = nil
            chatCompatibilityProfile = .auto
        case .geminiOAuth:
            upstreamBaseURL = self.extractGeminiBaseURL(from: payload)
            baseURLMode = nil
            upstreamAdapter = nil
            chatCompatibilityProfile = .auto
        }
        return (providerFamily, authMode, providerPreset, upstreamBaseURL, baseURLMode, upstreamAdapter, chatCompatibilityProfile)
    }

    public static func geminiAuthBackend(from text: String) -> String? {
        let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        return self.extractGeminiAuthBackend(from: payload)
    }

    public static func authNeedsRefresh(
        _ text: String,
        secretStore: SecretStore? = nil,
        leadTimeSeconds: Int64 = 60
    ) -> Bool {
        guard
            let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
            return true
        }
        let authMode = self.authMode(from: payload)
        if authMode.isManualAPIKey {
            return false
        }
        if authMode == .anthropicSubscriptionOAuth {
            guard let secretRef = self.extractAnthropicSecretRef(from: payload),
                  let bundle = secretStore?.loadAnthropicOAuthSecretIfPresent(ref: secretRef),
                  let expiresAt = bundle.expiresAt
            else {
                return true
            }
            return expiresAt <= Helpers.now() + leadTimeSeconds
        }
        if authMode == .geminiOAuth {
            guard let secretRef = self.extractGeminiSecretRef(from: payload),
                  let bundle = secretStore?.loadGeminiOAuthSecretIfPresent(ref: secretRef),
                  let expiresAt = bundle.expiresAt
            else {
                return true
            }
            return expiresAt <= Helpers.now() + leadTimeSeconds
        }
        guard
            let tokens = (payload["tokens"] as? [String: Any]) ?? payload as [String: Any]?
        else {
            return true
        }
        let now = Helpers.now()
        let expiresAt = self.importedAuthExpiration(from: payload, tokens: tokens)
        if let expiresAt, expiresAt <= now + leadTimeSeconds {
            return true
        }
        for key in ["access_token", "id_token"] {
            guard let token = tokens[key] as? String else {
                if key == "id_token", expiresAt != nil {
                    continue
                }
                return true
            }
            if let exp = self.jwtExpiration(token), exp <= now + leadTimeSeconds {
                return true
            }
        }
        return false
    }

    public static func refreshAuth(_ text: String, config: AppConfig, secretStore: SecretStore) async throws -> String {
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        switch self.authMode(from: payload) {
        case .openAIAPIKey, .anthropicAPIKey:
            return text
        case .chatGPT:
            return try await self.refreshChatGPTAuth(text, config: config)
        case .anthropicSubscriptionOAuth:
            return try await AnthropicAuthService.refreshAnthropicAuth(text, config: config, secretStore: secretStore)
        case .geminiOAuth:
            return try await GeminiAuthService.refreshGeminiAuth(text, config: config, secretStore: secretStore)
        }
    }

    public static func refreshChatGPTAuth(_ text: String, config: AppConfig) async throws -> String {
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        if self.authMode(from: payload) != .chatGPT {
            return text
        }
        guard let tokens = (payload["tokens"] as? [String: Any]) ?? payload as [String: Any]?,
              let refreshToken = tokens["refresh_token"] as? String
        else {
            throw ProxyError.message("auth.json 缺少 refresh_token")
        }
        let idToken = tokens["id_token"] as? String ?? ""
        let issuer: String
        if let claims = try? self.decodeJWTPayload(idToken),
           let authClaim = claims["iss"] as? String {
            issuer = authClaim
        } else {
            issuer = Self.defaultIssuer
        }
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.defaultOAuthClientID,
        ]
        let response = try await HTTPClientFactory.request(
            config: config,
            url: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth/token",
            method: .POST,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: self.formURLEncodedBody(body)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message("刷新 token 失败: \(response.statusCode) \(Helpers.truncate(response.bodyText))")
        }
        let refreshed = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        var updated = payload
        var tokenObject = (updated["tokens"] as? [String: Any]) ?? [:]
        tokenObject["access_token"] = refreshed["access_token"]
        tokenObject["id_token"] = refreshed["id_token"]
        if let newRefresh = refreshed["refresh_token"] {
            tokenObject["refresh_token"] = newRefresh
        }
        updated["tokens"] = tokenObject
        updated["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        return try self.jsonString(updated)
    }

    public static func prepareOAuthLogin(callbackPort: Int) throws -> (PendingOAuthLogin, PreparedOAuthLogin) {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let codeVerifier = [
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        ].joined()
        let challenge = Helpers.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        let redirectURI = self.localOAuthRedirectURI(
            callbackPort: callbackPort,
            path: Self.openAIOAuthCallbackPath
        )
        var components = URLComponents(string: Self.defaultIssuer + "/oauth/authorize")
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.defaultOAuthClientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.defaultOAuthScope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: Self.defaultOAuthOriginator),
        ]
        let pending = PendingOAuthLogin(
            providerFamily: .openAI,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: codeVerifier,
            expiresAt: Helpers.now() + Self.defaultOAuthTimeoutSeconds
        )
        guard let authURL = components?.url?.absoluteString, authURL.isEmpty == false else {
            throw ProxyError.message("生成 OAuth 授权链接失败")
        }
        return (
            pending,
            PreparedOAuthLogin(providerFamily: .openAI, authURL: authURL, redirectURI: redirectURI)
        )
    }

    public static func localOAuthRedirectURI(callbackPort: Int, path: String) -> String {
        "http://localhost:\(callbackPort)\(path)"
    }

    public static func completeOAuthCallback(
        pending: PendingOAuthLogin,
        callbackURL: String,
        config: AppConfig
    ) async throws -> String {
        guard pending.expiresAt >= Helpers.now() else {
            throw ProxyError.message("OAuth 授权已过期，请重新生成授权链接")
        }

        let components = try self.parseOAuthCallbackURL(callbackURL)
        if let errorPayload = try self.oauthErrorPayload(from: components) {
            throw ProxyError.message(self.oauthErrorMessage(from: errorPayload))
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let oauthError = items["error"], oauthError.isEmpty == false {
            let detail = items["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? oauthError
            throw ProxyError.message("授权失败: \(detail)")
        }
        guard let state = items["state"], state.isEmpty == false else {
            throw ProxyError.message("OAuth callback 缺少 state")
        }
        guard state == pending.state else {
            throw ProxyError.message("OAuth state 不匹配")
        }
        guard let code = items["code"], code.isEmpty == false else {
            throw ProxyError.message("OAuth callback 缺少 code")
        }
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.defaultOAuthClientID,
            "code": code,
            "code_verifier": pending.codeVerifier,
            "redirect_uri": pending.redirectURI,
        ]
        let response = try await HTTPClientFactory.request(
            config: config,
            url: Self.defaultIssuer + "/oauth/token",
            method: .POST,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: self.formURLEncodedBody(body)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message("OAuth token 交换失败: \(response.statusCode) \(Helpers.truncate(response.bodyText))")
        }
        let tokenResponse = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        guard let accessToken = tokenResponse["access_token"] as? String,
              let refreshToken = tokenResponse["refresh_token"] as? String,
              let idToken = tokenResponse["id_token"] as? String
        else {
            throw ProxyError.message("OAuth token 返回缺少字段")
        }
        let claims = try self.decodeJWTPayload(idToken)
        let accountID = ((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String) ?? (claims["sub"] as? String) ?? ""
        guard accountID.isEmpty == false else {
            throw ProxyError.message("无法从 OAuth 登录结果识别 chatgpt_account_id")
        }
        let auth: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "auth_mode": AccountAuthMode.chatGPT.rawValue,
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "id_token": idToken,
                "account_id": accountID,
            ],
        ]
        return try self.jsonString(auth)
    }

    public static func accountKey(from auth: ExtractedAuth) -> String {
        "\(auth.principalID)|\(auth.accountID)"
    }

    public static func normalizeManualAPIKeyInput(
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        chatCompatibilityProfile: ChatCompletionsCompatibilityProfile = .auto
    ) throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty == false else {
            throw ProxyError.message("API Key 不能为空")
        }
        var normalized: [String: Any] = [
            "auth_mode": providerPreset.manualAuthMode.rawValue,
            "provider_preset": providerPreset.rawValue,
            "upstream_base_url": try self.normalizeManualAPIKeyBaseURL(baseURL, providerPreset: providerPreset),
            "tokens": [
                "access_token": trimmedKey,
            ],
        ]
        if let baseURLMode {
            normalized["upstream_base_url_mode"] = baseURLMode.rawValue
        }
        if let upstreamAdapter, providerPreset == .genericOpenAICompatible {
            normalized["upstream_adapter"] = upstreamAdapter.rawValue
        }
        if providerPreset == .genericOpenAICompatible {
            normalized["chat_compatibility_profile"] = chatCompatibilityProfile.rawValue
        }
        return try self.normalizeManualAPIKeyAuthPayload(normalized, explicitProviderSelection: true)
    }

    public static func decodeJWTPayload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw ProxyError.message("JWT 格式无效")
        }
        let body = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = body + String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ProxyError.message("JWT payload 无法解析")
        }
        return payload
    }

    public static func jwtExpiration(_ token: String) -> Int64? {
        let payload = try? self.decodeJWTPayload(token)
        if let exp = payload?["exp"] as? Int64 {
            return exp
        }
        if let exp = payload?["exp"] as? Int {
            return Int64(exp)
        }
        if let exp = payload?["exp"] as? Double {
            return Int64(exp)
        }
        return nil
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseOAuthCallbackURL(_ callbackURL: String) throws -> URLComponents {
        let trimmed = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ProxyError.message("请提供完整的回调链接")
        }
        if let absolute = URLComponents(string: trimmed), absolute.scheme?.isEmpty == false {
            return absolute
        }

        let normalized = trimmed.hasPrefix("/") ? "http://localhost\(trimmed)" : "http://localhost/\(trimmed)"
        if let relative = URLComponents(string: normalized), relative.scheme?.isEmpty == false {
            return relative
        }
        throw ProxyError.message("回调链接格式无效")
    }

    public static func decodeOAuthErrorPayload(from callbackURL: String) throws -> OAuthErrorPayload? {
        let components = try self.parseOAuthCallbackURL(callbackURL)
        return try self.oauthErrorPayload(from: components)
    }

    private static func oauthErrorPayload(from components: URLComponents) throws -> OAuthErrorPayload? {
        let host = components.host?.lowercased() ?? ""
        guard host == "auth.openai.com", components.path == "/error" else {
            return nil
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let payload = items["payload"], payload.isEmpty == false else {
            throw ProxyError.message("OpenAI 授权页返回错误，但缺少 payload")
        }

        let normalized = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else {
            throw ProxyError.message("OpenAI 授权页错误 payload 无法解码")
        }
        do {
            return try Helpers.readJSON(OAuthErrorPayload.self, from: data)
        } catch {
            throw ProxyError.message("OpenAI 授权页错误 payload 不是合法 JSON")
        }
    }

    private static func oauthErrorMessage(from payload: OAuthErrorPayload) -> String {
        var message = "OpenAI 授权页返回错误: kind=\(payload.kind), error_code=\(payload.errorCode)"
        if let requestID = payload.requestId, !requestID.isEmpty {
            message += ", request_id=\(requestID)"
        }
        return message
    }

    private static func formURLEncodedBody(_ parameters: [String: String]) -> Data {
        let pairs = parameters.map { key, value in
            "\(self.formComponent(key))=\(self.formComponent(value))"
        }
        .sorted()
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func formComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+")
            ?? value
    }

    private static func authMode(from payload: [String: Any]) -> AccountAuthMode {
        AccountAuthMode(rawValue: (payload["auth_mode"] as? String) ?? "") ?? .chatGPT
    }

    private static func importedAuthExpiration(from payload: [String: Any], tokens: [String: Any]) -> Int64? {
        let candidates: [Any?] = [
            payload["expires_at"],
            payload["expiresAt"],
            payload["expired"],
            payload["expires"],
            tokens["expires_at"],
            tokens["expiresAt"],
            tokens["expired"],
            tokens["expires"],
        ]
        for candidate in candidates {
            if let timestamp = self.int64Value(from: candidate) {
                return timestamp
            }
            if let raw = candidate as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let numeric = Int64(trimmed) {
                    return numeric
                }
                if let date = ISO8601DateFormatter().date(from: trimmed) {
                    return Int64(date.timeIntervalSince1970)
                }
            }
        }
        return nil
    }

    private static func providerFamily(from payload: [String: Any], authMode: AccountAuthMode) -> AccountProviderFamily {
        AccountProviderFamily(rawValue: (payload["provider_family"] as? String) ?? "") ?? authMode.providerFamily
    }

    private static func extractOpenAIAPIKey(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["OPENAI_API_KEY"] as? String,
            payload["openai_api_key"] as? String,
            payload["api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["OPENAI_API_KEY"] as? String,
            (payload["tokens"] as? [String: Any])?["openai_api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["access_token"] as? String,
            (payload["tokens"] as? [String: Any])?["api_key"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractAnthropicAPIKey(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["ANTHROPIC_API_KEY"] as? String,
            payload["anthropic_api_key"] as? String,
            payload["x-api-key"] as? String,
            payload["x_api_key"] as? String,
            payload["api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["ANTHROPIC_API_KEY"] as? String,
            (payload["tokens"] as? [String: Any])?["anthropic_api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["x-api-key"] as? String,
            (payload["tokens"] as? [String: Any])?["x_api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["access_token"] as? String,
            (payload["tokens"] as? [String: Any])?["api_key"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractManualAPIKey(
        from payload: [String: Any],
        providerPreset: OpenAICompatibleProviderPreset
    ) -> String? {
        switch providerPreset {
        case .anthropicAPICompatible:
            return self.extractAnthropicAPIKey(from: payload)
        case .genericOpenAICompatible, .aliyunQwenCodingPlan, .googleGeminiCompatible:
            return self.extractOpenAIAPIKey(from: payload)
        }
    }

    private static func containsExplicitOpenAIAPIKey(_ payload: [String: Any]) -> Bool {
        let candidates = [
            payload["OPENAI_API_KEY"] as? String,
            payload["openai_api_key"] as? String,
            payload["api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["OPENAI_API_KEY"] as? String,
            (payload["tokens"] as? [String: Any])?["openai_api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["api_key"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(where: { !$0.isEmpty })
    }

    private static func containsExplicitAnthropicAPIKey(_ payload: [String: Any]) -> Bool {
        let candidates = [
            payload["ANTHROPIC_API_KEY"] as? String,
            payload["anthropic_api_key"] as? String,
            payload["x-api-key"] as? String,
            payload["x_api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["ANTHROPIC_API_KEY"] as? String,
            (payload["tokens"] as? [String: Any])?["anthropic_api_key"] as? String,
            (payload["tokens"] as? [String: Any])?["x-api-key"] as? String,
            (payload["tokens"] as? [String: Any])?["x_api_key"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(where: { !$0.isEmpty })
    }

    private static func containsExplicitManualAPIKey(_ payload: [String: Any]) -> Bool {
        self.containsExplicitOpenAIAPIKey(payload) || self.containsExplicitAnthropicAPIKey(payload)
    }

    private static func extractManualAPIKeyBaseURL(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["upstream_base_url"] as? String,
            payload["upstreamBaseURL"] as? String,
            payload["base_url"] as? String,
            payload["baseURL"] as? String,
            payload["OPENAI_BASE_URL"] as? String,
            payload["openai_base_url"] as? String,
            (payload["tokens"] as? [String: Any])?["upstream_base_url"] as? String,
            (payload["tokens"] as? [String: Any])?["upstreamBaseURL"] as? String,
            (payload["tokens"] as? [String: Any])?["base_url"] as? String,
            (payload["tokens"] as? [String: Any])?["baseURL"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractManualAPIKeyBaseURLMode(
        from payload: [String: Any]
    ) -> ManualAPIKeyBaseURLMode? {
        let candidates = [
            payload["upstream_base_url_mode"] as? String,
            payload["upstreamBaseURLMode"] as? String,
            payload["base_url_mode"] as? String,
            payload["baseURLMode"] as? String,
            (payload["tokens"] as? [String: Any])?["upstream_base_url_mode"] as? String,
            (payload["tokens"] as? [String: Any])?["upstreamBaseURLMode"] as? String,
            (payload["tokens"] as? [String: Any])?["base_url_mode"] as? String,
            (payload["tokens"] as? [String: Any])?["baseURLMode"] as? String,
        ]
        let raw = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return raw.flatMap(ManualAPIKeyBaseURLMode.init(rawValue:))
    }

    private static func resolvedManualAPIKeyBaseURLMode(
        from payload: [String: Any],
        providerPreset: OpenAICompatibleProviderPreset
    ) -> ManualAPIKeyBaseURLMode? {
        if let explicit = self.extractManualAPIKeyBaseURLMode(from: payload) {
            return explicit
        }
        guard providerPreset == .genericOpenAICompatible else {
            return nil
        }
        return .exactAPIPrefix
    }

    private static func extractManualAPIKeyUpstreamAdapter(
        from payload: [String: Any]
    ) -> ManualAPIKeyUpstreamAdapter? {
        let candidates = [
            payload["upstream_adapter"] as? String,
            payload["upstreamAdapter"] as? String,
            (payload["tokens"] as? [String: Any])?["upstream_adapter"] as? String,
            (payload["tokens"] as? [String: Any])?["upstreamAdapter"] as? String,
        ]
        let raw = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return raw.flatMap(ManualAPIKeyUpstreamAdapter.init(rawValue:))
    }

    private static func extractChatCompletionsCompatibilityProfile(
        from payload: [String: Any]
    ) -> ChatCompletionsCompatibilityProfile {
        let candidates = [
            payload["chat_compatibility_profile"] as? String,
            payload["chatCompatibilityProfile"] as? String,
            (payload["tokens"] as? [String: Any])?["chat_compatibility_profile"] as? String,
            (payload["tokens"] as? [String: Any])?["chatCompatibilityProfile"] as? String,
        ]
        let raw = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let raw,
              let data = try? JSONEncoder().encode(raw),
              let decoded = try? JSONDecoder().decode(ChatCompletionsCompatibilityProfile.self, from: data)
        else {
            return .auto
        }
        return decoded
    }

    private static func resolvedManualAPIKeyUpstreamAdapter(
        from payload: [String: Any],
        providerPreset: OpenAICompatibleProviderPreset
    ) -> ManualAPIKeyUpstreamAdapter? {
        guard providerPreset == .genericOpenAICompatible else {
            return nil
        }
        return self.extractManualAPIKeyUpstreamAdapter(from: payload) ?? .responses
    }

    private static func extractManualProviderPreset(
        from payload: [String: Any],
        authMode: AccountAuthMode
    ) -> OpenAICompatibleProviderPreset {
        let candidates = [
            payload["provider_preset"] as? String,
            payload["providerPreset"] as? String,
            (payload["tokens"] as? [String: Any])?["provider_preset"] as? String,
            (payload["tokens"] as? [String: Any])?["providerPreset"] as? String,
        ]
        let raw = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let preset = raw.flatMap(OpenAICompatibleProviderPreset.init(rawValue:)) {
            return preset
        }
        if raw == "deepseek_official_api" {
            return .genericOpenAICompatible
        }
        if authMode == .anthropicAPIKey || self.containsExplicitAnthropicAPIKey(payload) {
            return .anthropicAPICompatible
        }
        return .genericOpenAICompatible
    }

    private static func extractAnthropicBaseURL(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["upstream_base_url"] as? String,
            payload["upstreamBaseURL"] as? String,
            payload["base_url"] as? String,
            payload["baseURL"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractAnthropicSecretRef(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["secret_ref"] as? String,
            payload["secretRef"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractGeminiBaseURL(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["upstream_base_url"] as? String,
            payload["upstreamBaseURL"] as? String,
            payload["base_url"] as? String,
            payload["baseURL"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractGeminiSecretRef(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["secret_ref"] as? String,
            payload["secretRef"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    static func extractGeminiAuthBackend(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["gemini_auth_backend"] as? String,
            payload["geminiAuthBackend"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractGeminiValue(
        from payload: [String: Any],
        primaryKey: String,
        fallbackKeys: [String]
    ) -> String? {
        ([primaryKey] + fallbackKeys)
            .compactMap { payload[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func extractAnthropicValue(
        from payload: [String: Any],
        primaryKey: String,
        fallbackKeys: [String]
    ) -> String? {
        ([primaryKey] + fallbackKeys)
            .compactMap { payload[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func resolveAnthropicTokenBundle(
        payload: [String: Any],
        secretStore: SecretStore?
    ) throws -> AnthropicOAuthSecretBundle {
        if let accessToken = self.extractAnthropicValue(from: payload, primaryKey: "access_token", fallbackKeys: [] ) {
            return AnthropicOAuthSecretBundle(
                accessToken: accessToken,
                refreshToken: self.extractAnthropicValue(from: payload, primaryKey: "refresh_token", fallbackKeys: []),
                expiresAt: self.int64Value(from: payload["expires_at"]),
                tokenType: self.extractAnthropicValue(from: payload, primaryKey: "token_type", fallbackKeys: ["tokenType"]),
                scope: self.extractAnthropicValue(from: payload, primaryKey: "scope", fallbackKeys: [])
            )
        }
        guard let secretRef = self.extractAnthropicSecretRef(from: payload), !secretRef.isEmpty else {
            throw ProxyError.message("Anthropic 授权信息缺少 secret_ref")
        }
        guard let bundle = secretStore?.loadAnthropicOAuthSecretIfPresent(ref: secretRef) else {
            throw ProxyError.message("Anthropic 授权密钥缺失，请重新登录")
        }
        return bundle
    }

    private static func resolveGeminiTokenBundle(
        payload: [String: Any],
        secretStore: SecretStore?
    ) throws -> GeminiOAuthSecretBundle {
        if let accessToken = self.extractGeminiValue(from: payload, primaryKey: "access_token", fallbackKeys: [] ) {
            return GeminiOAuthSecretBundle(
                accessToken: accessToken,
                refreshToken: self.extractGeminiValue(from: payload, primaryKey: "refresh_token", fallbackKeys: []),
                expiresAt: self.int64Value(from: payload["expires_at"]),
                tokenType: self.extractGeminiValue(from: payload, primaryKey: "token_type", fallbackKeys: ["tokenType"]),
                scope: self.extractGeminiValue(from: payload, primaryKey: "scope", fallbackKeys: [])
            )
        }
        guard let secretRef = self.extractGeminiSecretRef(from: payload), !secretRef.isEmpty else {
            throw ProxyError.message("Gemini 授权信息缺少 secret_ref")
        }
        guard let bundle = secretStore?.loadGeminiOAuthSecretIfPresent(ref: secretRef) else {
            throw ProxyError.message("Gemini 授权密钥缺失，请重新登录")
        }
        return bundle
    }

    private static func normalizeManualAPIKeyAuthPayload(
        _ payload: [String: Any],
        explicitProviderSelection: Bool = false
    ) throws -> String {
        let authMode = self.authMode(from: payload)
        let providerPreset = self.extractManualProviderPreset(from: payload, authMode: authMode)
        let rawBaseURL = self.extractManualAPIKeyBaseURL(from: payload) ?? providerPreset.defaultBaseURL
        let effectiveProviderPreset = OpenAICompatibleUpstream.normalizedManualProviderPreset(
            baseURL: rawBaseURL,
            providerPreset: providerPreset
        )
        if let error = OpenAICompatibleUpstream.manualConfigurationError(
            baseURL: rawBaseURL,
            providerPreset: providerPreset,
            explicitSelection: explicitProviderSelection
        ) {
            throw ProxyError.message(error)
        }
        guard let apiKey = self.extractManualAPIKey(from: payload, providerPreset: effectiveProviderPreset) else {
            throw ProxyError.message("auth.json 缺少 API Key")
        }
        let resolvedAuthMode = effectiveProviderPreset.manualAuthMode
        let baseURLMode = self.resolvedManualAPIKeyBaseURLMode(
            from: payload,
            providerPreset: effectiveProviderPreset
        )
        let upstreamAdapter = self.resolvedManualAPIKeyUpstreamAdapter(
            from: payload,
            providerPreset: effectiveProviderPreset
        )
        let chatCompatibilityProfile = self.extractChatCompletionsCompatibilityProfile(from: payload)
        let upstreamBaseURL = try self.normalizeManualAPIKeyBaseURL(
            rawBaseURL,
            providerPreset: effectiveProviderPreset
        )
        var normalized: [String: Any] = [
            "auth_mode": resolvedAuthMode.rawValue,
            "provider_preset": effectiveProviderPreset.rawValue,
            "upstream_base_url": upstreamBaseURL,
            "tokens": [
                "access_token": apiKey,
                "provider_preset": effectiveProviderPreset.rawValue,
                "account_id": self.syntheticAPIKeyAccountID(
                    apiKey,
                    baseURL: upstreamBaseURL,
                    authMode: resolvedAuthMode
                ),
            ],
        ]
        if let baseURLMode, effectiveProviderPreset == .genericOpenAICompatible {
            normalized["upstream_base_url_mode"] = baseURLMode.rawValue
        }
        if let upstreamAdapter, effectiveProviderPreset == .genericOpenAICompatible {
            normalized["upstream_adapter"] = upstreamAdapter.rawValue
        }
        if effectiveProviderPreset == .genericOpenAICompatible {
            normalized["chat_compatibility_profile"] = chatCompatibilityProfile.rawValue
        }
        return try self.jsonString(normalized)
    }

    private static func normalizeManualAPIKeyBaseURL(
        _ baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset
    ) throws -> String {
        switch providerPreset {
        case .anthropicAPICompatible:
            return try AnthropicAPIKeyUpstream.normalizeBaseURL(baseURL)
        case .genericOpenAICompatible, .aliyunQwenCodingPlan, .googleGeminiCompatible:
            return try OpenAICompatibleUpstream.normalizeBaseURL(baseURL, providerPreset: providerPreset)
        }
    }

    private static func syntheticAPIKeyAccountID(
        _ apiKey: String,
        baseURL: String,
        authMode: AccountAuthMode
    ) -> String {
        switch authMode {
        case .anthropicAPIKey:
            return AnthropicAPIKeyUpstream.syntheticAccountID(apiKey: apiKey, baseURL: baseURL)
        case .openAIAPIKey, .chatGPT, .anthropicSubscriptionOAuth, .geminiOAuth:
            return OpenAICompatibleUpstream.syntheticAccountID(apiKey: apiKey, baseURL: baseURL)
        }
    }

    private static func syntheticAnthropicPrincipalID(_ accessToken: String) -> String {
        "anthropic-" + String(Helpers.sha256(accessToken).prefix(24))
    }

    private static func syntheticGeminiPrincipalID(_ seed: String) -> String {
        "gemini-" + String(Helpers.sha256(seed).prefix(24))
    }

    private static func int64Value(from value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? String, let parsed = Int64(value) {
            return parsed
        }
        return nil
    }
}
