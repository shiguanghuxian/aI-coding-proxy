import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

public enum GeminiAuthService {
    public static let oauthClientIDEnvironmentVariable = "CODEX_PROXY_GEMINI_OAUTH_CLIENT_ID"
    public static let oauthClientSecretEnvironmentVariable = "CODEX_PROXY_GEMINI_OAUTH_CLIENT_SECRET"
    public static var defaultOAuthClientID: String {
        self.oauthEnvironmentValue(named: self.oauthClientIDEnvironmentVariable)
    }
    public static var defaultOAuthClientSecret: String {
        self.oauthEnvironmentValue(named: self.oauthClientSecretEnvironmentVariable)
    }
    public static let defaultOAuthScopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ].joined(separator: " ")
    public static let defaultAuthorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let defaultTokenURL = "https://oauth2.googleapis.com/token"
    public static let defaultUserInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"
    public static let defaultCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com"
    public static let defaultCodeAssistAPIVersion = "v1internal"
    public static let googleAIProBackend = "google_ai_pro"
    private static let operationPollAttempts = 30
    private static let operationPollIntervalNanoseconds: UInt64 = 250_000_000

    public static func prepareOAuthLogin(
        callbackPort: Int,
        config: AppConfig
    ) throws -> (PendingOAuthLogin, PreparedOAuthLogin) {
        let credentials = try self.oauthCredentials(config: config)
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let codeVerifier = [
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        ].joined()
        let challenge = Helpers.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        let redirectURI = AuthService.localOAuthRedirectURI(
            callbackPort: callbackPort,
            path: AuthService.geminiOAuthCallbackPath
        )
        var components = URLComponents(string: Self.defaultAuthorizeURL)
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: Self.defaultOAuthScopes),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = components?.url?.absoluteString, !authURL.isEmpty else {
            throw ProxyError.message("生成 Google / Gemini 授权链接失败")
        }

        return (
            PendingOAuthLogin(
                providerFamily: .gemini,
                redirectURI: redirectURI,
                state: state,
                codeVerifier: codeVerifier,
                expiresAt: Helpers.now() + AuthService.defaultOAuthTimeoutSeconds
            ),
            PreparedOAuthLogin(
                providerFamily: .gemini,
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
        let overrides = self.testingEndpointOverrides()
        return try await self.completeOAuthCallback(
            pending: pending,
            callbackURL: callbackURL,
            config: config,
            secretStore: secretStore,
            tokenURLOverride: overrides.tokenURL,
            codeAssistBaseURLOverride: overrides.codeAssistBaseURL,
            userInfoURLOverride: overrides.userInfoURL
        )
    }

    static func completeOAuthCallback(
        pending: PendingOAuthLogin,
        callbackURL: String,
        config: AppConfig,
        secretStore: SecretStore,
        tokenURLOverride: String?,
        codeAssistBaseURLOverride: String?,
        userInfoURLOverride: String?
    ) async throws -> String {
        guard pending.providerFamily == .gemini else {
            throw ProxyError.message("当前并非 Google / Gemini 登录会话")
        }
        guard pending.expiresAt >= Helpers.now() else {
            throw ProxyError.message("Google / Gemini 授权已过期，请重新生成授权链接")
        }

        let components = try self.parseOAuthCallbackURL(callbackURL)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let oauthError = items["error"], !oauthError.isEmpty {
            let detail = items["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? oauthError
            throw ProxyError.message("Google / Gemini 授权失败: \(detail)")
        }
        guard let state = items["state"], !state.isEmpty else {
            throw ProxyError.message("Google / Gemini callback 缺少 state")
        }
        guard state == pending.state else {
            throw ProxyError.message("Google / Gemini state 不匹配")
        }
        guard let code = items["code"], !code.isEmpty else {
            throw ProxyError.message("Google / Gemini callback 缺少 code")
        }

        let credentials = try self.oauthCredentials(config: config)
        let tokenURL = self.firstNonEmpty([tokenURLOverride, Self.defaultTokenURL]) ?? Self.defaultTokenURL
        let codeAssistBaseURL = self.firstNonEmpty([codeAssistBaseURLOverride, Self.defaultCodeAssistEndpoint])
            ?? Self.defaultCodeAssistEndpoint
        let response = try await HTTPClientFactory.request(
            config: config,
            url: tokenURL,
            method: .POST,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: self.authorizationCodeTokenRequestBody(
                code: code,
                redirectURI: pending.redirectURI,
                codeVerifier: pending.codeVerifier,
                credentials: credentials
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message(
                "Google / Gemini token 交换失败: \(response.statusCode) \(Helpers.truncate(response.bodyText))"
            )
        }

        let tokenResponse = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        guard let accessToken = tokenResponse["access_token"] as? String, !accessToken.isEmpty else {
            throw ProxyError.message("Google / Gemini token 返回缺少 access_token")
        }
        guard let refreshToken = tokenResponse["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw ProxyError.message("Google / Gemini token 返回缺少 refresh_token，请重新登录")
        }

        let eligibility = try await self.loadEligibility(
            accessToken: accessToken,
            projectID: nil,
            config: config,
            mode: .fullEligibilityCheck,
            baseURL: codeAssistBaseURL
        )
        let claims = self.claims(from: tokenResponse["id_token"] as? String)
        let userInfo = try await self.fetchUserInfo(
            accessToken: accessToken,
            config: config,
            url: self.firstNonEmpty([userInfoURLOverride, Self.defaultUserInfoURL]) ?? Self.defaultUserInfoURL
        )
        let email = self.firstNonEmpty([
            userInfo["email"] as? String,
            tokenResponse["email"] as? String,
            claims?["email"] as? String,
        ])
        let name = self.firstNonEmpty([
            userInfo["name"] as? String,
            tokenResponse["name"] as? String,
        ])
        let stableSeed = refreshToken
        let principalID = self.firstNonEmpty([
            userInfo["id"] as? String,
            tokenResponse["sub"] as? String,
            claims?["sub"] as? String,
        ]) ?? self.syntheticPrincipalID(seed: stableSeed)
        let accountID = principalID

        let bundle = GeminiOAuthSecretBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: self.expiration(from: tokenResponse),
            tokenType: tokenResponse["token_type"] as? String,
            scope: tokenResponse["scope"] as? String ?? Self.defaultOAuthScopes
        )
        let secretRef = try secretStore.saveGeminiOAuthSecret(bundle)
        let versionedBaseURL = Self.versionedCodeAssistBaseURL(codeAssistBaseURL)

        var authPayload: [String: Any] = [
            "provider_family": AccountProviderFamily.gemini.rawValue,
            "auth_mode": AccountAuthMode.geminiOAuth.rawValue,
            "gemini_auth_backend": Self.googleAIProBackend,
            "principal_id": principalID,
            "account_id": accountID,
            "plan_type": self.planType(from: eligibility),
            "secret_ref": secretRef,
            "oauth_client_id": credentials.clientID,
            "oauth_scopes": Self.defaultOAuthScopes,
            "oauth_authorize_url": Self.defaultAuthorizeURL,
            "oauth_token_url": tokenURL,
            "upstream_base_url": versionedBaseURL,
            "gemini_code_assist_project": eligibility.projectID,
            "expires_at": bundle.expiresAt as Any,
            "token_type": bundle.tokenType as Any,
            "scope": bundle.scope as Any,
        ]
        authPayload["email"] = email as Any
        authPayload["display_name"] = (name ?? email ?? "Google / Gemini") as Any
        self.applyEligibility(&authPayload, eligibility: eligibility)
        return try self.jsonString(authPayload)
    }

    public static func refreshGeminiAuth(
        _ text: String,
        config: AppConfig,
        secretStore: SecretStore
    ) async throws -> String {
        let payload = try self.jsonObject(text)
        guard let secretRef = self.secretRef(from: payload) else {
            throw ProxyError.message("Google / Gemini 授权信息缺少 secret_ref")
        }
        var bundle = try secretStore.loadGeminiOAuthSecret(ref: secretRef)
        guard let refreshToken = bundle.refreshToken, !refreshToken.isEmpty else {
            throw ProxyError.message("Google / Gemini 授权缺少 refresh_token，请重新登录")
        }

        let credentials = try self.oauthCredentials(config: config)
        let tokenURL = self.extractTokenURL(from: payload) ?? Self.defaultTokenURL
        let response = try await HTTPClientFactory.request(
            config: config,
            url: tokenURL,
            method: .POST,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: self.refreshTokenRequestBody(refreshToken: refreshToken, credentials: credentials)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message(
                "Google / Gemini token 刷新失败: \(response.statusCode) \(Helpers.truncate(response.bodyText))"
            )
        }

        let tokenResponse = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        guard let accessToken = tokenResponse["access_token"] as? String, !accessToken.isEmpty else {
            throw ProxyError.message("Google / Gemini token 刷新返回缺少 access_token")
        }

        bundle.accessToken = accessToken
        if let refreshToken = tokenResponse["refresh_token"] as? String, !refreshToken.isEmpty {
            bundle.refreshToken = refreshToken
        }
        bundle.expiresAt = self.expiration(from: tokenResponse)
        bundle.tokenType = tokenResponse["token_type"] as? String ?? bundle.tokenType
        bundle.scope = tokenResponse["scope"] as? String ?? Self.defaultOAuthScopes
        _ = try secretStore.saveGeminiOAuthSecret(bundle, ref: secretRef)

        var updated = payload
        updated["gemini_auth_backend"] = Self.googleAIProBackend
        updated["oauth_client_id"] = credentials.clientID
        updated["oauth_scopes"] = Self.defaultOAuthScopes
        updated["oauth_authorize_url"] = Self.defaultAuthorizeURL
        updated["oauth_token_url"] = tokenURL
        updated["upstream_base_url"] = Self.versionedCodeAssistBaseURL(
            self.firstNonEmpty([payload["upstream_base_url"] as? String, Self.defaultCodeAssistEndpoint])
                ?? Self.defaultCodeAssistEndpoint
        )
        updated["expires_at"] = bundle.expiresAt as Any
        updated["token_type"] = bundle.tokenType as Any
        updated["scope"] = bundle.scope as Any
        return try self.jsonString(updated)
    }

    public static func validateConnection(
        auth: ExtractedAuth,
        authJSON: String,
        config: AppConfig
    ) async throws -> String {
        let payload = try self.jsonObject(authJSON)
        let eligibility = try await self.loadEligibility(
            accessToken: auth.accessToken,
            projectID: self.projectID(from: payload),
            config: config,
            mode: .healthCheck,
            baseURL: self.extractBaseURL(from: payload)
        )
        var updated = payload
        updated["gemini_auth_backend"] = Self.googleAIProBackend
        updated["plan_type"] = self.planType(from: eligibility)
        updated["upstream_base_url"] = Self.versionedCodeAssistBaseURL(
            self.extractBaseURL(from: payload) ?? Self.defaultCodeAssistEndpoint
        )
        updated["gemini_code_assist_project"] = eligibility.projectID
        self.applyEligibility(&updated, eligibility: eligibility)
        return try self.jsonString(updated)
    }

    public static func apiRequest(
        auth: ExtractedAuth,
        method: String,
        accept: String,
        streaming: Bool = false
    ) -> (url: String, headers: [String: String]) {
        let baseURL = self.versionedCodeAssistBaseURL(auth.upstreamBaseURL ?? Self.defaultCodeAssistEndpoint)
        let suffix = streaming ? ":\(method)?alt=sse" : ":\(method)"
        return (
            "\(baseURL)\(suffix)",
            [
                "Authorization": "Bearer \(auth.accessToken)",
                "Accept": accept,
                "Content-Type": "application/json",
                "User-Agent": RuntimeInfo.daemonServerToken,
            ]
        )
    }

    public static func generateContentRequestBody(
        rawRequest: [String: Any],
        model: String,
        authJSON: String,
        sessionID: String?
    ) throws -> Data {
        let payload = try self.jsonObject(authJSON)
        guard let projectID = self.projectID(from: payload), !projectID.isEmpty else {
            throw ProxyError.message("Google / Gemini 账号缺少 Code Assist project，请重新登录")
        }

        var request = rawRequest
        if let sessionID, !sessionID.isEmpty {
            request["session_id"] = sessionID
        }

        var wrapped: [String: Any] = [
            "model": self.normalizedModelName(model),
            "project": projectID,
            "user_prompt_id": UUID().uuidString.lowercased(),
            "request": request,
        ]
        if let enabledCreditTypes = self.enabledCreditTypes(from: payload) {
            wrapped["enabled_credit_types"] = enabledCreditTypes
        }
        return try JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])
    }

    public static func countTokensRequestBody(
        rawRequest: [String: Any],
        model: String
    ) throws -> Data {
        let wrapped: [String: Any] = [
            "request": [
                "model": "models/\(self.normalizedModelName(model))",
                "contents": self.countTokenContents(from: rawRequest["contents"]),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])
    }

    public static func unwrappedGenerateContentResponse(
        from payload: [String: Any]
    ) throws -> [String: Any] {
        guard let response = payload["response"] as? [String: Any] else {
            throw ProxyError.message("Google / Gemini 上游未返回 generateContent response")
        }
        return response
    }

    static func projectID(fromAuthJSON text: String) -> String? {
        let payload = (try? self.jsonObject(text)) ?? [:]
        return self.projectID(from: payload)
    }

    private static func loadEligibility(
        accessToken: String,
        projectID: String?,
        config: AppConfig,
        mode: EligibilityMode,
        baseURL: String?
    ) async throws -> EligibilityState {
        switch mode {
        case .fullEligibilityCheck:
            return try await self.resolveEligibility(
                accessToken: accessToken,
                projectID: projectID,
                config: config,
                baseURL: baseURL
            )
        case .healthCheck:
            let payload = try await self.loadCodeAssistState(
                accessToken: accessToken,
                projectID: projectID,
                config: config,
                mode: mode,
                baseURL: baseURL
            )
            return try self.validateHealthCheckEligibility(from: payload)
        }
    }

    private static func codeAssistRequest(
        accessToken: String,
        baseURL: String?,
        method: String,
        accept: String,
        streaming: Bool = false
    ) -> (url: String, headers: [String: String]) {
        let resolvedBaseURL = self.versionedCodeAssistBaseURL(baseURL ?? Self.defaultCodeAssistEndpoint)
        let suffix = streaming ? ":\(method)?alt=sse" : ":\(method)"
        return (
            "\(resolvedBaseURL)\(suffix)",
            [
                "Authorization": "Bearer \(accessToken)",
                "Accept": accept,
                "Content-Type": "application/json",
                "User-Agent": RuntimeInfo.daemonServerToken,
            ]
        )
    }

    private static func resolveEligibility(
        accessToken: String,
        projectID: String?,
        config: AppConfig,
        baseURL: String?
    ) async throws -> EligibilityState {
        let initial = try await self.loadCodeAssistState(
            accessToken: accessToken,
            projectID: projectID,
            config: config,
            mode: .fullEligibilityCheck,
            baseURL: baseURL
        )
        try self.throwIfIneligible(initial.ineligibleTiers)
        if let ready = self.readyEligibility(from: initial) {
            return ready
        }

        guard let tier = self.selectedOnboardTier(from: initial) else {
            throw self.unsupportedLoginError(for: initial)
        }
        guard let tierID = tier.id, tierID.isEmpty == false else {
            throw ProxyError.message("Google / Gemini 登录初始化失败：未找到可用的个人 tier。")
        }

        let operation = try await self.onboardUser(
            accessToken: accessToken,
            tierID: tierID,
            projectID: initial.projectID,
            config: config,
            baseURL: baseURL
        )
        let onboardedProjectID = try await self.pollOperationUntilDone(
            initial: operation,
            accessToken: accessToken,
            config: config,
            baseURL: baseURL
        )
        let final = try await self.loadCodeAssistState(
            accessToken: accessToken,
            projectID: onboardedProjectID ?? initial.projectID,
            config: config,
            mode: .fullEligibilityCheck,
            baseURL: baseURL
        )
        try self.throwIfIneligible(final.ineligibleTiers)
        if let ready = self.readyEligibility(from: final) {
            return ready
        }
        if self.requiresUserDefinedProject(final) {
            throw ProxyError.message("当前账号属于需要自配 Cloud Project 的组织 / Workspace 流程，当前版本不支持。")
        }
        throw ProxyError.message("Google / Gemini 登录初始化完成，但仍未拿到可用的 Code Assist project，请稍后重试。")
    }

    private static func validateHealthCheckEligibility(from payload: LoadCodeAssistState) throws -> EligibilityState {
        try self.throwIfIneligible(payload.ineligibleTiers)
        if let ready = self.readyEligibility(from: payload) {
            return ready
        }
        if self.requiresUserDefinedProject(payload) {
            throw ProxyError.message("当前账号属于需要自配 Cloud Project 的组织 / Workspace 流程，当前版本不支持。")
        }
        if self.selectedOnboardTier(from: payload) != nil {
            throw ProxyError.message("当前 Google / Gemini 账号尚未完成初始化，请重新登录。")
        }
        throw self.unsupportedLoginError(for: payload)
    }

    private static func loadCodeAssistState(
        accessToken: String,
        projectID: String?,
        config: AppConfig,
        mode: EligibilityMode,
        baseURL: String?
    ) async throws -> LoadCodeAssistState {
        let request = self.codeAssistRequest(
            accessToken: accessToken,
            baseURL: baseURL,
            method: "loadCodeAssist",
            accept: "application/json"
        )
        let response = try await HTTPClientFactory.request(
            config: config,
            url: request.url,
            method: .POST,
            headers: request.headers,
            body: self.loadCodeAssistRequestBody(projectID: projectID, mode: mode)
        )
        let prefix = mode == .fullEligibilityCheck
            ? "Google / Gemini 登录资格检查失败"
            : "Google / Gemini 连通性校验失败"
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message(self.codeAssistFailureMessage(prefix: prefix, response: response))
        }
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        return self.parseLoadCodeAssistState(object)
    }

    private static func loadCodeAssistRequestBody(projectID: String?, mode: EligibilityMode) -> Data {
        let metadata = self.codeAssistMetadata(projectID: projectID)
        var payload: [String: Any] = [
            "metadata": metadata,
            "mode": mode.rawValue,
        ]
        if let projectID, !projectID.isEmpty {
            payload["cloudaicompanionProject"] = projectID
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func codeAssistMetadata(projectID: String?) -> [String: Any] {
        var metadata: [String: Any] = [
            "ideType": "GEMINI_CLI",
            "platform": self.clientMetadataPlatform(),
            "pluginType": "GEMINI",
            "ideName": "AI Coding Proxy",
        ]
        if let projectID, !projectID.isEmpty {
            metadata["duetProject"] = projectID
        }
        return metadata
    }

    private static func onboardUserRequestBody(tierID: String, projectID: String?) -> Data {
        var payload: [String: Any] = [
            "tierId": tierID,
            "metadata": self.codeAssistMetadata(projectID: projectID),
        ]
        if let projectID, !projectID.isEmpty {
            payload["cloudaicompanionProject"] = projectID
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func onboardUser(
        accessToken: String,
        tierID: String,
        projectID: String?,
        config: AppConfig,
        baseURL: String?
    ) async throws -> OperationState {
        let request = self.codeAssistRequest(
            accessToken: accessToken,
            baseURL: baseURL,
            method: "onboardUser",
            accept: "application/json"
        )
        let response = try await HTTPClientFactory.request(
            config: config,
            url: request.url,
            method: .POST,
            headers: request.headers,
            body: self.onboardUserRequestBody(tierID: tierID, projectID: projectID)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message(self.codeAssistFailureMessage(prefix: "Google / Gemini 账号初始化失败", response: response))
        }
        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        return self.parseOperationState(payload)
    }

    private static func pollOperationUntilDone(
        initial: OperationState,
        accessToken: String,
        config: AppConfig,
        baseURL: String?
    ) async throws -> String? {
        var current = initial
        if current.done {
            if let errorMessage = current.errorMessage {
                throw ProxyError.message("Google / Gemini 账号初始化失败: \(errorMessage)")
            }
            return current.projectID
        }

        guard let operationName = current.name, !operationName.isEmpty else {
            throw ProxyError.message("Google / Gemini 账号初始化失败：未返回可轮询的 operation。")
        }

        for attempt in 0..<Self.operationPollAttempts {
            current = try await self.loadOperation(
                accessToken: accessToken,
                operationName: operationName,
                config: config,
                baseURL: baseURL
            )
            if current.done {
                if let errorMessage = current.errorMessage {
                    throw ProxyError.message("Google / Gemini 账号初始化失败: \(errorMessage)")
                }
                return current.projectID
            }
            if attempt + 1 < Self.operationPollAttempts {
                try await Task.sleep(nanoseconds: Self.operationPollIntervalNanoseconds)
            }
        }

        throw ProxyError.message("Google / Gemini 账号初始化超时，请稍后重试登录。")
    }

    private static func loadOperation(
        accessToken: String,
        operationName: String,
        config: AppConfig,
        baseURL: String?
    ) async throws -> OperationState {
        let resolvedBaseURL = self.versionedCodeAssistBaseURL(baseURL ?? Self.defaultCodeAssistEndpoint)
        let trimmedName = operationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: String
        if trimmedName.lowercased().hasPrefix("http://") || trimmedName.lowercased().hasPrefix("https://") {
            url = trimmedName
        } else {
            let normalizedName = trimmedName.hasPrefix("/") ? String(trimmedName.dropFirst()) : trimmedName
            url = "\(resolvedBaseURL)/\(normalizedName)"
        }
        let response = try await HTTPClientFactory.request(
            config: config,
            url: url,
            method: .GET,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "User-Agent": RuntimeInfo.daemonServerToken,
            ],
            body: nil
        )
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message(self.codeAssistFailureMessage(prefix: "Google / Gemini 初始化轮询失败", response: response))
        }
        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        return self.parseOperationState(payload)
    }

    private static func authorizationCodeTokenRequestBody(
        code: String,
        redirectURI: String,
        codeVerifier: String,
        credentials: OAuthCredentials
    ) -> Data {
        self.formURLEncodedBody([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
        ])
    }

    private static func refreshTokenRequestBody(refreshToken: String, credentials: OAuthCredentials) -> Data {
        self.formURLEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
        ])
    }

    private static func fetchUserInfo(
        accessToken: String,
        config: AppConfig,
        url: String
    ) async throws -> [String: Any] {
        let response = try await HTTPClientFactory.request(
            config: config,
            url: url,
            method: .GET,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "User-Agent": RuntimeInfo.daemonServerToken,
            ],
            body: nil
        )
        guard (200..<300).contains(response.statusCode) else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
    }

    private static func parseOAuthCallbackURL(_ callbackURL: String) throws -> URLComponents {
        let trimmed = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProxyError.message("请提供完整的 Google / Gemini 回调链接")
        }
        if let absolute = URLComponents(string: trimmed), absolute.scheme?.isEmpty == false {
            return absolute
        }
        let normalized = trimmed.hasPrefix("/") ? "http://localhost\(trimmed)" : "http://localhost/\(trimmed)"
        if let relative = URLComponents(string: normalized), relative.scheme?.isEmpty == false {
            return relative
        }
        throw ProxyError.message("Google / Gemini 回调链接格式无效")
    }

    private static func projectID(from payload: [String: Any]) -> String? {
        self.firstNonEmpty([
            payload["gemini_code_assist_project"] as? String,
            payload["project_id"] as? String,
            payload["projectId"] as? String,
            payload["cloudaicompanion_project"] as? String,
            payload["cloudaicompanionProject"] as? String,
            (payload["cloudaicompanionProject"] as? [String: Any]).flatMap { $0["id"] as? String },
            (payload["cloudaicompanion_project"] as? [String: Any]).flatMap { $0["id"] as? String },
        ])
    }

    private static func extractBaseURL(from payload: [String: Any]) -> String? {
        self.firstNonEmpty([
            payload["upstream_base_url"] as? String,
            payload["upstreamBaseURL"] as? String,
            payload["base_url"] as? String,
            payload["baseURL"] as? String,
        ])
    }

    private static func applyEligibility(
        _ payload: inout [String: Any],
        eligibility: EligibilityState
    ) {
        payload["gemini_code_assist_project"] = eligibility.projectID
        payload["gemini_current_tier_id"] = eligibility.currentTierID as Any
        payload["gemini_current_tier_name"] = eligibility.currentTierName as Any
        payload["gemini_paid_tier_id"] = eligibility.paidTierID as Any
        payload["gemini_paid_tier_name"] = eligibility.paidTierName as Any
        payload["gemini_google_one_ai_credit_balance"] = eligibility.googleOneAICreditBalance as Any
    }

    private static func enabledCreditTypes(from payload: [String: Any]) -> [String]? {
        guard self.firstNonEmpty([payload["gemini_google_one_ai_credit_balance"] as? String]) != nil else {
            return nil
        }
        return ["GOOGLE_ONE_AI"]
    }

    private static func planType(from eligibility: EligibilityState) -> String {
        let markers = [
            eligibility.paidTierID,
            eligibility.paidTierName,
            eligibility.currentTierID,
            eligibility.currentTierName,
        ]
            .compactMap { $0?.lowercased() }
        if markers.contains(where: { $0.contains("ultra") }) {
            return "google_ai_ultra"
        }
        if eligibility.paidTierID != nil || eligibility.paidTierName != nil || markers.contains(where: { $0.contains("pro") }) {
            return "google_ai_pro"
        }
        return "free"
    }

    private static func countTokenContents(from rawContents: Any?) -> [[String: Any]] {
        guard let contents = rawContents as? [Any] else {
            return []
        }
        return contents.compactMap { self.sanitizedCountTokenContent($0) }
    }

    private static func sanitizedCountTokenContent(_ raw: Any) -> [String: Any]? {
        guard let content = raw as? [String: Any] else {
            return nil
        }
        var sanitized = content
        if let parts = content["parts"] as? [Any] {
            sanitized["parts"] = parts.compactMap { self.sanitizedCountTokenPart($0) }
        }
        return sanitized
    }

    private static func sanitizedCountTokenPart(_ raw: Any) -> [String: Any]? {
        guard var part = raw as? [String: Any] else {
            return nil
        }
        let isThought = self.boolValue(part["thought"]) == true
        part.removeValue(forKey: "thought")
        part.removeValue(forKey: "thoughtSignature")
        part.removeValue(forKey: "thought_signature")
        if isThought {
            let hasAPIContent = part["functionCall"] != nil
                || part["function_call"] != nil
                || part["functionResponse"] != nil
                || part["function_response"] != nil
                || part["inlineData"] != nil
                || part["inline_data"] != nil
                || part["fileData"] != nil
                || part["file_data"] != nil
            if hasAPIContent {
                return part
            }
            let existingText = self.firstNonEmpty([part["text"] as? String]) ?? ""
            let thoughtText = "[Thought: true]"
            part["text"] = existingText.isEmpty ? thoughtText : "\(existingText)\n\(thoughtText)"
        }
        return part
    }

    private static func claims(from token: String?) -> [String: Any]? {
        guard let token, !token.isEmpty else { return nil }
        return try? AuthService.decodeJWTPayload(token)
    }

    private static func expiration(from tokenResponse: [String: Any]) -> Int64? {
        if let expiresAt = self.int64Value(tokenResponse["expires_at"]) {
            return expiresAt
        }
        if let expiresIn = self.int64Value(tokenResponse["expires_in"]) {
            return Helpers.now() + expiresIn
        }
        return nil
    }

    private static func secretRef(from payload: [String: Any]) -> String? {
        self.firstNonEmpty([
            payload["secret_ref"] as? String,
            payload["secretRef"] as? String,
        ])
    }

    private static func extractTokenURL(from payload: [String: Any]) -> String? {
        self.firstNonEmpty([
            payload["oauth_token_url"] as? String,
            payload["oauthTokenURL"] as? String,
            payload["token_url"] as? String,
            payload["tokenURL"] as? String,
        ])
    }

    private static func googleOneAICreditBalance(from paidTier: [String: Any]) -> String? {
        let credits = paidTier["availableCredits"] as? [[String: Any]] ?? []
        return self.googleOneAICreditBalance(from: credits)
    }

    private static func googleOneAICreditBalance(from paidTier: TierState?) -> String? {
        guard let paidTier else { return nil }
        return self.googleOneAICreditBalance(from: paidTier.availableCredits)
    }

    private static func googleOneAICreditBalance(from credits: [[String: Any]]) -> String? {
        for credit in credits {
            guard let creditType = self.firstNonEmpty([credit["creditType"] as? String]),
                  creditType == "GOOGLE_ONE_AI"
            else {
                continue
            }
            return self.firstNonEmpty([credit["creditAmount"] as? String])
        }
        return nil
    }

    private static func ineligibleMessage(from tiers: [[String: Any]]) -> String {
        for tier in tiers {
            if let reasonCode = self.firstNonEmpty([tier["reasonCode"] as? String]),
               reasonCode == "VALIDATION_REQUIRED",
               let validationURL = self.firstNonEmpty([tier["validationUrl"] as? String])
            {
                let reasonMessage = self.firstNonEmpty([tier["reasonMessage"] as? String]) ?? "当前账号还需要先完成 Google 校验。"
                return "当前 Google 账号还需要先完成校验：\(reasonMessage) \(validationURL)"
            }
        }

        let reason = tiers
            .compactMap {
                self.firstNonEmpty([
                    $0["validationErrorMessage"] as? String,
                    $0["reasonMessage"] as? String,
                    $0["tierName"] as? String,
                ])
            }
            .first

        return reason ?? "当前 Google 账号不具备可用的 Gemini Code Assist / Google / Gemini 登录资格。"
    }

    private static func codeAssistFailureMessage(prefix: String, response: SimpleHTTPResponse) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return "\(prefix): \(response.statusCode) \(Helpers.truncate(response.bodyText))"
        }
        let detail = self.firstNonEmpty([
            ((payload["error"] as? [String: Any])?["message"]) as? String,
            payload["message"] as? String,
        ]) ?? Helpers.truncate(response.bodyText)
        return "\(prefix): \(response.statusCode) \(detail)"
    }

    private static func normalizedModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return GeminiTranscoder.defaultGeminiModel
        }
        if trimmed.hasPrefix("models/") {
            return String(trimmed.dropFirst("models/".count))
        }
        return trimmed
    }

    private static func clientMetadataPlatform() -> String {
        #if os(macOS)
        #if arch(arm64)
        return "DARWIN_ARM64"
        #else
        return "DARWIN_AMD64"
        #endif
        #elseif os(Linux)
        #if arch(arm64)
        return "LINUX_ARM64"
        #else
        return "LINUX_AMD64"
        #endif
        #elseif os(Windows)
        return "WINDOWS_AMD64"
        #else
        return "PLATFORM_UNSPECIFIED"
        #endif
    }

    private static func syntheticPrincipalID(seed: String) -> String {
        "gemini-" + String(Helpers.sha256(seed).prefix(24))
    }

    private static func versionedCodeAssistBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = Self.defaultCodeAssistEndpoint + "/" + Self.defaultCodeAssistAPIVersion
        guard var components = URLComponents(string: trimmed.isEmpty ? Self.defaultCodeAssistEndpoint : trimmed) else {
            return fallback
        }

        let version = Self.defaultCodeAssistAPIVersion.lowercased()
        let loweredPath = components.path.lowercased()
        if loweredPath.hasSuffix("/\(version)") || loweredPath == "/\(version)" {
            components.path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        } else {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = path.isEmpty ? "/\(Self.defaultCodeAssistAPIVersion)" : "/\(path)/\(Self.defaultCodeAssistAPIVersion)"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? fallback
    }

    private static func int64Value(_ value: Any?) -> Int64? {
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

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private struct OAuthCredentials {
        var clientID: String
        var clientSecret: String
    }

    private static func oauthCredentials(config: AppConfig) throws -> OAuthCredentials {
        let clientID = self.firstNonEmpty([
            config.geminiOAuth.clientID,
            self.defaultOAuthClientID,
        ]) ?? ""
        guard !clientID.isEmpty else {
            throw ProxyError.message(
                "Google / Gemini OAuth 缺少 client id，请在设置 > 常规 > Google / Gemini OAuth 中填写 Client ID，或设置 \(self.oauthClientIDEnvironmentVariable) 环境变量。"
            )
        }
        let clientSecret = self.firstNonEmpty([
            config.geminiOAuth.clientSecret,
            self.defaultOAuthClientSecret,
        ]) ?? ""
        guard !clientSecret.isEmpty else {
            throw ProxyError.message(
                "Google / Gemini OAuth 缺少 client secret，请在设置 > 常规 > Google / Gemini OAuth 中填写 Client Secret，或设置 \(self.oauthClientSecretEnvironmentVariable) 环境变量。"
            )
        }
        return OAuthCredentials(clientID: clientID, clientSecret: clientSecret)
    }

    private static func oauthEnvironmentValue(named name: String) -> String {
        ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func formURLEncodedBody(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        let body = parameters
            .map { key, value in
                "\(self.formComponent(key, allowed: allowed))=\(self.formComponent(value, allowed: allowed))"
            }
            .sorted()
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func formComponent(_ value: String, allowed: CharacterSet) -> String {
        value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+")
            ?? value
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonObject(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }

    private static func testingEndpointOverrides() -> (tokenURL: String?, codeAssistBaseURL: String?, userInfoURL: String?) {
        let env = ProcessInfo.processInfo.environment
        return (
            self.firstNonEmpty([env["CODEX_PROXY_TEST_GEMINI_TOKEN_URL"]]),
            self.firstNonEmpty([env["CODEX_PROXY_TEST_GEMINI_CODE_ASSIST_BASE_URL"]]),
            self.firstNonEmpty([env["CODEX_PROXY_TEST_GEMINI_USERINFO_URL"]])
        )
    }

    private static func parseLoadCodeAssistState(_ payload: [String: Any]) -> LoadCodeAssistState {
        LoadCodeAssistState(
            currentTier: self.parseTier(payload["currentTier"] as? [String: Any]),
            allowedTiers: (payload["allowedTiers"] as? [[String: Any]] ?? []).compactMap(self.parseTier),
            paidTier: self.parseTier(payload["paidTier"] as? [String: Any]),
            ineligibleTiers: payload["ineligibleTiers"] as? [[String: Any]] ?? [],
            projectID: self.projectID(from: payload)
        )
    }

    private static func parseTier(_ payload: [String: Any]?) -> TierState? {
        guard let payload else { return nil }
        let id = self.firstNonEmpty([payload["id"] as? String])
        let name = self.firstNonEmpty([payload["name"] as? String])
        guard id != nil || name != nil else { return nil }
        return TierState(
            id: id,
            name: name,
            isDefault: self.boolValue(payload["isDefault"]) == true,
            requiresUserDefinedProject: self.boolValue(payload["userDefinedCloudaicompanionProject"]) == true,
            availableCredits: payload["availableCredits"] as? [[String: Any]] ?? []
        )
    }

    private static func parseOperationState(_ payload: [String: Any]) -> OperationState {
        let name = self.firstNonEmpty([payload["name"] as? String])
        let response = payload["response"] as? [String: Any]
        let errorMessage = self.firstNonEmpty([
            (payload["error"] as? [String: Any])?["message"] as? String,
            payload["error"] as? String,
            (response?["error"] as? [String: Any])?["message"] as? String,
        ])
        let done = self.boolValue(payload["done"]) ?? (name == nil)
        let projectID = self.firstNonEmpty([
            self.projectID(from: payload),
            response.flatMap { self.projectID(from: $0) },
        ])
        return OperationState(
            name: name,
            done: done,
            projectID: projectID,
            errorMessage: errorMessage
        )
    }

    private static func throwIfIneligible(_ ineligibleTiers: [[String: Any]]) throws {
        guard ineligibleTiers.isEmpty == false else { return }
        throw ProxyError.message(self.ineligibleMessage(from: ineligibleTiers))
    }

    private static func readyEligibility(from payload: LoadCodeAssistState) -> EligibilityState? {
        guard let currentTier = payload.currentTier,
              let projectID = payload.projectID,
              projectID.isEmpty == false
        else {
            return nil
        }

        return EligibilityState(
            projectID: projectID,
            currentTierID: currentTier.id,
            currentTierName: currentTier.name,
            paidTierID: payload.paidTier?.id,
            paidTierName: payload.paidTier?.name,
            googleOneAICreditBalance: self.googleOneAICreditBalance(from: payload.paidTier)
        )
    }

    private static func selectedOnboardTier(from payload: LoadCodeAssistState) -> TierState? {
        if let currentTier = payload.currentTier,
           currentTier.requiresUserDefinedProject == false,
           let tierID = currentTier.id,
           tierID.isEmpty == false
        {
            return currentTier
        }

        let allowed = payload.allowedTiers.filter {
            $0.requiresUserDefinedProject == false && (($0.id ?? "").isEmpty == false)
        }
        if let defaultTier = allowed.first(where: { $0.isDefault }) {
            return defaultTier
        }
        return allowed.first
    }

    private static func requiresUserDefinedProject(_ payload: LoadCodeAssistState) -> Bool {
        let tiers = ([payload.currentTier].compactMap { $0 } + payload.allowedTiers)
        guard tiers.isEmpty == false else { return false }
        return tiers.allSatisfy { $0.requiresUserDefinedProject }
    }

    private static func unsupportedLoginError(for payload: LoadCodeAssistState) -> ProxyError {
        if self.requiresUserDefinedProject(payload) {
            return ProxyError.message("当前账号属于需要自配 Cloud Project 的组织 / Workspace 流程，当前版本不支持。")
        }
        return ProxyError.message("当前 Google 账号没有可用的 Gemini 个人登录资格，请确认它是官方 Gemini CLI 支持的个人账号。")
    }

    private struct EligibilityState {
        var projectID: String
        var currentTierID: String?
        var currentTierName: String?
        var paidTierID: String?
        var paidTierName: String?
        var googleOneAICreditBalance: String?
    }

    private struct TierState {
        var id: String?
        var name: String?
        var isDefault: Bool
        var requiresUserDefinedProject: Bool
        var availableCredits: [[String: Any]]
    }

    private struct LoadCodeAssistState {
        var currentTier: TierState?
        var allowedTiers: [TierState]
        var paidTier: TierState?
        var ineligibleTiers: [[String: Any]]
        var projectID: String?
    }

    private struct OperationState {
        var name: String?
        var done: Bool
        var projectID: String?
        var errorMessage: String?
    }

    private enum EligibilityMode: String {
        case fullEligibilityCheck = "FULL_ELIGIBILITY_CHECK"
        case healthCheck = "HEALTH_CHECK"
    }
}
