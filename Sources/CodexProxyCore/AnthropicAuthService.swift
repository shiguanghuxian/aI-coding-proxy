import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

public enum AnthropicAuthService {
    public static let defaultAPIBaseURL = "https://api.anthropic.com"
    public static let defaultConsoleAuthorizeURL = "https://platform.claude.com/oauth/authorize"
    public static let defaultAuthorizeURL = "https://claude.com/cai/oauth/authorize"
    public static let defaultClaudeAIAuthorizeURL = defaultAuthorizeURL
    public static let defaultTokenURL = "https://platform.claude.com/v1/oauth/token"
    public static let defaultClientMetadataURL = "https://claude.ai/oauth/claude-code-client-metadata"
    public static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let defaultOAuthBetaHeader = "oauth-2025-04-20"
    public static let defaultOAuthTimeoutSeconds: Int64 = 300
    public static let defaultScopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ]
    public static let reauthorizationRequiredMessage = "当前 Anthropic OAuth 凭据缺少推理权限，请在账号页重新授权登录。"

    public struct OAuthConfigSnapshot: Sendable, Equatable {
        public var clientID: String
        public var authorizeURL: String
        public var tokenURL: String
        public var requestedScope: String
        public var betaHeader: String
        public var apiBaseURL: String
        public var loginSource: String

        public init(
            clientID: String,
            authorizeURL: String,
            tokenURL: String,
            requestedScope: String,
            betaHeader: String,
            apiBaseURL: String,
            loginSource: String
        ) {
            self.clientID = clientID
            self.authorizeURL = authorizeURL
            self.tokenURL = tokenURL
            self.requestedScope = requestedScope
            self.betaHeader = betaHeader
            self.apiBaseURL = apiBaseURL
            self.loginSource = loginSource
        }
    }

    public static func prepareOAuthLogin(
        callbackPort: Int,
        config: AppConfig
    ) async throws -> (PendingOAuthLogin, PreparedOAuthLogin) {
        let oauthConfig = try await self.oauthConfig(config: config)
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let codeVerifier = [
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        ].joined()
        let challenge = Helpers.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        let redirectURI = AuthService.localOAuthRedirectURI(
            callbackPort: callbackPort,
            path: AuthService.anthropicOAuthCallbackPath
        )
        var components = URLComponents(string: oauthConfig.authorizeURL)
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: oauthConfig.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
            .init(name: "scope", value: oauthConfig.requestedScope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = components?.url?.absoluteString, !authURL.isEmpty else {
            throw ProxyError.message("生成 Anthropic OAuth 授权链接失败")
        }
        return (
            PendingOAuthLogin(
                providerFamily: .anthropic,
                redirectURI: redirectURI,
                state: state,
                codeVerifier: codeVerifier,
                expiresAt: Helpers.now() + Self.defaultOAuthTimeoutSeconds,
                anthropicOAuthConfigSnapshot: oauthConfig.snapshot
            ),
            PreparedOAuthLogin(
                providerFamily: .anthropic,
                authURL: authURL,
                redirectURI: redirectURI
            )
        )
    }

    public static func completeOAuthCallback(
        pending: PendingOAuthLogin,
        callbackURL: String,
        config: AppConfig,
        secretStore: SecretStore
    ) async throws -> String {
        guard pending.providerFamily == .anthropic else {
            throw ProxyError.message("当前并非 Anthropic OAuth 会话")
        }
        guard pending.expiresAt >= Helpers.now() else {
            throw ProxyError.message("Anthropic OAuth 授权已过期，请重新生成授权链接")
        }

        let components = try self.parseOAuthCallbackURL(callbackURL)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let oauthError = items["error"], !oauthError.isEmpty {
            let detail = items["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? oauthError
            throw ProxyError.message("Anthropic 授权失败: \(detail)")
        }
        guard let state = items["state"], !state.isEmpty else {
            throw ProxyError.message("Anthropic OAuth callback 缺少 state")
        }
        guard state == pending.state else {
            throw ProxyError.message("Anthropic OAuth state 不匹配")
        }
        guard let code = items["code"], !code.isEmpty else {
            throw ProxyError.message("Anthropic OAuth callback 缺少 code")
        }

        let oauthConfig = try await self.oauthConfig(
            config: config,
            payload: nil,
            pendingSnapshot: pending.anthropicOAuthConfigSnapshot
        )
        let response = try await HTTPClientFactory.request(
            config: config,
            url: oauthConfig.tokenURL,
            method: .POST,
            headers: self.tokenRequestHeaders(),
            body: try self.authorizationCodeTokenRequestBody(pending: pending, code: code, clientID: oauthConfig.clientID)
        )
        guard (200..<300).contains(response.statusCode) else {
            self.logTokenRequestFailure(
                kind: "token_exchange",
                endpoint: oauthConfig.tokenURL,
                statusCode: response.statusCode,
                usesJSONBody: true
            )
            throw ProxyError.message("Anthropic OAuth token 交换失败: \(response.statusCode) \(Helpers.truncate(response.bodyText))")
        }

        let tokenResponse = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        guard let accessToken = tokenResponse["access_token"] as? String, !accessToken.isEmpty else {
            throw ProxyError.message("Anthropic OAuth token 返回缺少 access_token")
        }

        let bundle = AnthropicOAuthSecretBundle(
            accessToken: accessToken,
            refreshToken: tokenResponse["refresh_token"] as? String,
            expiresAt: self.expiration(from: tokenResponse),
            tokenType: tokenResponse["token_type"] as? String,
            scope: tokenResponse["scope"] as? String ?? oauthConfig.requestedScope
        )
        let secretRef = try secretStore.saveAnthropicOAuthSecret(bundle)

        let tokenClaims = self.claims(from: tokenResponse["id_token"] as? String)
            ?? self.claims(from: accessToken)
        let principalID = self.firstNonEmpty([
            tokenResponse["sub"] as? String,
            tokenClaims?["sub"] as? String,
            tokenResponse["account_id"] as? String,
        ]) ?? self.syntheticAccountID(accessToken: accessToken)
        let accountID = self.firstNonEmpty([
            tokenResponse["account_id"] as? String,
            tokenClaims?["account_id"] as? String,
            principalID,
        ]) ?? principalID
        let email = self.firstNonEmpty([
            tokenResponse["email"] as? String,
            tokenClaims?["email"] as? String,
        ])
        let displayName = self.firstNonEmpty([
            tokenResponse["name"] as? String,
            tokenResponse["display_name"] as? String,
            email,
            "Anthropic \(String(accountID.prefix(6)))",
        ])

        let authPayload: [String: Any] = [
            "provider_family": AccountProviderFamily.anthropic.rawValue,
            "auth_mode": AccountAuthMode.anthropicSubscriptionOAuth.rawValue,
            "principal_id": principalID,
            "account_id": accountID,
            "email": email as Any,
            "display_name": displayName as Any,
            "plan_type": "subscription_oauth",
            "secret_ref": secretRef,
            "oauth_client_id": oauthConfig.clientID,
            "oauth_authorize_url": oauthConfig.authorizeURL,
            "oauth_token_url": oauthConfig.tokenURL,
            "oauth_requested_scope": oauthConfig.requestedScope,
            "oauth_login_source": oauthConfig.loginSource,
            "oauth_beta_header": oauthConfig.betaHeader,
            "upstream_base_url": oauthConfig.apiBaseURL,
            "expires_at": bundle.expiresAt as Any,
            "token_type": bundle.tokenType as Any,
            "scope": bundle.scope as Any,
        ]
        return try self.jsonString(authPayload)
    }

    public static func refreshAnthropicAuth(
        _ text: String,
        config: AppConfig,
        secretStore: SecretStore
    ) async throws -> String {
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        guard let secretRef = self.secretRef(from: payload) else {
            throw ProxyError.message("Anthropic 授权信息缺少 secret_ref")
        }
        var bundle = try secretStore.loadAnthropicOAuthSecret(ref: secretRef)
        guard let refreshToken = bundle.refreshToken, !refreshToken.isEmpty else {
            throw ProxyError.message("Anthropic 授权缺少 refresh_token，请重新登录")
        }

        let oauthConfig = try await self.oauthConfig(config: config, payload: payload)
        if self.requiresReauthorization(payload: payload, bundle: bundle) {
            throw ProxyError.message(self.reauthorizationRequiredMessage)
        }
        let refreshScope = self.resolvedRefreshScope(bundle: bundle, payload: payload, fallback: oauthConfig.requestedScope)
        let response = try await HTTPClientFactory.request(
            config: config,
            url: oauthConfig.tokenURL,
            method: .POST,
            headers: self.tokenRequestHeaders(),
            body: try self.refreshTokenRequestBody(
                refreshToken: refreshToken,
                clientID: oauthConfig.clientID,
                scope: refreshScope
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            self.logTokenRequestFailure(
                kind: "token_refresh",
                endpoint: oauthConfig.tokenURL,
                statusCode: response.statusCode,
                usesJSONBody: true
            )
            throw ProxyError.message("Anthropic token 刷新失败: \(response.statusCode) \(Helpers.truncate(response.bodyText))")
        }

        let tokenResponse = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        guard let accessToken = tokenResponse["access_token"] as? String, !accessToken.isEmpty else {
            throw ProxyError.message("Anthropic token 刷新返回缺少 access_token")
        }

        bundle.accessToken = accessToken
        if let refreshToken = tokenResponse["refresh_token"] as? String, !refreshToken.isEmpty {
            bundle.refreshToken = refreshToken
        }
        bundle.expiresAt = self.expiration(from: tokenResponse)
        bundle.tokenType = tokenResponse["token_type"] as? String ?? bundle.tokenType
        bundle.scope = tokenResponse["scope"] as? String ?? refreshScope
        _ = try secretStore.saveAnthropicOAuthSecret(bundle, ref: secretRef)

        var updated = payload
        updated["expires_at"] = bundle.expiresAt
        updated["token_type"] = bundle.tokenType
        updated["scope"] = bundle.scope
        updated["oauth_requested_scope"] = payload["oauth_requested_scope"] as? String ?? refreshScope
        return try self.jsonString(updated)
    }

    private static func oauthConfig(
        config: AppConfig,
        payload: [String: Any]? = nil,
        pendingSnapshot: OAuthConfigSnapshot? = nil
    ) async throws -> OAuthConfig {
        if let pendingSnapshot {
            return OAuthConfig(snapshot: pendingSnapshot)
        }

        let env = ProcessInfo.processInfo.environment
        let customBase = env["CLAUDE_CODE_CUSTOM_OAUTH_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = try await self.fetchClientMetadataIfNeeded(config: config, env: env)

        let clientID = self.firstNonEmpty([
            payload?["oauth_client_id"] as? String,
            env["CLAUDE_CODE_OAUTH_CLIENT_ID"],
            metadata?.clientID,
        ]) ?? self.defaultClientID
        let apiBaseURL = self.firstNonEmpty([
            payload?["upstream_base_url"] as? String,
            customBase,
            metadata?.apiBaseURL,
            self.defaultAPIBaseURL,
        ]) ?? self.defaultAPIBaseURL
        let authorizeURL = self.firstNonEmpty([
            payload?["oauth_authorize_url"] as? String,
            env["CLAUDE_CODE_AUTHORIZE_URL"],
            customBase.map { "\($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/oauth/authorize" },
            metadata?.authorizeURL,
            self.defaultAuthorizeURL,
        ]) ?? self.defaultAuthorizeURL
        let tokenURL = self.firstNonEmpty([
            payload?["oauth_token_url"] as? String,
            env["CLAUDE_CODE_TOKEN_URL"],
            customBase.map { "\($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/oauth/token" },
            metadata?.tokenURL,
            self.defaultTokenURL,
        ]) ?? self.defaultTokenURL
        let betaHeader = self.firstNonEmpty([
            payload?["oauth_beta_header"] as? String,
            env["CLAUDE_CODE_OAUTH_BETA_HEADER"],
            metadata?.betaHeader,
            self.defaultOAuthBetaHeader,
        ]) ?? self.defaultOAuthBetaHeader
        let requestedScope = self.firstNonEmpty([
            payload?["oauth_requested_scope"] as? String,
            env["CLAUDE_CODE_OAUTH_SCOPES"],
            metadata?.requestedScope,
            self.defaultRequestedScope,
        ]) ?? self.defaultRequestedScope
        let loginSource = self.firstNonEmpty([
            payload?["oauth_login_source"] as? String,
            self.envOverrideSource(env: env),
            metadata == nil ? nil : OAuthLoginSource.clientMetadata.rawValue,
            OAuthLoginSource.claudeAISubscription.rawValue,
        ]) ?? OAuthLoginSource.claudeAISubscription.rawValue

        return OAuthConfig(
            clientID: clientID,
            authorizeURL: authorizeURL,
            tokenURL: tokenURL,
            apiBaseURL: apiBaseURL,
            betaHeader: betaHeader,
            requestedScope: requestedScope,
            loginSource: loginSource
        )
    }

    private static func secretRef(from payload: [String: Any]) -> String? {
        self.firstNonEmpty([
            payload["secret_ref"] as? String,
            payload["secretRef"] as? String,
        ])
    }

    private static func parseOAuthCallbackURL(_ callbackURL: String) throws -> URLComponents {
        let trimmed = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProxyError.message("请提供完整的 Anthropic 回调链接")
        }
        if let absolute = URLComponents(string: trimmed), absolute.scheme?.isEmpty == false {
            return absolute
        }
        let normalized = trimmed.hasPrefix("/") ? "http://localhost\(trimmed)" : "http://localhost/\(trimmed)"
        if let relative = URLComponents(string: normalized), relative.scheme?.isEmpty == false {
            return relative
        }
        throw ProxyError.message("Anthropic 回调链接格式无效")
    }

    private static func expiration(from tokenResponse: [String: Any]) -> Int64? {
        if let expiresAt = int64Value(from: tokenResponse["expires_at"]) {
            return expiresAt
        }
        if let expiresIn = int64Value(from: tokenResponse["expires_in"]) {
            return Helpers.now() + expiresIn
        }
        return nil
    }

    private static func claims(from token: String?) -> [String: Any]? {
        guard let token, !token.isEmpty else { return nil }
        return try? AuthService.decodeJWTPayload(token)
    }

    private static func syntheticAccountID(accessToken: String) -> String {
        "anthropic-" + String(Helpers.sha256(accessToken).prefix(24))
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
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

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func tokenRequestHeaders() -> [String: String] {
        ["Content-Type": "application/json"]
    }

    static func authorizationCodeTokenRequestBody(
        pending: PendingOAuthLogin,
        code: String,
        clientID: String
    ) throws -> Data {
        try self.jsonBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": pending.redirectURI,
            "client_id": clientID,
            "code_verifier": pending.codeVerifier,
            "state": pending.state,
        ])
    }

    static func refreshTokenRequestBody(
        refreshToken: String,
        clientID: String,
        scope: String
    ) throws -> Data {
        try self.jsonBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scope,
        ])
    }

    private static func jsonBody(_ parameters: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
    }

    private static func resolvedRefreshScope(
        bundle: AnthropicOAuthSecretBundle,
        payload: [String: Any],
        fallback: String
    ) -> String {
        self.firstNonEmpty([
            payload["oauth_requested_scope"] as? String,
            payload["scope"] as? String,
            bundle.scope,
            fallback,
        ]) ?? fallback
    }

    private static func requiresReauthorization(
        payload: [String: Any],
        bundle: AnthropicOAuthSecretBundle
    ) -> Bool {
        if let requestedScope = self.firstNonEmpty([
            payload["oauth_requested_scope"] as? String,
        ]) {
            return self.hasInferenceCapability(scopeText: requestedScope) == false
        }

        if self.isLegacyConsoleAuthorization(payload: payload) {
            return true
        }

        if let resolvedScope = self.firstNonEmpty([
            payload["scope"] as? String,
            bundle.scope,
        ]) {
            return self.hasInferenceCapability(scopeText: resolvedScope) == false
        }

        return false
    }

    public static func isInferenceScopePermissionError(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("permission_error") else {
            return false
        }
        return lower.contains("scope requirement")
            || lower.contains("does not meet scope requirement")
            || lower.contains("user:inference")
            || lower.contains("ccr_inference")
            || lower.contains("service_key_inference")
    }

    private static func hasInferenceCapability(scopeText: String) -> Bool {
        let scopes = scopeText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return scopes.contains {
            $0.contains("inference") || $0 == "user:voice"
        }
    }

    private static func isLegacyConsoleAuthorization(payload: [String: Any]) -> Bool {
        if let loginSource = self.firstNonEmpty([
            payload["oauth_login_source"] as? String,
        ]) {
            return loginSource == OAuthLoginSource.consoleLegacy.rawValue
                || loginSource == OAuthLoginSource.legacyUnknown.rawValue
        }

        if let authorizeURL = self.firstNonEmpty([
            payload["oauth_authorize_url"] as? String,
        ]) {
            return self.normalizedURLString(authorizeURL) == self.normalizedURLString(self.defaultConsoleAuthorizeURL)
        }

        return false
    }

    private static func fetchClientMetadataIfNeeded(
        config: AppConfig,
        env: [String: String]
    ) async throws -> ClientMetadata? {
        if self.envOverrideSource(env: env) != nil {
            return nil
        }

        let metadataURL = self.firstNonEmpty([
            env["CLAUDE_CODE_CLIENT_METADATA_URL"],
            self.defaultClientMetadataURL,
        ]) ?? self.defaultClientMetadataURL
        return try await self.fetchClientMetadata(config: config, url: metadataURL)
    }

    private static func fetchClientMetadata(
        config: AppConfig,
        url: String
    ) async throws -> ClientMetadata? {
        guard URL(string: url) != nil else {
            return nil
        }

        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return self.clientMetadata(from: object)
        } catch {
            _ = config
            return nil
        }
    }

    private static func clientMetadata(from object: [String: Any]) -> ClientMetadata? {
        let requestedScope = self.scopeText(
            from: object["scopes"] ?? object["scope"] ?? object["requested_scope"] ?? object["requestedScope"]
        )
        let clientID = self.firstNonEmpty([
            object["client_id"] as? String,
            object["clientId"] as? String,
        ])
        let authorizeURL = self.firstNonEmpty([
            object["authorization_endpoint"] as? String,
            object["authorizationEndpoint"] as? String,
            object["authorize_url"] as? String,
            object["authorizeURL"] as? String,
        ])
        let tokenURL = self.firstNonEmpty([
            object["token_endpoint"] as? String,
            object["tokenEndpoint"] as? String,
            object["token_url"] as? String,
            object["tokenURL"] as? String,
        ])
        let apiBaseURL = self.firstNonEmpty([
            object["api_base_url"] as? String,
            object["apiBaseURL"] as? String,
            object["api_url"] as? String,
            object["apiURL"] as? String,
        ])
        let betaHeader = self.firstNonEmpty([
            object["oauth_beta_header"] as? String,
            object["oauthBetaHeader"] as? String,
            object["beta_header"] as? String,
            object["betaHeader"] as? String,
        ])

        if clientID == nil && authorizeURL == nil && tokenURL == nil && requestedScope == nil && apiBaseURL == nil && betaHeader == nil {
            return nil
        }

        return ClientMetadata(
            clientID: clientID,
            authorizeURL: authorizeURL,
            tokenURL: tokenURL,
            requestedScope: requestedScope,
            betaHeader: betaHeader,
            apiBaseURL: apiBaseURL
        )
    }

    private static func scopeText(from value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let values = value as? [String] {
            let joined = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func envOverrideSource(env: [String: String]) -> String? {
        let keys = [
            "CLAUDE_CODE_CUSTOM_OAUTH_URL",
            "CLAUDE_CODE_OAUTH_CLIENT_ID",
            "CLAUDE_CODE_AUTHORIZE_URL",
            "CLAUDE_CODE_TOKEN_URL",
            "CLAUDE_CODE_OAUTH_BETA_HEADER",
            "CLAUDE_CODE_OAUTH_SCOPES",
        ]
        let hasOverride = keys.contains {
            let value = env[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty == false
        }
        return hasOverride ? OAuthLoginSource.environmentOverride.rawValue : nil
    }

    private static func normalizedURLString(_ url: String) -> String {
        url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private static func logTokenRequestFailure(
        kind: String,
        endpoint: String,
        statusCode: Int,
        usesJSONBody: Bool
    ) {
        print("[oauth] Anthropic \(kind) failed endpoint=\(endpoint) status=\(statusCode) json_body=\(usesJSONBody)")
    }

    private struct OAuthConfig {
        var clientID: String
        var authorizeURL: String
        var tokenURL: String
        var apiBaseURL: String
        var betaHeader: String
        var requestedScope: String
        var loginSource: String

        var snapshot: OAuthConfigSnapshot {
            OAuthConfigSnapshot(
                clientID: self.clientID,
                authorizeURL: self.authorizeURL,
                tokenURL: self.tokenURL,
                requestedScope: self.requestedScope,
                betaHeader: self.betaHeader,
                apiBaseURL: self.apiBaseURL,
                loginSource: self.loginSource
            )
        }

        init(
            clientID: String,
            authorizeURL: String,
            tokenURL: String,
            apiBaseURL: String,
            betaHeader: String,
            requestedScope: String,
            loginSource: String
        ) {
            self.clientID = clientID
            self.authorizeURL = authorizeURL
            self.tokenURL = tokenURL
            self.apiBaseURL = apiBaseURL
            self.betaHeader = betaHeader
            self.requestedScope = requestedScope
            self.loginSource = loginSource
        }

        init(snapshot: OAuthConfigSnapshot) {
            self.init(
                clientID: snapshot.clientID,
                authorizeURL: snapshot.authorizeURL,
                tokenURL: snapshot.tokenURL,
                apiBaseURL: snapshot.apiBaseURL,
                betaHeader: snapshot.betaHeader,
                requestedScope: snapshot.requestedScope,
                loginSource: snapshot.loginSource
            )
        }
    }

    private struct ClientMetadata {
        var clientID: String?
        var authorizeURL: String?
        var tokenURL: String?
        var requestedScope: String?
        var betaHeader: String?
        var apiBaseURL: String?
    }

    private enum OAuthLoginSource: String {
        case clientMetadata = "client_metadata"
        case claudeAISubscription = "claude_ai_subscription"
        case environmentOverride = "environment_override"
        case consoleLegacy = "console_legacy"
        case legacyUnknown = "legacy_unknown"
    }

    private static var defaultRequestedScope: String {
        self.defaultScopes.joined(separator: " ")
    }
}
