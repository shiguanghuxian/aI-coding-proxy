import Foundation

public enum ProxyError: Error, LocalizedError, Sendable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

public enum OutboundProxyScheme: String, Codable, Sendable, CaseIterable {
    case disabled
    case http
    case https
    case socks5
}

public enum OutboundProxyMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case manual
    case subscription
}

public struct OutboundProxySettings: Codable, Sendable, Equatable {
    public var scheme: OutboundProxyScheme
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(
        scheme: OutboundProxyScheme = .disabled,
        host: String = "",
        port: Int = 0,
        username: String = "",
        password: String = ""
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var isEnabled: Bool {
        self.scheme != .disabled && !self.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && self.port > 0
    }

    private enum CodingKeys: String, CodingKey {
        case scheme
        case host
        case port
        case username
        case password
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scheme: try container.decodeIfPresent(OutboundProxyScheme.self, forKey: .scheme) ?? .disabled,
            host: try container.decodeIfPresent(String.self, forKey: .host) ?? "",
            port: try container.decodeIfPresent(Int.self, forKey: .port) ?? 0,
            username: try container.decodeIfPresent(String.self, forKey: .username) ?? "",
            password: try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        )
    }
}

public struct ManagedProxyConfigSummary: Codable, Sendable, Equatable {
    public static let defaultProviderName = "codex-subscription"
    public static let defaultAutoUpdateIntervalHours = 24
    public static let defaultHealthcheckURL = "http://cp.cloudflare.com/generate_204"
    private static let legacyDefaultHealthcheckURLs: Set<String> = [
        "http://www.google.com/generate_204",
        "https://www.google.com/generate_204",
    ]

    public var subscriptionConfigured: Bool
    public var selectedNodeName: String
    public var providerName: String
    public var autoUpdateIntervalHours: Int
    public var healthcheckURL: String

    public static func migratedHealthcheckURL(_ value: String) -> String {
        self.legacyDefaultHealthcheckURLs.contains(value) ? self.defaultHealthcheckURL : value
    }

    public static func normalizedHealthcheckURL(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = trimmed.isEmpty ? self.defaultHealthcheckURL : trimmed
        return self.migratedHealthcheckURL(normalized)
    }

    public static func validatedHealthcheckURL(_ value: String?) throws -> String {
        let normalized = self.normalizedHealthcheckURL(value)
        guard
            let components = URLComponents(string: normalized),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw ProxyError.message("测速目标 URL 必须是有效的 HTTP 或 HTTPS 绝对 URL。")
        }
        return normalized
    }

    public static func sanitizedHealthcheckURL(_ value: String?) -> String {
        (try? self.validatedHealthcheckURL(value)) ?? self.defaultHealthcheckURL
    }

    public init(
        subscriptionConfigured: Bool = false,
        selectedNodeName: String = "",
        providerName: String = ManagedProxyConfigSummary.defaultProviderName,
        autoUpdateIntervalHours: Int = ManagedProxyConfigSummary.defaultAutoUpdateIntervalHours,
        healthcheckURL: String = ManagedProxyConfigSummary.defaultHealthcheckURL
    ) {
        self.subscriptionConfigured = subscriptionConfigured
        self.selectedNodeName = selectedNodeName
        self.providerName = providerName
        self.autoUpdateIntervalHours = autoUpdateIntervalHours
        self.healthcheckURL = ManagedProxyConfigSummary.sanitizedHealthcheckURL(healthcheckURL)
    }

    enum CodingKeys: String, CodingKey {
        case subscriptionConfigured
        case selectedNodeName
        case providerName
        case autoUpdateIntervalHours
        case healthcheckURL = "healthcheckUrl"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            subscriptionConfigured: try container.decodeIfPresent(Bool.self, forKey: .subscriptionConfigured) ?? false,
            selectedNodeName: try container.decodeIfPresent(String.self, forKey: .selectedNodeName) ?? "",
            providerName: try container.decodeIfPresent(String.self, forKey: .providerName)
                ?? ManagedProxyConfigSummary.defaultProviderName,
            autoUpdateIntervalHours: try container.decodeIfPresent(Int.self, forKey: .autoUpdateIntervalHours)
                ?? ManagedProxyConfigSummary.defaultAutoUpdateIntervalHours,
            healthcheckURL: try container.decodeIfPresent(String.self, forKey: .healthcheckURL)
                ?? ManagedProxyConfigSummary.defaultHealthcheckURL
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.subscriptionConfigured, forKey: .subscriptionConfigured)
        try container.encode(self.selectedNodeName, forKey: .selectedNodeName)
        try container.encode(self.providerName, forKey: .providerName)
        try container.encode(self.autoUpdateIntervalHours, forKey: .autoUpdateIntervalHours)
        try container.encode(self.healthcheckURL, forKey: .healthcheckURL)
    }
}

public enum WindowCloseBehavior: String, Codable, Sendable {
    case hideToMenuBar
    case quit
}

public enum AccountProviderFamily: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case openAI = "openai"
    case anthropic
    case gemini
}

public enum ProxyDataSource: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case all
    case openAI = "openai"
    case anthropic
    case gemini

    public var isWildcard: Bool {
        self == .all
    }

    public func allows(providerFamily: AccountProviderFamily) -> Bool {
        switch self {
        case .all:
            return true
        case .openAI:
            return providerFamily == .openAI
        case .anthropic:
            return providerFamily == .anthropic
        case .gemini:
            return providerFamily == .gemini
        }
    }
}

public struct RemoteHostConfig: Codable, Sendable, Identifiable, Hashable {
    public enum AuthMode: String, Codable, Sendable, CaseIterable {
        case sshKeyPath
        case sshKeyContent
        case password
    }

    public var id: String
    public var label: String
    public var host: String
    public var sshPort: Int
    public var sshUser: String
    public var authMode: AuthMode
    public var identityFile: String
    public var privateKey: String
    public var password: String
    public var remoteDirectory: String
    public var publicPort: Int
    public var adminPort: Int

    public init(
        id: String = UUID().uuidString,
        label: String = "",
        host: String = "",
        sshPort: Int = 22,
        sshUser: String = "root",
        authMode: AuthMode = .sshKeyPath,
        identityFile: String = "",
        privateKey: String = "",
        password: String = "",
        remoteDirectory: String = "/opt/codex-proxy",
        publicPort: Int = 8787,
        adminPort: Int = 8788
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.sshPort = sshPort
        self.sshUser = sshUser
        self.authMode = authMode
        self.identityFile = identityFile
        self.privateKey = privateKey
        self.password = password
        self.remoteDirectory = remoteDirectory
        self.publicPort = publicPort
        self.adminPort = adminPort
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case host
        case sshPort
        case sshUser
        case authMode
        case identityFile
        case privateKey
        case password
        case remoteDirectory
        case publicPort
        case adminPort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            host: try container.decodeIfPresent(String.self, forKey: .host) ?? "",
            sshPort: try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22,
            sshUser: try container.decodeIfPresent(String.self, forKey: .sshUser) ?? "root",
            authMode: try container.decodeIfPresent(AuthMode.self, forKey: .authMode) ?? .sshKeyPath,
            identityFile: try container.decodeIfPresent(String.self, forKey: .identityFile) ?? "",
            privateKey: try container.decodeIfPresent(String.self, forKey: .privateKey) ?? "",
            password: try container.decodeIfPresent(String.self, forKey: .password) ?? "",
            remoteDirectory: try container.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? "/opt/codex-proxy",
            publicPort: try container.decodeIfPresent(Int.self, forKey: .publicPort) ?? 8787,
            adminPort: try container.decodeIfPresent(Int.self, forKey: .adminPort) ?? 8788
        )
    }
}

public struct ProxyAPIKeyRecord: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var label: String
    public var key: String
    public var dataSource: ProxyDataSource
    public var allowedAccountKeys: [String]
    public var enabled: Bool
    public var createdAt: Int64

    public init(
        id: String = UUID().uuidString,
        label: String = "",
        key: String = "",
        dataSource: ProxyDataSource = .openAI,
        allowedAccountKeys: [String] = [],
        enabled: Bool = true,
        createdAt: Int64 = Helpers.now()
    ) {
        self.id = id
        self.label = label
        self.key = key
        self.dataSource = dataSource
        self.allowedAccountKeys = Self.normalizedAllowedAccountKeys(allowedAccountKeys)
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public static func normalizedAllowedAccountKeys(_ keys: [String]) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for rawKey in keys {
            let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedKey.isEmpty == false else { continue }
            guard seen.insert(trimmedKey).inserted else { continue }
            normalized.append(trimmedKey)
        }

        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case key
        case dataSource
        case allowedAccountKeys
        case enabled
        case createdAt
        case createdAtUnix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            key: try container.decodeIfPresent(String.self, forKey: .key) ?? "",
            dataSource: try container.decodeIfPresent(ProxyDataSource.self, forKey: .dataSource) ?? .openAI,
            allowedAccountKeys: try container.decodeIfPresent([String].self, forKey: .allowedAccountKeys) ?? [],
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            createdAt: try container.decodeIfPresent(Int64.self, forKey: .createdAt)
                ?? container.decodeIfPresent(Int64.self, forKey: .createdAtUnix)
                ?? Helpers.now()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.key, forKey: .key)
        try container.encode(self.dataSource, forKey: .dataSource)
        try container.encode(self.allowedAccountKeys, forKey: .allowedAccountKeys)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}

public struct GeminiOAuthConfig: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String = "", clientSecret: String = "") {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case clientIDLegacy = "clientID"
        case clientIDSnake = "client_id"
        case clientSecret
        case clientSecretSnake = "client_secret"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientID: try container.decodeIfPresent(String.self, forKey: .clientID)
                ?? container.decodeIfPresent(String.self, forKey: .clientIDLegacy)
                ?? container.decodeIfPresent(String.self, forKey: .clientIDSnake)
                ?? "",
            clientSecret: try container.decodeIfPresent(String.self, forKey: .clientSecret)
                ?? container.decodeIfPresent(String.self, forKey: .clientSecretSnake)
                ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.clientID, forKey: .clientID)
        try container.encode(self.clientSecret, forKey: .clientSecret)
    }
}

public enum OCRModelProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case openAICompatible = "openai_compatible"
    case localMLX = "local_mlx"
}

public struct OnlineOCRModelProfile: Codable, Sendable, Equatable, Identifiable {
    public static let legacyDefaultID = "default"

    public var id: String
    public var label: String
    public var model: String
    public var baseURL: String
    public var apiKey: String

    public init(
        id: String = UUID().uuidString,
        label: String = "",
        model: String = "",
        baseURL: String = OpenAICompatibleUpstream.defaultBaseURL,
        apiKey: String = ""
    ) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = normalizedID.isEmpty ? UUID().uuidString : normalizedID
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = normalizedModel
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmedBaseURL.isEmpty ? OpenAICompatibleUpstream.defaultBaseURL : trimmedBaseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var displayLabel: String {
        if self.label.isEmpty == false {
            return self.label
        }
        if self.model.isEmpty == false {
            return self.model
        }
        return self.id
    }

    public var isReadyForRecognition: Bool {
        self.model.isEmpty == false && self.apiKey.isEmpty == false
    }

    public static func legacyProfile(model: String, baseURL: String, apiKey: String) -> OnlineOCRModelProfile? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModel.isEmpty == false || trimmedAPIKey.isEmpty == false else {
            return nil
        }
        return OnlineOCRModelProfile(
            id: Self.legacyDefaultID,
            label: trimmedModel.isEmpty ? "Default OCR" : trimmedModel,
            model: trimmedModel,
            baseURL: trimmedBaseURL.isEmpty ? OpenAICompatibleUpstream.defaultBaseURL : trimmedBaseURL,
            apiKey: trimmedAPIKey
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case model
        case baseURL
        case baseUrl
        case baseURLSnake = "base_url"
        case apiKey
        case apiKeySnake = "api_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? container.decodeIfPresent(String.self, forKey: .baseUrl)
                ?? container.decodeIfPresent(String.self, forKey: .baseURLSnake)
                ?? OpenAICompatibleUpstream.defaultBaseURL,
            apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey)
                ?? container.decodeIfPresent(String.self, forKey: .apiKeySnake)
                ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.model, forKey: .model)
        try container.encode(self.baseURL, forKey: .baseURL)
        try container.encode(self.apiKey, forKey: .apiKey)
    }
}

public struct LocalMLXOCRConfig: Codable, Sendable, Equatable {
    public static let defaultSelectedModelID = "mlx-community/Qwen3-VL-4B-Instruct-4bit"
    public static let defaultMaxTokens = 1_024
    public static let defaultIdleShutdownSeconds = 60
    public static let defaultMaxConcurrentRecognitions = 1

    public var selectedModelID: String
    public var customHFRepo: String
    public var modelCachePath: String
    public var hfBaseURL: String
    public var hfToken: String
    public var runtimePath: String
    public var autoStart: Bool
    public var maxTokens: Int
    public var idleShutdownSeconds: Int
    public var maxConcurrentRecognitions: Int

    public init(
        selectedModelID: String = Self.defaultSelectedModelID,
        customHFRepo: String = "",
        modelCachePath: String = "",
        hfBaseURL: String = "https://huggingface.co",
        hfToken: String = "",
        runtimePath: String = "",
        autoStart: Bool = true,
        maxTokens: Int = Self.defaultMaxTokens,
        idleShutdownSeconds: Int = Self.defaultIdleShutdownSeconds,
        maxConcurrentRecognitions: Int = Self.defaultMaxConcurrentRecognitions
    ) {
        self.selectedModelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.customHFRepo = customHFRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelCachePath = modelCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hfBaseURL = hfBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://huggingface.co"
            : hfBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hfToken = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtimePath = runtimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.autoStart = autoStart
        self.maxTokens = max(maxTokens, 128)
        self.idleShutdownSeconds = max(idleShutdownSeconds, 0)
        self.maxConcurrentRecognitions = min(max(maxConcurrentRecognitions, 1), 8)
    }

    public var selectedModelIsCustom: Bool {
        self.selectedModelID == LocalOCRModelDescriptor.customModelID
    }

    public func effectiveModelID() -> String {
        let trimmedSelected = self.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSelected == LocalOCRModelDescriptor.customModelID {
            return self.customHFRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmedSelected
    }

    public func effectiveCacheDirectory(dataDirectory: URL) -> URL {
        let trimmed = self.modelCachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return Paths.localOCRModelsDirectoryURL(in: dataDirectory)
        }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true)
    }

    private enum CodingKeys: String, CodingKey {
        case selectedModelID = "selectedModelId"
        case selectedModelIDLegacy = "selectedModelID"
        case selectedModelIDSnake = "selected_model_id"
        case customHFRepo = "customHFRepo"
        case customHfRepo = "customHfRepo"
        case customHFRepoLegacy = "customHFRepository"
        case customHFRepoSnake = "custom_hf_repo"
        case modelCachePath
        case modelCachePathSnake = "model_cache_path"
        case hfBaseURL = "hfBaseURL"
        case hfBaseUrl = "hfBaseUrl"
        case hfBaseURLSnake = "hf_base_url"
        case hfToken
        case hfTokenSnake = "hf_token"
        case runtimePath
        case runtimePathSnake = "runtime_path"
        case autoStart
        case autoStartSnake = "auto_start"
        case maxTokens
        case maxTokensSnake = "max_tokens"
        case idleShutdownSeconds
        case idleShutdownSecondsSnake = "idle_shutdown_seconds"
        case maxConcurrentRecognitions
        case maxConcurrentRecognitionsSnake = "max_concurrent_recognitions"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedModelID: try container.decodeIfPresent(String.self, forKey: .selectedModelID)
                ?? container.decodeIfPresent(String.self, forKey: .selectedModelIDLegacy)
                ?? container.decodeIfPresent(String.self, forKey: .selectedModelIDSnake)
                ?? Self.defaultSelectedModelID,
            customHFRepo: try container.decodeIfPresent(String.self, forKey: .customHFRepo)
                ?? container.decodeIfPresent(String.self, forKey: .customHfRepo)
                ?? container.decodeIfPresent(String.self, forKey: .customHFRepoLegacy)
                ?? container.decodeIfPresent(String.self, forKey: .customHFRepoSnake)
                ?? "",
            modelCachePath: try container.decodeIfPresent(String.self, forKey: .modelCachePath)
                ?? container.decodeIfPresent(String.self, forKey: .modelCachePathSnake)
                ?? "",
            hfBaseURL: try container.decodeIfPresent(String.self, forKey: .hfBaseURL)
                ?? container.decodeIfPresent(String.self, forKey: .hfBaseUrl)
                ?? container.decodeIfPresent(String.self, forKey: .hfBaseURLSnake)
                ?? "https://huggingface.co",
            hfToken: try container.decodeIfPresent(String.self, forKey: .hfToken)
                ?? container.decodeIfPresent(String.self, forKey: .hfTokenSnake)
                ?? "",
            runtimePath: try container.decodeIfPresent(String.self, forKey: .runtimePath)
                ?? container.decodeIfPresent(String.self, forKey: .runtimePathSnake)
                ?? "",
            autoStart: try container.decodeIfPresent(Bool.self, forKey: .autoStart)
                ?? container.decodeIfPresent(Bool.self, forKey: .autoStartSnake)
                ?? true,
            maxTokens: try container.decodeIfPresent(Int.self, forKey: .maxTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .maxTokensSnake)
                ?? Self.defaultMaxTokens,
            idleShutdownSeconds: try container.decodeIfPresent(Int.self, forKey: .idleShutdownSeconds)
                ?? container.decodeIfPresent(Int.self, forKey: .idleShutdownSecondsSnake)
                ?? Self.defaultIdleShutdownSeconds,
            maxConcurrentRecognitions: try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRecognitions)
                ?? container.decodeIfPresent(Int.self, forKey: .maxConcurrentRecognitionsSnake)
                ?? Self.defaultMaxConcurrentRecognitions
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.selectedModelID, forKey: .selectedModelID)
        try container.encode(self.customHFRepo, forKey: .customHFRepo)
        try container.encode(self.modelCachePath, forKey: .modelCachePath)
        try container.encode(self.hfBaseURL, forKey: .hfBaseURL)
        try container.encode(self.hfToken, forKey: .hfToken)
        try container.encode(self.runtimePath, forKey: .runtimePath)
        try container.encode(self.autoStart, forKey: .autoStart)
        try container.encode(self.maxTokens, forKey: .maxTokens)
        try container.encode(self.idleShutdownSeconds, forKey: .idleShutdownSeconds)
        try container.encode(self.maxConcurrentRecognitions, forKey: .maxConcurrentRecognitions)
    }
}

public struct LocalOCRModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public static let customModelID = "__custom_hf_repo__"

    public var id: String
    public var displayName: String
    public var huggingFaceRepo: String
    public var snapshotDirectoryName: String
    public var sizeBytes: Int64
    public var quantization: String
    public var minimumMemoryGB: Int
    public var licenseName: String
    public var licenseURL: String
    public var recommended: Bool
    public var experimental: Bool
    public var notes: String

    public init(
        id: String,
        displayName: String,
        huggingFaceRepo: String,
        snapshotDirectoryName: String? = nil,
        sizeBytes: Int64,
        quantization: String,
        minimumMemoryGB: Int,
        licenseName: String,
        licenseURL: String,
        recommended: Bool = false,
        experimental: Bool = false,
        notes: String = ""
    ) {
        let repo = huggingFaceRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.huggingFaceRepo = repo
        self.snapshotDirectoryName = (snapshotDirectoryName ?? Self.defaultSnapshotDirectoryName(for: repo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.sizeBytes = max(0, sizeBytes)
        self.quantization = quantization.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minimumMemoryGB = max(0, minimumMemoryGB)
        self.licenseName = licenseName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.licenseURL = licenseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recommended = recommended
        self.experimental = experimental
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case huggingFaceRepo
        case snapshotDirectoryName
        case sizeBytes
        case quantization
        case minimumMemoryGB = "minimumMemoryGb"
        case minimumMemoryGBLegacy = "minimumMemoryGB"
        case minimumMemoryGBSnake = "minimum_memory_gb"
        case licenseName
        case licenseURL = "licenseUrl"
        case licenseURLLegacy = "licenseURL"
        case licenseURLSnake = "license_url"
        case recommended
        case experimental
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName) ?? "",
            huggingFaceRepo: try container.decodeIfPresent(String.self, forKey: .huggingFaceRepo) ?? "",
            snapshotDirectoryName: try container.decodeIfPresent(String.self, forKey: .snapshotDirectoryName),
            sizeBytes: try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0,
            quantization: try container.decodeIfPresent(String.self, forKey: .quantization) ?? "",
            minimumMemoryGB: try container.decodeIfPresent(Int.self, forKey: .minimumMemoryGB)
                ?? container.decodeIfPresent(Int.self, forKey: .minimumMemoryGBLegacy)
                ?? container.decodeIfPresent(Int.self, forKey: .minimumMemoryGBSnake)
                ?? 0,
            licenseName: try container.decodeIfPresent(String.self, forKey: .licenseName) ?? "",
            licenseURL: try container.decodeIfPresent(String.self, forKey: .licenseURL)
                ?? container.decodeIfPresent(String.self, forKey: .licenseURLLegacy)
                ?? container.decodeIfPresent(String.self, forKey: .licenseURLSnake)
                ?? "",
            recommended: try container.decodeIfPresent(Bool.self, forKey: .recommended) ?? false,
            experimental: try container.decodeIfPresent(Bool.self, forKey: .experimental) ?? false,
            notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.displayName, forKey: .displayName)
        try container.encode(self.huggingFaceRepo, forKey: .huggingFaceRepo)
        try container.encode(self.snapshotDirectoryName, forKey: .snapshotDirectoryName)
        try container.encode(self.sizeBytes, forKey: .sizeBytes)
        try container.encode(self.quantization, forKey: .quantization)
        try container.encode(self.minimumMemoryGB, forKey: .minimumMemoryGB)
        try container.encode(self.licenseName, forKey: .licenseName)
        try container.encode(self.licenseURL, forKey: .licenseURL)
        try container.encode(self.recommended, forKey: .recommended)
        try container.encode(self.experimental, forKey: .experimental)
        try container.encode(self.notes, forKey: .notes)
    }

    public static let recommendedModels: [LocalOCRModelDescriptor] = [
        .init(
            id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen3-VL 4B Instruct 4bit",
            huggingFaceRepo: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            sizeBytes: 3_200_000_000,
            quantization: "4bit",
            minimumMemoryGB: 8,
            licenseName: "Qwen License",
            licenseURL: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit",
            recommended: true,
            notes: "默认推荐，适合截图 OCR 与结构化图片理解。"
        ),
        .init(
            id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            displayName: "Qwen2.5-VL 3B Instruct 4bit",
            huggingFaceRepo: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            sizeBytes: 2_500_000_000,
            quantization: "4bit",
            minimumMemoryGB: 8,
            licenseName: "Qwen License",
            licenseURL: "https://huggingface.co/mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            notes: "轻量备选，速度更快。"
        ),
        .init(
            id: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
            displayName: "Qwen2.5-VL 7B Instruct 4bit",
            huggingFaceRepo: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
            sizeBytes: 5_300_000_000,
            quantization: "4bit",
            minimumMemoryGB: 16,
            licenseName: "Qwen License",
            licenseURL: "https://huggingface.co/mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
            notes: "质量备选，占用更高。"
        ),
        .init(
            id: "FakeRockert543/gemma-4-e2b-it-MLX-4bit",
            displayName: "Gemma 4 E2B Instruct MLX 4bit",
            huggingFaceRepo: "FakeRockert543/gemma-4-e2b-it-MLX-4bit",
            snapshotDirectoryName: "gemma-4-e2b-it-mlx-ple-safe-4bit",
            sizeBytes: 7_000_000_000,
            quantization: "PLE-safe 4bit",
            minimumMemoryGB: 8,
            licenseName: "Gemma Terms of Use",
            licenseURL: "https://ai.google.dev/gemma/terms",
            notes: "Gemma 4 备选，沿用 TrustLens 的 PLE-safe MLX 转换。"
        ),
        .init(
            id: "FakeRockert543/gemma-4-e4b-it-MLX-4bit",
            displayName: "Gemma 4 E4B Instruct MLX 4bit",
            huggingFaceRepo: "FakeRockert543/gemma-4-e4b-it-MLX-4bit",
            snapshotDirectoryName: "gemma-4-e4b-it-mlx-ple-safe-4bit",
            sizeBytes: 12_000_000_000,
            quantization: "PLE-safe 4bit",
            minimumMemoryGB: 16,
            licenseName: "Gemma Terms of Use",
            licenseURL: "https://ai.google.dev/gemma/terms",
            notes: "更高质量 Gemma 4 备选。"
        ),
        .init(
            id: "mlx-community/DeepSeek-OCR-4bit",
            displayName: "DeepSeek OCR 4bit (Experimental)",
            huggingFaceRepo: "mlx-community/DeepSeek-OCR-4bit",
            sizeBytes: 3_000_000_000,
            quantization: "4bit",
            minimumMemoryGB: 8,
            licenseName: "DeepSeek License",
            licenseURL: "https://huggingface.co/deepseek-ai/DeepSeek-OCR-2",
            experimental: true,
            notes: "实验项；DeepSeek-OCR-2 官方形态目前不是首批默认 MLX 一键模型。"
        ),
    ]

    public static func descriptor(id: String, customHFRepo: String = "") -> LocalOCRModelDescriptor? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let descriptor = Self.recommendedModels.first(where: { $0.id == trimmedID }) {
            return descriptor
        }
        if trimmedID == Self.customModelID || trimmedID.isEmpty {
            return Self.customDescriptor(repo: customHFRepo)
        }
        return Self.customDescriptor(repo: trimmedID)
    }

    public static func customDescriptor(repo: String) -> LocalOCRModelDescriptor? {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/"), trimmed.isEmpty == false else { return nil }
        return .init(
            id: Self.customModelID,
            displayName: "Custom HF · \(trimmed)",
            huggingFaceRepo: trimmed,
            sizeBytes: 0,
            quantization: "custom",
            minimumMemoryGB: 0,
            licenseName: "Custom",
            licenseURL: "https://huggingface.co/\(trimmed)",
            experimental: true,
            notes: "用户自定义 Hugging Face MLX/VLM 仓库。"
        )
    }

    public static func defaultSnapshotDirectoryName(for repo: String) -> String {
        repo.lowercased()
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: " ", with: "-")
    }
}

public enum LocalOCRModelInstallPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case notInstalled = "not_installed"
    case downloading
    case installed
    case failed
}

public enum LocalOCRModelCompatibilityStatus: String, Codable, Sendable, Equatable {
    case unknown
    case compatible
    case incomplete
    case incompatible
}

public struct LocalOCRModelStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String { self.descriptor.id }
    public var descriptor: LocalOCRModelDescriptor
    public var phase: LocalOCRModelInstallPhase
    public var progress: Double
    public var detail: String
    public var localPath: String?
    public var compatibility: LocalOCRModelCompatibilityStatus
    public var checkedAt: Int64

    public init(
        descriptor: LocalOCRModelDescriptor,
        phase: LocalOCRModelInstallPhase,
        progress: Double = 0,
        detail: String = "",
        localPath: String? = nil,
        compatibility: LocalOCRModelCompatibilityStatus = .unknown,
        checkedAt: Int64 = Helpers.now()
    ) {
        self.descriptor = descriptor
        self.phase = phase
        self.progress = min(max(progress, 0), 1)
        self.detail = detail
        self.localPath = localPath
        self.compatibility = compatibility
        self.checkedAt = checkedAt
    }
}

public struct LocalMLXOCRRuntimeStatus: Codable, Sendable, Equatable {
    public var running: Bool
    public var modelID: String?
    public var endpoint: String?
    public var detail: String

    public init(running: Bool = false, modelID: String? = nil, endpoint: String? = nil, detail: String = "") {
        self.running = running
        self.modelID = modelID
        self.endpoint = endpoint
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case running
        case modelID = "modelId"
        case modelIDLegacy = "modelID"
        case modelIDSnake = "model_id"
        case endpoint
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            running: try container.decodeIfPresent(Bool.self, forKey: .running) ?? false,
            modelID: try container.decodeIfPresent(String.self, forKey: .modelID)
                ?? container.decodeIfPresent(String.self, forKey: .modelIDLegacy)
                ?? container.decodeIfPresent(String.self, forKey: .modelIDSnake),
            endpoint: try container.decodeIfPresent(String.self, forKey: .endpoint),
            detail: try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.running, forKey: .running)
        try container.encodeIfPresent(self.modelID, forKey: .modelID)
        try container.encodeIfPresent(self.endpoint, forKey: .endpoint)
        try container.encode(self.detail, forKey: .detail)
    }
}

public struct LocalOCRModelsResponse: Codable, Sendable, Equatable {
    public var selectedModelID: String
    public var customHFRepo: String
    public var models: [LocalOCRModelStatus]
    public var runtime: LocalMLXOCRRuntimeStatus

    public init(
        selectedModelID: String = LocalMLXOCRConfig.defaultSelectedModelID,
        customHFRepo: String = "",
        models: [LocalOCRModelStatus] = [],
        runtime: LocalMLXOCRRuntimeStatus = .init()
    ) {
        self.selectedModelID = selectedModelID
        self.customHFRepo = customHFRepo
        self.models = models
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case selectedModelID = "selectedModelId"
        case selectedModelIDLegacy = "selectedModelID"
        case selectedModelIDSnake = "selected_model_id"
        case customHFRepo = "customHFRepo"
        case customHfRepo = "customHfRepo"
        case customHFRepoSnake = "custom_hf_repo"
        case models
        case runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedModelID: try container.decodeIfPresent(String.self, forKey: .selectedModelID)
                ?? container.decodeIfPresent(String.self, forKey: .selectedModelIDLegacy)
                ?? container.decodeIfPresent(String.self, forKey: .selectedModelIDSnake)
                ?? LocalMLXOCRConfig.defaultSelectedModelID,
            customHFRepo: try container.decodeIfPresent(String.self, forKey: .customHFRepo)
                ?? container.decodeIfPresent(String.self, forKey: .customHfRepo)
                ?? container.decodeIfPresent(String.self, forKey: .customHFRepoSnake)
                ?? "",
            models: try container.decodeIfPresent([LocalOCRModelStatus].self, forKey: .models) ?? [],
            runtime: try container.decodeIfPresent(LocalMLXOCRRuntimeStatus.self, forKey: .runtime) ?? .init()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.selectedModelID, forKey: .selectedModelID)
        try container.encode(self.customHFRepo, forKey: .customHFRepo)
        try container.encode(self.models, forKey: .models)
        try container.encode(self.runtime, forKey: .runtime)
    }
}

public struct LocalOCRModelActionResult: Codable, Sendable, Equatable {
    public var status: LocalOCRModelStatus
    public var models: LocalOCRModelsResponse

    public init(status: LocalOCRModelStatus, models: LocalOCRModelsResponse) {
        self.status = status
        self.models = models
    }
}

public struct OCRModelConfig: Codable, Sendable, Equatable {
    public static let defaultPrompt = """
    你是一个专业的图片内容识别助手。

    你的任务：
    准确提取图片中的所有关键信息，并输出适合大模型理解的结构化文本。

    要求：

    1. 描述图片主体内容
    2. 如果图片中有文字，需要完整提取
    3. 如果是代码截图，需要保留代码结构
    4. 如果是报错截图，需要重点提取：

       * 错误信息
       * 文件名
       * 行号
       * 调用栈
    5. 如果是界面截图，需要描述：

       * 页面结构
       * 按钮
       * 输入框
       * 状态提示
    6. 不要输出“可能”“猜测”等模糊描述
    7. 使用简洁、结构化输出
    8. 不要遗漏细节
    9. 输出必须适合作为大模型上下文

    输出格式：

    [OCR识别结果]
    图片类型：
    主要内容：
    文字内容：
    关键细节：
    结构化信息：
    """

    public var provider: OCRModelProvider
    public var model: String
    public var apiKey: String
    public var baseURL: String
    public var prompt: String
    public var timeout: Int
    public var maxImageSize: Int
    public var enabled: Bool
    public var debugMode: Bool
    public var localMLX: LocalMLXOCRConfig
    public var onlineProfiles: [OnlineOCRModelProfile]
    public var selectedOnlineProfileID: String

    public init(
        provider: OCRModelProvider = .openAICompatible,
        model: String = "",
        apiKey: String = "",
        baseURL: String = OpenAICompatibleUpstream.defaultBaseURL,
        prompt: String = OCRModelConfig.defaultPrompt,
        timeout: Int = 60,
        maxImageSize: Int = 4 * 1024 * 1024,
        enabled: Bool = false,
        debugMode: Bool = false,
        localMLX: LocalMLXOCRConfig = .init(),
        onlineProfiles: [OnlineOCRModelProfile] = [],
        selectedOnlineProfileID: String = ""
    ) {
        self.provider = provider
        let legacyModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalizedProfiles: [OnlineOCRModelProfile] = []
        var seenProfileIDs = Set<String>()
        for profile in onlineProfiles {
            guard seenProfileIDs.insert(profile.id).inserted else { continue }
            normalizedProfiles.append(profile)
        }
        if normalizedProfiles.isEmpty,
           let legacyProfile = OnlineOCRModelProfile.legacyProfile(
            model: legacyModel,
            baseURL: legacyBaseURL,
            apiKey: legacyAPIKey
           )
        {
            normalizedProfiles.append(legacyProfile)
        }
        let normalizedSelectedOnlineProfileID = selectedOnlineProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedProfile = normalizedProfiles.first { $0.id == normalizedSelectedOnlineProfileID }
            ?? normalizedProfiles.first
        self.model = selectedProfile?.model ?? legacyModel
        self.apiKey = selectedProfile?.apiKey ?? legacyAPIKey
        self.baseURL = selectedProfile?.baseURL ?? legacyBaseURL
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = trimmedPrompt.isEmpty ? Self.defaultPrompt : trimmedPrompt
        self.timeout = max(timeout, 1)
        self.maxImageSize = max(maxImageSize, 64 * 1024)
        self.enabled = enabled
        self.debugMode = debugMode
        self.localMLX = localMLX
        self.onlineProfiles = normalizedProfiles
        self.selectedOnlineProfileID = selectedProfile?.id ?? normalizedSelectedOnlineProfileID
    }

    public var isReadyForRecognition: Bool {
        guard self.enabled else { return false }
        switch self.provider {
        case .openAICompatible:
            return self.effectiveOnlineProfile?.isReadyForRecognition == true
        case .localMLX:
            return self.localMLX.effectiveModelID().isEmpty == false
        }
    }

    public var recognitionModelLabel: String {
        switch self.provider {
        case .openAICompatible:
            return self.effectiveOnlineProfile?.displayLabel ?? self.model
        case .localMLX:
            return "Local MLX · \(self.localMLX.effectiveModelID())"
        }
    }

    public var effectiveOnlineProfile: OnlineOCRModelProfile? {
        if let selected = self.onlineProfiles.first(where: { $0.id == self.selectedOnlineProfileID }) {
            return selected
        }
        if let first = self.onlineProfiles.first {
            return first
        }
        return OnlineOCRModelProfile.legacyProfile(model: self.model, baseURL: self.baseURL, apiKey: self.apiKey)
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case model
        case apiKey
        case apiKeySnake = "api_key"
        case baseURL
        case baseUrl
        case baseURLSnake = "base_url"
        case prompt
        case timeout
        case maxImageSize
        case maxImageSizeSnake = "max_image_size"
        case enabled
        case debugMode
        case debugModeSnake = "debug_mode"
        case localMLX
        case localMlx
        case localMLXSnake = "local_mlx"
        case onlineProfiles
        case onlineProfilesSnake = "online_profiles"
        case selectedOnlineProfileID = "selectedOnlineProfileId"
        case selectedOnlineProfileIDLegacy = "selectedOnlineProfileID"
        case selectedOnlineProfileIDSnake = "selected_online_profile_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decodeIfPresent(OCRModelProvider.self, forKey: .provider) ?? .openAICompatible,
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
            apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey)
                ?? container.decodeIfPresent(String.self, forKey: .apiKeySnake)
                ?? "",
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? container.decodeIfPresent(String.self, forKey: .baseUrl)
                ?? container.decodeIfPresent(String.self, forKey: .baseURLSnake)
                ?? OpenAICompatibleUpstream.defaultBaseURL,
            prompt: try container.decodeIfPresent(String.self, forKey: .prompt) ?? Self.defaultPrompt,
            timeout: try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 60,
            maxImageSize: try container.decodeIfPresent(Int.self, forKey: .maxImageSize)
                ?? container.decodeIfPresent(Int.self, forKey: .maxImageSizeSnake)
                ?? 4 * 1024 * 1024,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            debugMode: try container.decodeIfPresent(Bool.self, forKey: .debugMode)
                ?? container.decodeIfPresent(Bool.self, forKey: .debugModeSnake)
                ?? false,
            localMLX: try container.decodeIfPresent(LocalMLXOCRConfig.self, forKey: .localMLX)
                ?? container.decodeIfPresent(LocalMLXOCRConfig.self, forKey: .localMlx)
                ?? container.decodeIfPresent(LocalMLXOCRConfig.self, forKey: .localMLXSnake)
                ?? .init(),
            onlineProfiles: try container.decodeIfPresent([OnlineOCRModelProfile].self, forKey: .onlineProfiles)
                ?? container.decodeIfPresent([OnlineOCRModelProfile].self, forKey: .onlineProfilesSnake)
                ?? [],
            selectedOnlineProfileID: try container.decodeIfPresent(String.self, forKey: .selectedOnlineProfileID)
                ?? container.decodeIfPresent(String.self, forKey: .selectedOnlineProfileIDLegacy)
                ?? container.decodeIfPresent(String.self, forKey: .selectedOnlineProfileIDSnake)
                ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.provider, forKey: .provider)
        let profile = self.effectiveOnlineProfile
        try container.encode(profile?.model ?? self.model, forKey: .model)
        try container.encode(profile?.apiKey ?? self.apiKey, forKey: .apiKey)
        try container.encode(profile?.baseURL ?? self.baseURL, forKey: .baseURL)
        try container.encode(self.prompt, forKey: .prompt)
        try container.encode(self.timeout, forKey: .timeout)
        try container.encode(self.maxImageSize, forKey: .maxImageSize)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.debugMode, forKey: .debugMode)
        try container.encode(self.localMLX, forKey: .localMLX)
        try container.encode(self.onlineProfiles, forKey: .onlineProfiles)
        try container.encode(self.selectedOnlineProfileID, forKey: .selectedOnlineProfileID)
    }
}

public struct AuthenticatedProxyKeyContext: Sendable, Equatable {
    public var apiKeyHash: String
    public var proxyKeyID: String
    public var dataSource: ProxyDataSource
    public var allowedAccountKeys: [String]

    public init(
        apiKeyHash: String,
        proxyKeyID: String,
        dataSource: ProxyDataSource,
        allowedAccountKeys: [String] = []
    ) {
        self.apiKeyHash = apiKeyHash
        self.proxyKeyID = proxyKeyID
        self.dataSource = dataSource
        self.allowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(allowedAccountKeys)
    }
}

public struct DiagnosticRequestBodyCaptureConfig: Codable, Sendable, Equatable {
    public static let defaultRetentionDays = 7
    public static let defaultMaxBodySizeBytes = 20 * 1_024 * 1_024

    public var enabled: Bool
    public var retentionDays: Int
    public var maxBodySizeBytes: Int
    public var captureJSONOnly: Bool

    public init(
        enabled: Bool = false,
        retentionDays: Int = Self.defaultRetentionDays,
        maxBodySizeBytes: Int = Self.defaultMaxBodySizeBytes,
        captureJSONOnly: Bool = true
    ) {
        self.enabled = enabled
        self.retentionDays = min(max(retentionDays, 1), 365)
        self.maxBodySizeBytes = min(max(maxBodySizeBytes, 1_024), 200 * 1_024 * 1_024)
        self.captureJSONOnly = captureJSONOnly
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case retentionDays
        case retentionDaysSnake = "retention_days"
        case maxBodySizeBytes
        case maxBodySizeBytesSnake = "max_body_size_bytes"
        case captureJSONOnly
        case captureJSONOnlyAlt = "captureJsonOnly"
        case captureJSONOnlySnake = "capture_json_only"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            retentionDays: try container.decodeIfPresent(Int.self, forKey: .retentionDays)
                ?? container.decodeIfPresent(Int.self, forKey: .retentionDaysSnake)
                ?? Self.defaultRetentionDays,
            maxBodySizeBytes: try container.decodeIfPresent(Int.self, forKey: .maxBodySizeBytes)
                ?? container.decodeIfPresent(Int.self, forKey: .maxBodySizeBytesSnake)
                ?? Self.defaultMaxBodySizeBytes,
            captureJSONOnly: try container.decodeIfPresent(Bool.self, forKey: .captureJSONOnly)
                ?? container.decodeIfPresent(Bool.self, forKey: .captureJSONOnlyAlt)
                ?? container.decodeIfPresent(Bool.self, forKey: .captureJSONOnlySnake)
                ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.retentionDays, forKey: .retentionDays)
        try container.encode(self.maxBodySizeBytes, forKey: .maxBodySizeBytes)
        try container.encode(self.captureJSONOnly, forKey: .captureJSONOnly)
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public static let defaultAnthropicTargetModel = ProxyTranscoder.defaultModel
    public static let defaultProxyAPIKeyLabel = "Primary"
    public static let defaultAnthropicAccessProxyAPIKeyLabel = "Anthropic Access"

    public var publicHost: String
    public var publicPort: Int
    public var adminPort: Int
    public var autoStart: Bool
    public var outboundProxyMode: OutboundProxyMode
    public var outboundProxy: OutboundProxySettings
    public var managedProxySummary: ManagedProxyConfigSummary
    public var proxyAPIKey: String
    public var proxyAPIKeys: [ProxyAPIKeyRecord]
    public var primaryProxyAPIKeyID: String?
    public var adminToken: String
    public var statsRetentionDays: Int
    public var remoteHosts: [RemoteHostConfig]
    public var windowCloseBehavior: WindowCloseBehavior
    public var chatGPTBaseURL: String
    public var daemonBinaryOverride: String
    public var anthropicDefaultTargetModel: String
    public var anthropicModelMappings: [AnthropicModelMapping]
    public var geminiOAuth: GeminiOAuthConfig
    public var ocrModel: OCRModelConfig
    public var diagnosticRequestBodyCapture: DiagnosticRequestBodyCaptureConfig

    public init(
        publicHost: String = "127.0.0.1",
        publicPort: Int = 8787,
        adminPort: Int = 8788,
        autoStart: Bool = true,
        outboundProxyMode: OutboundProxyMode = .disabled,
        outboundProxy: OutboundProxySettings = .init(),
        managedProxySummary: ManagedProxyConfigSummary = .init(),
        proxyAPIKey: String = "",
        proxyAPIKeys: [ProxyAPIKeyRecord] = [],
        primaryProxyAPIKeyID: String? = nil,
        adminToken: String = "",
        statsRetentionDays: Int = 90,
        remoteHosts: [RemoteHostConfig] = [],
        windowCloseBehavior: WindowCloseBehavior = .hideToMenuBar,
        chatGPTBaseURL: String = "https://chatgpt.com",
        daemonBinaryOverride: String = "",
        anthropicDefaultTargetModel: String = AppConfig.defaultAnthropicTargetModel,
        anthropicModelMappings: [AnthropicModelMapping] = [],
        geminiOAuth: GeminiOAuthConfig = .init(),
        ocrModel: OCRModelConfig = .init(),
        diagnosticRequestBodyCapture: DiagnosticRequestBodyCaptureConfig = .init()
    ) {
        self.publicHost = publicHost
        self.publicPort = publicPort
        self.adminPort = adminPort
        self.autoStart = autoStart
        self.outboundProxyMode = outboundProxyMode
        self.outboundProxy = outboundProxy
        self.managedProxySummary = managedProxySummary
        self.proxyAPIKey = proxyAPIKey
        self.proxyAPIKeys = proxyAPIKeys
        self.primaryProxyAPIKeyID = primaryProxyAPIKeyID
        self.adminToken = adminToken
        self.statsRetentionDays = statsRetentionDays
        self.remoteHosts = remoteHosts
        self.windowCloseBehavior = windowCloseBehavior
        self.chatGPTBaseURL = chatGPTBaseURL
        self.daemonBinaryOverride = daemonBinaryOverride
        self.anthropicDefaultTargetModel = anthropicDefaultTargetModel
        self.anthropicModelMappings = anthropicModelMappings
        self.geminiOAuth = geminiOAuth
        self.ocrModel = ocrModel
        self.diagnosticRequestBodyCapture = diagnosticRequestBodyCapture
    }

    private enum CodingKeys: String, CodingKey {
        case publicHost
        case publicPort
        case adminPort
        case autoStart
        case outboundProxyMode
        case outboundProxy
        case managedProxySummary
        case proxyAPIKey = "proxyApiKey"
        case proxyAPIKeys = "proxyApiKeys"
        case primaryProxyAPIKeyID = "primaryProxyApiKeyId"
        case adminToken
        case statsRetentionDays
        case remoteHosts
        case windowCloseBehavior
        case chatGPTBaseURL = "chatGptBaseUrl"
        case daemonBinaryOverride
        case anthropicDefaultTargetModel
        case anthropicModelMappings
        case geminiOAuth
        case geminiOauth
        case geminiOAuthSnake = "gemini_oauth"
        case ocrModel
        case ocrModelSnake = "ocr_model"
        case diagnosticRequestBodyCapture
        case diagnosticRequestBodyCaptureSnake = "diagnostic_request_body_capture"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outboundProxy = try container.decodeIfPresent(OutboundProxySettings.self, forKey: .outboundProxy) ?? .init()
        let outboundProxyMode = try container.decodeIfPresent(OutboundProxyMode.self, forKey: .outboundProxyMode)
            ?? (outboundProxy.isEnabled ? .manual : .disabled)
        self.init(
            publicHost: try container.decodeIfPresent(String.self, forKey: .publicHost) ?? "127.0.0.1",
            publicPort: try container.decodeIfPresent(Int.self, forKey: .publicPort) ?? 8787,
            adminPort: try container.decodeIfPresent(Int.self, forKey: .adminPort) ?? 8788,
            autoStart: try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true,
            outboundProxyMode: outboundProxyMode,
            outboundProxy: outboundProxy,
            managedProxySummary: try container.decodeIfPresent(ManagedProxyConfigSummary.self, forKey: .managedProxySummary) ?? .init(),
            proxyAPIKey: try container.decodeIfPresent(String.self, forKey: .proxyAPIKey) ?? "",
            proxyAPIKeys: try container.decodeIfPresent([ProxyAPIKeyRecord].self, forKey: .proxyAPIKeys) ?? [],
            primaryProxyAPIKeyID: try container.decodeIfPresent(String.self, forKey: .primaryProxyAPIKeyID),
            adminToken: try container.decodeIfPresent(String.self, forKey: .adminToken) ?? "",
            statsRetentionDays: try container.decodeIfPresent(Int.self, forKey: .statsRetentionDays) ?? 90,
            remoteHosts: try container.decodeIfPresent([RemoteHostConfig].self, forKey: .remoteHosts) ?? [],
            windowCloseBehavior: try container.decodeIfPresent(WindowCloseBehavior.self, forKey: .windowCloseBehavior) ?? .hideToMenuBar,
            chatGPTBaseURL: try container.decodeIfPresent(String.self, forKey: .chatGPTBaseURL) ?? "https://chatgpt.com",
            daemonBinaryOverride: try container.decodeIfPresent(String.self, forKey: .daemonBinaryOverride) ?? "",
            anthropicDefaultTargetModel: try container.decodeIfPresent(String.self, forKey: .anthropicDefaultTargetModel) ?? Self.defaultAnthropicTargetModel,
            anthropicModelMappings: try container.decodeIfPresent([AnthropicModelMapping].self, forKey: .anthropicModelMappings) ?? [],
            geminiOAuth: try container.decodeIfPresent(GeminiOAuthConfig.self, forKey: .geminiOAuth)
                ?? container.decodeIfPresent(GeminiOAuthConfig.self, forKey: .geminiOauth)
                ?? container.decodeIfPresent(GeminiOAuthConfig.self, forKey: .geminiOAuthSnake)
                ?? .init(),
            ocrModel: try container.decodeIfPresent(OCRModelConfig.self, forKey: .ocrModel)
                ?? container.decodeIfPresent(OCRModelConfig.self, forKey: .ocrModelSnake)
                ?? .init(),
            diagnosticRequestBodyCapture: try container.decodeIfPresent(
                DiagnosticRequestBodyCaptureConfig.self,
                forKey: .diagnosticRequestBodyCapture
            )
                ?? container.decodeIfPresent(
                    DiagnosticRequestBodyCaptureConfig.self,
                    forKey: .diagnosticRequestBodyCaptureSnake
                )
                ?? .init()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.publicHost, forKey: .publicHost)
        try container.encode(self.publicPort, forKey: .publicPort)
        try container.encode(self.adminPort, forKey: .adminPort)
        try container.encode(self.autoStart, forKey: .autoStart)
        try container.encode(self.outboundProxyMode, forKey: .outboundProxyMode)
        try container.encode(self.outboundProxy, forKey: .outboundProxy)
        try container.encode(self.managedProxySummary, forKey: .managedProxySummary)
        try container.encode(self.proxyAPIKey, forKey: .proxyAPIKey)
        try container.encode(self.proxyAPIKeys, forKey: .proxyAPIKeys)
        try container.encodeIfPresent(self.primaryProxyAPIKeyID, forKey: .primaryProxyAPIKeyID)
        try container.encode(self.adminToken, forKey: .adminToken)
        try container.encode(self.statsRetentionDays, forKey: .statsRetentionDays)
        try container.encode(self.remoteHosts, forKey: .remoteHosts)
        try container.encode(self.windowCloseBehavior, forKey: .windowCloseBehavior)
        try container.encode(self.chatGPTBaseURL, forKey: .chatGPTBaseURL)
        try container.encode(self.daemonBinaryOverride, forKey: .daemonBinaryOverride)
        try container.encode(self.anthropicDefaultTargetModel, forKey: .anthropicDefaultTargetModel)
        try container.encode(self.anthropicModelMappings, forKey: .anthropicModelMappings)
        try container.encode(self.geminiOAuth, forKey: .geminiOauth)
        try container.encode(self.ocrModel, forKey: .ocrModel)
        try container.encode(self.diagnosticRequestBodyCapture, forKey: .diagnosticRequestBodyCapture)
    }

    public func normalizedModelRoutingConfig() -> AppConfig {
        let normalizedDefaultTargetModel = Self.normalizedAnthropicTargetModel(self.anthropicDefaultTargetModel)
        let normalizedProxyKeys = Self.normalizedProxyAPIKeys(
            self.proxyAPIKeys,
            legacyProxyAPIKey: self.proxyAPIKey
        )
        let normalizedPrimaryKeyID = Self.normalizedPrimaryProxyAPIKeyID(
            requestedID: self.primaryProxyAPIKeyID,
            proxyAPIKeys: normalizedProxyKeys
        )
        let normalizedPrimaryKey = normalizedProxyKeys.first(where: { $0.id == normalizedPrimaryKeyID })?.key
            ?? normalizedProxyKeys.first?.key
            ?? self.proxyAPIKey
        return AppConfig(
            publicHost: self.publicHost,
            publicPort: self.publicPort,
            adminPort: self.adminPort,
            autoStart: self.autoStart,
            outboundProxyMode: self.outboundProxyMode,
            outboundProxy: self.outboundProxy,
            managedProxySummary: self.managedProxySummary,
            proxyAPIKey: normalizedPrimaryKey,
            proxyAPIKeys: normalizedProxyKeys,
            primaryProxyAPIKeyID: normalizedPrimaryKeyID,
            adminToken: self.adminToken,
            statsRetentionDays: self.statsRetentionDays,
            remoteHosts: self.remoteHosts,
            windowCloseBehavior: self.windowCloseBehavior,
            chatGPTBaseURL: self.chatGPTBaseURL,
            daemonBinaryOverride: self.daemonBinaryOverride,
            anthropicDefaultTargetModel: normalizedDefaultTargetModel,
            anthropicModelMappings: Self.normalizedAnthropicModelMappings(
                self.anthropicModelMappings,
                defaultTargetModel: normalizedDefaultTargetModel
            ),
            geminiOAuth: self.geminiOAuth,
            ocrModel: self.ocrModel,
            diagnosticRequestBodyCapture: self.diagnosticRequestBodyCapture
        )
    }

    public func normalizedAnthropicModelConfig() -> AppConfig {
        self.normalizedModelRoutingConfig()
    }

    public var primaryProxyAPIKeyRecord: ProxyAPIKeyRecord? {
        let normalized = self.normalizedModelRoutingConfig()
        if let primaryProxyAPIKeyID = normalized.primaryProxyAPIKeyID,
           let matched = normalized.proxyAPIKeys.first(where: { $0.id == primaryProxyAPIKeyID })
        {
            return matched
        }
        return normalized.proxyAPIKeys.first
    }

    public var enabledProxyAPIKeys: [ProxyAPIKeyRecord] {
        self.normalizedModelRoutingConfig().proxyAPIKeys.filter(\.enabled)
    }

    public static func generatedProxyAPIKey() -> String {
        "sk-local-" + Helpers.randomToken(length: 36)
    }

    private static func normalizedAnthropicTargetModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultAnthropicTargetModel : trimmed
    }

    private static func normalizedAnthropicModelMappings(
        _ mappings: [AnthropicModelMapping],
        defaultTargetModel: String
    ) -> [AnthropicModelMapping] {
        var order: [String] = []
        var deduped: [String: AnthropicModelMapping] = [:]

        for mapping in mappings {
            let sourceModel = mapping.sourceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sourceModel.isEmpty == false else { continue }

            let trimmedTargetModel = mapping.targetModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetModel = trimmedTargetModel.isEmpty ? defaultTargetModel : trimmedTargetModel
            let normalized = AnthropicModelMapping(sourceModel: sourceModel, targetModel: targetModel)

            if deduped[sourceModel] == nil {
                order.append(sourceModel)
            }
            deduped[sourceModel] = normalized
        }

        return order.compactMap { deduped[$0] }
    }
    private static func normalizedProxyAPIKeys(
        _ keys: [ProxyAPIKeyRecord],
        legacyProxyAPIKey: String
    ) -> [ProxyAPIKeyRecord] {
        var normalized: [ProxyAPIKeyRecord] = []
        var seenKeys = Set<String>()

        let seedKeys = keys.isEmpty
            ? [
                ProxyAPIKeyRecord(
                    label: Self.defaultProxyAPIKeyLabel,
                    key: legacyProxyAPIKey,
                    dataSource: .openAI,
                    enabled: true
                )
            ]
            : keys

        for (index, entry) in seedKeys.enumerated() {
            let trimmedKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedKey.isEmpty == false else { continue }
            guard seenKeys.insert(trimmedKey).inserted else { continue }

            let trimmedLabel = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.append(
                ProxyAPIKeyRecord(
                    id: entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? UUID().uuidString : entry.id,
                    label: trimmedLabel.isEmpty ? (index == 0 ? Self.defaultProxyAPIKeyLabel : "API Key \(index + 1)") : trimmedLabel,
                    key: trimmedKey,
                    dataSource: entry.dataSource,
                    allowedAccountKeys: ProxyAPIKeyRecord.normalizedAllowedAccountKeys(entry.allowedAccountKeys),
                    enabled: entry.enabled,
                    createdAt: entry.createdAt > 0 ? entry.createdAt : Helpers.now()
                )
            )
        }

        return normalized
    }

    private static func normalizedPrimaryProxyAPIKeyID(
        requestedID: String?,
        proxyAPIKeys: [ProxyAPIKeyRecord]
    ) -> String? {
        guard proxyAPIKeys.isEmpty == false else { return nil }
        if let requestedID,
           let matched = proxyAPIKeys.first(where: { $0.id == requestedID })
        {
            if matched.enabled {
                return matched.id
            }
        }
        if let firstEnabled = proxyAPIKeys.first(where: \.enabled) {
            return firstEnabled.id
        }
        return proxyAPIKeys.first?.id
    }
}

public struct AnthropicModelMapping: Codable, Sendable, Equatable {
    public var sourceModel: String
    public var targetModel: String

    public init(
        sourceModel: String = "",
        targetModel: String = AppConfig.defaultAnthropicTargetModel
    ) {
        self.sourceModel = sourceModel
        self.targetModel = targetModel
    }
}

public struct AccountModelMapping: Codable, Sendable, Equatable {
    public var sourceModel: String
    public var targetModel: String

    public init(sourceModel: String = "", targetModel: String = "") {
        self.sourceModel = sourceModel
        self.targetModel = targetModel
    }
}

public struct AccountModelRoutingConfig: Codable, Sendable, Equatable {
    public var defaultTargetModel: String?
    public var mappings: [AccountModelMapping]

    public init(defaultTargetModel: String? = nil, mappings: [AccountModelMapping] = []) {
        self.defaultTargetModel = Self.normalizedTargetModelValue(defaultTargetModel)
        self.mappings = Self.normalizedMappings(mappings)
    }

    private enum CodingKeys: String, CodingKey {
        case defaultTargetModel
        case defaultTargetModelSnake = "default_target_model"
        case mappings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultTargetModel: try container.decodeIfPresent(String.self, forKey: .defaultTargetModel)
                ?? container.decodeIfPresent(String.self, forKey: .defaultTargetModelSnake),
            mappings: try container.decodeIfPresent([AccountModelMapping].self, forKey: .mappings) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.defaultTargetModel, forKey: .defaultTargetModel)
        try container.encode(self.mappings, forKey: .mappings)
    }

    public var normalizedOrNil: AccountModelRoutingConfig? {
        let normalized = AccountModelRoutingConfig(
            defaultTargetModel: self.defaultTargetModel,
            mappings: self.mappings
        )
        if normalized.defaultTargetModel == nil, normalized.mappings.isEmpty {
            return nil
        }
        return normalized
    }

    public func resolvedTargetModel(for sourceModel: String) -> String? {
        let trimmedSourceModel = sourceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSourceModel.isEmpty == false else { return nil }
        return self.mappings.first(where: { $0.sourceModel == trimmedSourceModel })?.targetModel
    }

    private static func normalizedMappings(_ mappings: [AccountModelMapping]) -> [AccountModelMapping] {
        var order: [String] = []
        var deduped: [String: AccountModelMapping] = [:]

        for mapping in mappings {
            let sourceModel = mapping.sourceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetModel = normalizedTargetModelValue(mapping.targetModel)
            guard sourceModel.isEmpty == false, let targetModel else { continue }

            if deduped[sourceModel] == nil {
                order.append(sourceModel)
            }
            deduped[sourceModel] = AccountModelMapping(sourceModel: sourceModel, targetModel: targetModel)
        }

        return order.compactMap { deduped[$0] }
    }

    private static func normalizedTargetModelValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct AccountReasoningEffortConfig: Codable, Sendable, Equatable {
    public static let defaultConfig = AccountReasoningEffortConfig()

    public var low: String
    public var medium: String
    public var high: String
    public var xhigh: String

    public init(
        low: String = "low",
        medium: String = "medium",
        high: String = "high",
        xhigh: String = "xhigh"
    ) {
        self.low = low.trimmingCharacters(in: .whitespacesAndNewlines)
        self.medium = medium.trimmingCharacters(in: .whitespacesAndNewlines)
        self.high = high.trimmingCharacters(in: .whitespacesAndNewlines)
        self.xhigh = xhigh.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case low
        case medium
        case high
        case xhigh
        case extraHigh
        case extraHighSnake = "extra_high"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            low: try container.decodeIfPresent(String.self, forKey: .low) ?? "low",
            medium: try container.decodeIfPresent(String.self, forKey: .medium) ?? "medium",
            high: try container.decodeIfPresent(String.self, forKey: .high) ?? "high",
            xhigh: try container.decodeIfPresent(String.self, forKey: .xhigh)
                ?? container.decodeIfPresent(String.self, forKey: .extraHigh)
                ?? container.decodeIfPresent(String.self, forKey: .extraHighSnake)
                ?? "xhigh"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.low, forKey: .low)
        try container.encode(self.medium, forKey: .medium)
        try container.encode(self.high, forKey: .high)
        try container.encode(self.xhigh, forKey: .xhigh)
    }

    public func mappedReasoningEffort(for rawEffort: String?) -> String? {
        let trimmed = rawEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else { return nil }
        let mapped: String?
        switch trimmed.lowercased() {
        case "low":
            mapped = self.low
        case "medium":
            mapped = self.medium
        case "high":
            mapped = self.high
        case "xhigh":
            mapped = self.xhigh
        default:
            return trimmed
        }
        let normalized = mapped?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? trimmed : normalized
    }
}

public struct UsageWindow: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var windowSeconds: Int
    public var resetAt: Int64?

    public init(usedPercent: Double, windowSeconds: Int, resetAt: Int64?) {
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetAt = resetAt
    }

    public var remainingPercent: Int {
        Int((100.0 - self.usedPercent).rounded()).clamped(to: 0...100)
    }
}

public struct CreditSnapshot: Codable, Sendable, Equatable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var fetchedAt: Int64
    public var planType: String?
    public var fiveHour: UsageWindow?
    public var oneWeek: UsageWindow?
    public var credits: CreditSnapshot?

    public init(
        fetchedAt: Int64 = Int64(Date().timeIntervalSince1970),
        planType: String?,
        fiveHour: UsageWindow?,
        oneWeek: UsageWindow?,
        credits: CreditSnapshot?
    ) {
        self.fetchedAt = fetchedAt
        self.planType = planType
        self.fiveHour = fiveHour
        self.oneWeek = oneWeek
        self.credits = credits
    }
}

public struct AccountTodayTokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int64
    public var outputTokens: Int64

    public init(inputTokens: Int64 = 0, outputTokens: Int64 = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct AccountSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var label: String
    public var email: String?
    public var accountKey: String
    public var accountID: String
    public var planType: String?
    public var providerFamily: AccountProviderFamily
    public var authMode: AccountAuthMode
    public var providerPreset: OpenAICompatibleProviderPreset
    public var upstreamAdapter: ManualAPIKeyUpstreamAdapter?
    public var upstreamBaseURL: String?
    public var managedProxyNodeName: String?
    public var modelRouting: AccountModelRoutingConfig?
    public var reasoningEffort: AccountReasoningEffortConfig
    public var supportsVision: Bool
    public var addedAt: Int64
    public var updatedAt: Int64
    public var enabled: Bool
    public var selectionOrder: Int64
    public var consecutiveFailureCount: Int64
    public var cooldownUntil: Int64?
    public var automaticCooldownDisabled: Bool
    public var usage: UsageSnapshot?
    public var usageWindowsVisible: Bool
    public var todayTokenUsage: AccountTodayTokenUsage?
    public var usageError: String?
    public var authRefreshBlocked: Bool
    public var authRefreshError: String?
    public var isCurrent: Bool

    public init(
        id: String,
        label: String,
        email: String?,
        accountKey: String,
        accountID: String,
        planType: String?,
        providerFamily: AccountProviderFamily? = nil,
        authMode: AccountAuthMode = .chatGPT,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        upstreamBaseURL: String? = nil,
        managedProxyNodeName: String? = nil,
        modelRouting: AccountModelRoutingConfig? = nil,
        reasoningEffort: AccountReasoningEffortConfig = .defaultConfig,
        supportsVision: Bool = true,
        addedAt: Int64,
        updatedAt: Int64,
        enabled: Bool = true,
        selectionOrder: Int64 = 0,
        consecutiveFailureCount: Int64 = 0,
        cooldownUntil: Int64? = nil,
        automaticCooldownDisabled: Bool = false,
        usage: UsageSnapshot?,
        usageWindowsVisible: Bool = true,
        todayTokenUsage: AccountTodayTokenUsage? = nil,
        usageError: String?,
        authRefreshBlocked: Bool,
        authRefreshError: String?,
        isCurrent: Bool
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.accountKey = accountKey
        self.accountID = accountID
        self.planType = planType
        self.providerFamily = providerFamily ?? authMode.providerFamily
        self.authMode = authMode
        self.providerPreset = providerPreset
        self.upstreamAdapter = upstreamAdapter
        self.upstreamBaseURL = upstreamBaseURL
        self.managedProxyNodeName = Self.normalizedManagedProxyNodeName(managedProxyNodeName)
        self.modelRouting = Self.normalizedModelRouting(modelRouting)
        self.reasoningEffort = reasoningEffort
        self.supportsVision = supportsVision
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.selectionOrder = selectionOrder
        self.consecutiveFailureCount = consecutiveFailureCount
        self.cooldownUntil = cooldownUntil
        self.automaticCooldownDisabled = automaticCooldownDisabled
        self.usage = usage
        self.usageWindowsVisible = usageWindowsVisible
        self.todayTokenUsage = todayTokenUsage
        self.usageError = usageError
        self.authRefreshBlocked = authRefreshBlocked
        self.authRefreshError = authRefreshError
        self.isCurrent = isCurrent
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case email
        case accountKey
        case accountID
        case accountId
        case planType
        case providerFamily
        case authMode
        case providerPreset
        case providerPresetSnake = "provider_preset"
        case upstreamAdapter
        case upstreamAdapterSnake = "upstream_adapter"
        case upstreamBaseURL
        case upstreamBaseUrl
        case managedProxyNodeName
        case managedProxyNodeNameSnake = "managed_proxy_node_name"
        case modelRouting
        case modelRoutingSnake = "model_routing"
        case reasoningEffort
        case reasoningEffortSnake = "reasoning_effort"
        case supportsVision
        case supportsVisionSnake = "supports_vision"
        case addedAt
        case updatedAt
        case enabled
        case selectionOrder
        case consecutiveFailureCount
        case cooldownUntil
        case automaticCooldownDisabled
        case automaticCooldownDisabledSnake = "automatic_cooldown_disabled"
        case usage
        case usageWindowsVisible
        case todayTokenUsage
        case usageError
        case authRefreshBlocked
        case authRefreshError
        case isCurrent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            email: try container.decodeIfPresent(String.self, forKey: .email),
            accountKey: try container.decode(String.self, forKey: .accountKey),
            accountID: try container.decodeIfPresent(String.self, forKey: .accountID)
                ?? container.decode(String.self, forKey: .accountId),
            planType: try container.decodeIfPresent(String.self, forKey: .planType),
            providerFamily: try container.decodeIfPresent(AccountProviderFamily.self, forKey: .providerFamily),
            authMode: try container.decodeIfPresent(AccountAuthMode.self, forKey: .authMode) ?? .chatGPT,
            providerPreset: try container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPreset)
                ?? container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPresetSnake)
                ?? .genericOpenAICompatible,
            upstreamAdapter: try container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapter)
                ?? container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapterSnake),
            upstreamBaseURL: try container.decodeIfPresent(String.self, forKey: .upstreamBaseURL)
                ?? container.decodeIfPresent(String.self, forKey: .upstreamBaseUrl),
            managedProxyNodeName: try container.decodeIfPresent(String.self, forKey: .managedProxyNodeName)
                ?? container.decodeIfPresent(String.self, forKey: .managedProxyNodeNameSnake),
            modelRouting: try container.decodeIfPresent(AccountModelRoutingConfig.self, forKey: .modelRouting)
                ?? container.decodeIfPresent(AccountModelRoutingConfig.self, forKey: .modelRoutingSnake),
            reasoningEffort: try container.decodeIfPresent(AccountReasoningEffortConfig.self, forKey: .reasoningEffort)
                ?? container.decodeIfPresent(AccountReasoningEffortConfig.self, forKey: .reasoningEffortSnake)
                ?? .defaultConfig,
            supportsVision: try container.decodeIfPresent(Bool.self, forKey: .supportsVision)
                ?? container.decodeIfPresent(Bool.self, forKey: .supportsVisionSnake)
                ?? true,
            addedAt: try container.decode(Int64.self, forKey: .addedAt),
            updatedAt: try container.decode(Int64.self, forKey: .updatedAt),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            selectionOrder: try container.decodeIfPresent(Int64.self, forKey: .selectionOrder) ?? 0,
            consecutiveFailureCount: try container.decodeIfPresent(Int64.self, forKey: .consecutiveFailureCount) ?? 0,
            cooldownUntil: try container.decodeIfPresent(Int64.self, forKey: .cooldownUntil),
            automaticCooldownDisabled: try container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabled)
                ?? container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabledSnake)
                ?? false,
            usage: try container.decodeIfPresent(UsageSnapshot.self, forKey: .usage),
            usageWindowsVisible: try container.decodeIfPresent(Bool.self, forKey: .usageWindowsVisible) ?? true,
            todayTokenUsage: try container.decodeIfPresent(AccountTodayTokenUsage.self, forKey: .todayTokenUsage),
            usageError: try container.decodeIfPresent(String.self, forKey: .usageError),
            authRefreshBlocked: try container.decodeIfPresent(Bool.self, forKey: .authRefreshBlocked) ?? false,
            authRefreshError: try container.decodeIfPresent(String.self, forKey: .authRefreshError),
            isCurrent: try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.label, forKey: .label)
        try container.encodeIfPresent(self.email, forKey: .email)
        try container.encode(self.accountKey, forKey: .accountKey)
        try container.encode(self.accountID, forKey: .accountID)
        try container.encodeIfPresent(self.planType, forKey: .planType)
        try container.encode(self.providerFamily, forKey: .providerFamily)
        try container.encode(self.authMode, forKey: .authMode)
        try container.encode(self.providerPreset, forKey: .providerPreset)
        try container.encodeIfPresent(self.upstreamAdapter, forKey: .upstreamAdapter)
        try container.encodeIfPresent(self.upstreamBaseURL, forKey: .upstreamBaseURL)
        try container.encodeIfPresent(self.managedProxyNodeName, forKey: .managedProxyNodeName)
        try container.encodeIfPresent(self.modelRouting, forKey: .modelRouting)
        try container.encode(self.reasoningEffort, forKey: .reasoningEffort)
        try container.encode(self.supportsVision, forKey: .supportsVision)
        try container.encode(self.addedAt, forKey: .addedAt)
        try container.encode(self.updatedAt, forKey: .updatedAt)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.selectionOrder, forKey: .selectionOrder)
        try container.encode(self.consecutiveFailureCount, forKey: .consecutiveFailureCount)
        try container.encodeIfPresent(self.cooldownUntil, forKey: .cooldownUntil)
        try container.encode(self.automaticCooldownDisabled, forKey: .automaticCooldownDisabled)
        try container.encodeIfPresent(self.usage, forKey: .usage)
        try container.encode(self.usageWindowsVisible, forKey: .usageWindowsVisible)
        try container.encodeIfPresent(self.todayTokenUsage, forKey: .todayTokenUsage)
        try container.encodeIfPresent(self.usageError, forKey: .usageError)
        try container.encode(self.authRefreshBlocked, forKey: .authRefreshBlocked)
        try container.encodeIfPresent(self.authRefreshError, forKey: .authRefreshError)
        try container.encode(self.isCurrent, forKey: .isCurrent)
    }

    public var effectivePlanType: String? {
        resolvedAccountPlanType(self.usage?.planType, fallback: self.planType)
    }

    public static func normalizedManagedProxyNodeName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func normalizedModelRouting(_ value: AccountModelRoutingConfig?) -> AccountModelRoutingConfig? {
        value?.normalizedOrNil
    }

    public func isCoolingDown(now: Int64 = Helpers.now()) -> Bool {
        guard self.automaticCooldownDisabled == false else { return false }
        guard let cooldownUntil else { return false }
        return cooldownUntil > now
    }
}

public struct ProxyStatus: Codable, Sendable, Equatable {
    public enum ProxyTestAdminTransportMode: String, Codable, Sendable, Equatable {
        case legacyGeminiOnly = "legacyGeminiOnly"
        case full = "full"
    }

    public var running: Bool
    public var publicBaseURL: String
    public var anthropicBaseURL: String
    public var geminiBaseURL: String
    public var adminBaseURL: String
    public var apiKey: String
    public var activeAccountKey: String?
    public var activeAccountID: String?
    public var activeAccountLabel: String?
    public var lastError: String?
    public var daemonVersion: String
    public var proxyTestAdminTransportMode: ProxyTestAdminTransportMode?

    public init(
        running: Bool,
        publicBaseURL: String,
        anthropicBaseURL: String,
        geminiBaseURL: String,
        adminBaseURL: String,
        apiKey: String,
        activeAccountKey: String?,
        activeAccountID: String?,
        activeAccountLabel: String?,
        lastError: String?,
        daemonVersion: String,
        proxyTestAdminTransportMode: ProxyTestAdminTransportMode? = nil
    ) {
        self.running = running
        self.publicBaseURL = publicBaseURL
        self.anthropicBaseURL = anthropicBaseURL
        self.geminiBaseURL = geminiBaseURL
        self.adminBaseURL = adminBaseURL
        self.apiKey = apiKey
        self.activeAccountKey = activeAccountKey
        self.activeAccountID = activeAccountID
        self.activeAccountLabel = activeAccountLabel
        self.lastError = lastError
        self.daemonVersion = daemonVersion
        self.proxyTestAdminTransportMode = proxyTestAdminTransportMode
    }

    private enum CodingKeys: String, CodingKey {
        case running
        case publicBaseURL
        case publicBaseUrl
        case anthropicBaseURL
        case anthropicBaseUrl
        case geminiBaseURL
        case geminiBaseUrl
        case adminBaseURL
        case adminBaseUrl
        case apiKey
        case activeAccountKey
        case activeAccountID
        case activeAccountId
        case activeAccountLabel
        case lastError
        case daemonVersion
        case proxyTestAdminTransportMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            running: try container.decodeIfPresent(Bool.self, forKey: .running) ?? false,
            publicBaseURL: try container.decodeIfPresent(String.self, forKey: .publicBaseURL)
                ?? container.decode(String.self, forKey: .publicBaseUrl),
            anthropicBaseURL: try container.decodeIfPresent(String.self, forKey: .anthropicBaseURL)
                ?? container.decodeIfPresent(String.self, forKey: .anthropicBaseUrl)
                ?? "",
            geminiBaseURL: try container.decodeIfPresent(String.self, forKey: .geminiBaseURL)
                ?? container.decodeIfPresent(String.self, forKey: .geminiBaseUrl)
                ?? "",
            adminBaseURL: try container.decodeIfPresent(String.self, forKey: .adminBaseURL)
                ?? container.decode(String.self, forKey: .adminBaseUrl),
            apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey) ?? "",
            activeAccountKey: try container.decodeIfPresent(String.self, forKey: .activeAccountKey),
            activeAccountID: try container.decodeIfPresent(String.self, forKey: .activeAccountID)
                ?? container.decodeIfPresent(String.self, forKey: .activeAccountId),
            activeAccountLabel: try container.decodeIfPresent(String.self, forKey: .activeAccountLabel),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            daemonVersion: try container.decodeIfPresent(String.self, forKey: .daemonVersion) ?? "",
            proxyTestAdminTransportMode: try container.decodeIfPresent(
                ProxyTestAdminTransportMode.self,
                forKey: .proxyTestAdminTransportMode
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.running, forKey: .running)
        try container.encode(self.publicBaseURL, forKey: .publicBaseURL)
        try container.encode(self.anthropicBaseURL, forKey: .anthropicBaseURL)
        try container.encode(self.geminiBaseURL, forKey: .geminiBaseURL)
        try container.encode(self.adminBaseURL, forKey: .adminBaseURL)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encodeIfPresent(self.activeAccountKey, forKey: .activeAccountKey)
        try container.encodeIfPresent(self.activeAccountID, forKey: .activeAccountID)
        try container.encodeIfPresent(self.activeAccountLabel, forKey: .activeAccountLabel)
        try container.encodeIfPresent(self.lastError, forKey: .lastError)
        try container.encode(self.daemonVersion, forKey: .daemonVersion)
        try container.encodeIfPresent(self.proxyTestAdminTransportMode, forKey: .proxyTestAdminTransportMode)
    }
}

public enum ManagedProxyRuntimeState: String, Codable, Sendable, Equatable {
    case stopped
    case starting
    case running
    case degraded
}

public enum ManagedProxyListenerKind: String, Codable, Sendable, Equatable {
    case mixedPort = "mixed-port"
    case nodeListener = "node-listener"
}

public enum ManagedProxyNodeHealthcheckStatus: String, Codable, Sendable, Equatable {
    case success
    case failure
}

public struct ManagedProxyListener: Codable, Sendable, Equatable, Identifiable {
    public var kind: ManagedProxyListenerKind
    public var listenHost: String?
    public var port: Int
    public var nodeName: String?

    public init(
        kind: ManagedProxyListenerKind,
        listenHost: String? = nil,
        port: Int,
        nodeName: String? = nil
    ) {
        self.kind = kind
        self.listenHost = listenHost
        self.port = port
        self.nodeName = nodeName
    }

    public var id: String {
        "\(self.kind.rawValue):\(self.listenHost ?? ""):\(self.port):\(self.nodeName ?? "")"
    }
}

public struct ManagedProxyNode: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var type: String
    public var isCurrent: Bool
    public var isPinned: Bool
    public var alive: Bool?
    public var lastDelayMS: Int64?
    public var lastHealthcheckStatus: ManagedProxyNodeHealthcheckStatus?
    public var lastHealthcheckAt: Int64?

    public init(
        name: String,
        type: String,
        isCurrent: Bool? = nil,
        isPinned: Bool = false,
        selected: Bool = false,
        alive: Bool? = nil,
        lastDelayMS: Int64? = nil,
        lastHealthcheckStatus: ManagedProxyNodeHealthcheckStatus? = nil,
        lastHealthcheckAt: Int64? = nil
    ) {
        self.name = name
        self.type = type
        self.isCurrent = isCurrent ?? selected
        self.isPinned = isPinned
        self.alive = alive
        self.lastDelayMS = lastDelayMS
        self.lastHealthcheckStatus = lastHealthcheckStatus
        self.lastHealthcheckAt = lastHealthcheckAt
    }

    public var id: String { self.name }

    public var selected: Bool {
        get { self.isCurrent }
        set { self.isCurrent = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case isCurrent
        case isPinned
        case selected
        case alive
        case lastDelayMS
        case lastDelayMs
        case lastHealthcheckStatus
        case lastHealthcheckAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacySelected = try container.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        self.init(
            name: try container.decode(String.self, forKey: .name),
            type: try container.decode(String.self, forKey: .type),
            isCurrent: try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? legacySelected,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            alive: try container.decodeIfPresent(Bool.self, forKey: .alive),
            lastDelayMS: try container.decodeIfPresent(Int64.self, forKey: .lastDelayMS)
                ?? container.decodeIfPresent(Int64.self, forKey: .lastDelayMs),
            lastHealthcheckStatus: try container.decodeIfPresent(
                ManagedProxyNodeHealthcheckStatus.self,
                forKey: .lastHealthcheckStatus
            ),
            lastHealthcheckAt: try container.decodeIfPresent(Int64.self, forKey: .lastHealthcheckAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.type, forKey: .type)
        try container.encode(self.isCurrent, forKey: .isCurrent)
        try container.encode(self.isPinned, forKey: .isPinned)
        try container.encode(self.isCurrent, forKey: .selected)
        try container.encodeIfPresent(self.alive, forKey: .alive)
        try container.encodeIfPresent(self.lastDelayMS, forKey: .lastDelayMS)
        try container.encodeIfPresent(self.lastHealthcheckStatus, forKey: .lastHealthcheckStatus)
        try container.encodeIfPresent(self.lastHealthcheckAt, forKey: .lastHealthcheckAt)
    }
}

public struct ManagedProxySnapshot: Codable, Sendable, Equatable {
    public var mode: OutboundProxyMode
    public var subscriptionConfigured: Bool
    public var subscriptionURL: String?
    public var providerName: String
    public var autoUpdateIntervalHours: Int
    public var healthcheckURL: String
    public var runtimeState: ManagedProxyRuntimeState
    public var controllerReachable: Bool
    public var mixedPort: Int?
    public var controllerPort: Int?
    public var currentNodeName: String?
    public var pinnedNodeName: String?
    public var pinnedNodeAvailable: Bool
    public var providerUpdatedAt: Int64?
    public var listeners: [ManagedProxyListener]
    public var nodes: [ManagedProxyNode]
    public var lastHealthcheckFeedbackDetail: String?
    public var lastError: String?
    public var subscriptionUserinfo: String?

    public init(
        mode: OutboundProxyMode = .disabled,
        subscriptionConfigured: Bool = false,
        subscriptionURL: String? = nil,
        providerName: String = ManagedProxyConfigSummary.defaultProviderName,
        autoUpdateIntervalHours: Int = ManagedProxyConfigSummary.defaultAutoUpdateIntervalHours,
        healthcheckURL: String = ManagedProxyConfigSummary.defaultHealthcheckURL,
        runtimeState: ManagedProxyRuntimeState = .stopped,
        controllerReachable: Bool = false,
        mixedPort: Int? = nil,
        controllerPort: Int? = nil,
        currentNodeName: String? = nil,
        pinnedNodeName: String? = nil,
        pinnedNodeAvailable: Bool = false,
        selectedNodeName: String? = nil,
        selectedNodeAvailable: Bool = false,
        providerUpdatedAt: Int64? = nil,
        listeners: [ManagedProxyListener] = [],
        nodes: [ManagedProxyNode] = [],
        lastHealthcheckFeedbackDetail: String? = nil,
        lastError: String? = nil,
        subscriptionUserinfo: String? = nil
    ) {
        self.mode = mode
        self.subscriptionConfigured = subscriptionConfigured
        self.subscriptionURL = subscriptionURL
        self.providerName = providerName
        self.autoUpdateIntervalHours = autoUpdateIntervalHours
        self.healthcheckURL = ManagedProxyConfigSummary.sanitizedHealthcheckURL(healthcheckURL)
        self.runtimeState = runtimeState
        self.controllerReachable = controllerReachable
        self.mixedPort = mixedPort
        self.controllerPort = controllerPort
        self.currentNodeName = currentNodeName
        self.pinnedNodeName = pinnedNodeName ?? selectedNodeName
        self.pinnedNodeAvailable = pinnedNodeName != nil
            ? pinnedNodeAvailable
            : selectedNodeAvailable
        self.providerUpdatedAt = providerUpdatedAt
        self.listeners = listeners
        self.nodes = nodes
        self.lastHealthcheckFeedbackDetail = lastHealthcheckFeedbackDetail
        self.lastError = lastError
        self.subscriptionUserinfo = subscriptionUserinfo
    }

    public var selectedNodeName: String? {
        get { self.pinnedNodeName }
        set { self.pinnedNodeName = newValue }
    }

    public var selectedNodeAvailable: Bool {
        get { self.pinnedNodeAvailable }
        set { self.pinnedNodeAvailable = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case subscriptionConfigured
        case subscriptionURL = "subscriptionUrl"
        case providerName
        case autoUpdateIntervalHours
        case healthcheckURL = "healthcheckUrl"
        case runtimeState
        case controllerReachable
        case mixedPort
        case controllerPort
        case currentNodeName
        case pinnedNodeName
        case pinnedNodeAvailable
        case selectedNodeName
        case selectedNodeAvailable
        case providerUpdatedAt
        case listeners
        case nodes
        case lastHealthcheckFeedbackDetail
        case lastError
        case subscriptionUserinfo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyPinnedNodeName = try container.decodeIfPresent(String.self, forKey: .selectedNodeName)
        let legacyPinnedNodeAvailable = try container.decodeIfPresent(Bool.self, forKey: .selectedNodeAvailable) ?? false
        self.init(
            mode: try container.decodeIfPresent(OutboundProxyMode.self, forKey: .mode) ?? .disabled,
            subscriptionConfigured: try container.decodeIfPresent(Bool.self, forKey: .subscriptionConfigured) ?? false,
            subscriptionURL: try container.decodeIfPresent(String.self, forKey: .subscriptionURL),
            providerName: try container.decodeIfPresent(String.self, forKey: .providerName) ?? ManagedProxyConfigSummary.defaultProviderName,
            autoUpdateIntervalHours: try container.decodeIfPresent(Int.self, forKey: .autoUpdateIntervalHours)
                ?? ManagedProxyConfigSummary.defaultAutoUpdateIntervalHours,
            healthcheckURL: try container.decodeIfPresent(String.self, forKey: .healthcheckURL)
                ?? ManagedProxyConfigSummary.defaultHealthcheckURL,
            runtimeState: try container.decodeIfPresent(ManagedProxyRuntimeState.self, forKey: .runtimeState) ?? .stopped,
            controllerReachable: try container.decodeIfPresent(Bool.self, forKey: .controllerReachable) ?? false,
            mixedPort: try container.decodeIfPresent(Int.self, forKey: .mixedPort),
            controllerPort: try container.decodeIfPresent(Int.self, forKey: .controllerPort),
            currentNodeName: try container.decodeIfPresent(String.self, forKey: .currentNodeName),
            pinnedNodeName: try container.decodeIfPresent(String.self, forKey: .pinnedNodeName) ?? legacyPinnedNodeName,
            pinnedNodeAvailable: try container.decodeIfPresent(Bool.self, forKey: .pinnedNodeAvailable) ?? legacyPinnedNodeAvailable,
            providerUpdatedAt: try container.decodeIfPresent(Int64.self, forKey: .providerUpdatedAt),
            listeners: try container.decodeIfPresent([ManagedProxyListener].self, forKey: .listeners) ?? [],
            nodes: try container.decodeIfPresent([ManagedProxyNode].self, forKey: .nodes) ?? [],
            lastHealthcheckFeedbackDetail: try container.decodeIfPresent(
                String.self,
                forKey: .lastHealthcheckFeedbackDetail
            ),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            subscriptionUserinfo: try container.decodeIfPresent(String.self, forKey: .subscriptionUserinfo)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.mode, forKey: .mode)
        try container.encode(self.subscriptionConfigured, forKey: .subscriptionConfigured)
        try container.encodeIfPresent(self.subscriptionURL, forKey: .subscriptionURL)
        try container.encode(self.providerName, forKey: .providerName)
        try container.encode(self.autoUpdateIntervalHours, forKey: .autoUpdateIntervalHours)
        try container.encode(self.healthcheckURL, forKey: .healthcheckURL)
        try container.encode(self.runtimeState, forKey: .runtimeState)
        try container.encode(self.controllerReachable, forKey: .controllerReachable)
        try container.encodeIfPresent(self.mixedPort, forKey: .mixedPort)
        try container.encodeIfPresent(self.controllerPort, forKey: .controllerPort)
        try container.encodeIfPresent(self.currentNodeName, forKey: .currentNodeName)
        try container.encodeIfPresent(self.pinnedNodeName, forKey: .pinnedNodeName)
        try container.encode(self.pinnedNodeAvailable, forKey: .pinnedNodeAvailable)
        try container.encodeIfPresent(self.pinnedNodeName, forKey: .selectedNodeName)
        try container.encode(self.pinnedNodeAvailable, forKey: .selectedNodeAvailable)
        try container.encodeIfPresent(self.providerUpdatedAt, forKey: .providerUpdatedAt)
        try container.encode(self.listeners, forKey: .listeners)
        try container.encode(self.nodes, forKey: .nodes)
        try container.encodeIfPresent(self.lastHealthcheckFeedbackDetail, forKey: .lastHealthcheckFeedbackDetail)
        try container.encodeIfPresent(self.lastError, forKey: .lastError)
        try container.encodeIfPresent(self.subscriptionUserinfo, forKey: .subscriptionUserinfo)
    }
}

public struct ManagedProxyConfigPayload: Codable, Sendable, Equatable {
    public var subscriptionURL: String?

    public init(subscriptionURL: String? = nil) {
        self.subscriptionURL = subscriptionURL
    }

    enum CodingKeys: String, CodingKey {
        case subscriptionURL = "subscriptionUrl"
    }
}

public struct ManagedProxyHealthcheckConfigPayload: Codable, Sendable, Equatable {
    public var healthcheckURL: String?

    public init(healthcheckURL: String? = nil) {
        self.healthcheckURL = healthcheckURL
    }

    enum CodingKeys: String, CodingKey {
        case healthcheckURL = "healthcheckUrl"
    }
}

public struct ManagedProxySelectRequest: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct ManagedProxySwitchCurrentRequest: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct ManagedProxyPinnedNodeRequest: Codable, Sendable, Equatable {
    public var name: String?

    public init(name: String? = nil) {
        self.name = name
    }
}

public struct ManagedProxyHealthcheckRequest: Codable, Sendable, Equatable {
    public var nodeName: String?

    public init(nodeName: String? = nil) {
        self.nodeName = nodeName
    }
}

public enum ProxyTestModelFamily: String, Codable, Sendable, Equatable {
    case gpt
    case image
    case anthropic
    case gemini
}

public struct ProxyTestModelGroup: Codable, Sendable, Equatable {
    public var family: ProxyTestModelFamily
    public var models: [String]
    public var defaultModel: String

    public init(
        family: ProxyTestModelFamily,
        models: [String],
        defaultModel: String
    ) {
        self.family = family
        self.models = models
        self.defaultModel = defaultModel
    }
}

public struct ProxyTestModelCatalog: Codable, Sendable, Equatable {
    public var chatCompletions: ProxyTestModelGroup
    public var responses: ProxyTestModelGroup
    public var imageGenerations: ProxyTestModelGroup
    public var anthropicMessages: ProxyTestModelGroup
    public var geminiGenerateContent: ProxyTestModelGroup

    public init(
        chatCompletions: ProxyTestModelGroup,
        responses: ProxyTestModelGroup,
        imageGenerations: ProxyTestModelGroup = ProxyTestModelGroup(
            family: .image,
            models: ["codex-gpt-image-2", "gpt-image-2"],
            defaultModel: "codex-gpt-image-2"
        ),
        anthropicMessages: ProxyTestModelGroup,
        geminiGenerateContent: ProxyTestModelGroup = ProxyTestModelGroup(
            family: .gemini,
            models: [
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite",
            ],
            defaultModel: "gemini-2.5-flash"
        )
    ) {
        self.chatCompletions = chatCompletions
        self.responses = responses
        self.imageGenerations = imageGenerations
        self.anthropicMessages = anthropicMessages
        self.geminiGenerateContent = geminiGenerateContent
    }

    private enum CodingKeys: String, CodingKey {
        case chatCompletions
        case responses
        case imageGenerations
        case anthropicMessages
        case geminiGenerateContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            chatCompletions: try container.decode(ProxyTestModelGroup.self, forKey: .chatCompletions),
            responses: try container.decode(ProxyTestModelGroup.self, forKey: .responses),
            imageGenerations: try container.decodeIfPresent(ProxyTestModelGroup.self, forKey: .imageGenerations)
                ?? ProxyTestModelGroup(
                    family: .image,
                    models: Self.defaultImageModels,
                    defaultModel: Self.defaultImageModels.first ?? "codex-gpt-image-2"
                ),
            anthropicMessages: try container.decode(ProxyTestModelGroup.self, forKey: .anthropicMessages),
            geminiGenerateContent: try container.decodeIfPresent(ProxyTestModelGroup.self, forKey: .geminiGenerateContent)
                ?? ProxyTestModelGroup(
                    family: .gemini,
                    models: Self.defaultGeminiModels,
                    defaultModel: Self.defaultGeminiModels.first ?? "gemini-2.5-flash"
                )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.chatCompletions, forKey: .chatCompletions)
        try container.encode(self.responses, forKey: .responses)
        try container.encode(self.imageGenerations, forKey: .imageGenerations)
        try container.encode(self.anthropicMessages, forKey: .anthropicMessages)
        try container.encode(self.geminiGenerateContent, forKey: .geminiGenerateContent)
    }

    private static let defaultGPTModels = ProxyTranscoder.supportedModels
    private static let defaultGPTModel = ProxyTranscoder.defaultModel
    private static let defaultImageModels = ["codex-gpt-image-2", "gpt-image-2"]
    private static let defaultAnthropicModels = [
        "claude-sonnet-4-5",
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-3-7-sonnet-latest",
        "claude-3-5-haiku-latest",
        "claude-opus-4-1",
    ]
    private static let defaultGeminiModels = [
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
    ]

    public static let defaultCatalog = ProxyTestModelCatalog(
        chatCompletions: ProxyTestModelGroup(
            family: .gpt,
            models: Self.defaultGPTModels,
            defaultModel: Self.defaultGPTModel
        ),
        responses: ProxyTestModelGroup(
            family: .gpt,
            models: Self.defaultGPTModels,
            defaultModel: Self.defaultGPTModel
        ),
        imageGenerations: ProxyTestModelGroup(
            family: .image,
            models: Self.defaultImageModels,
            defaultModel: Self.defaultImageModels.first ?? "codex-gpt-image-2"
        ),
        anthropicMessages: ProxyTestModelGroup(
            family: .anthropic,
            models: Self.defaultAnthropicModels,
            defaultModel: Self.defaultAnthropicModels.first ?? "claude-sonnet-4-5"
        ),
        geminiGenerateContent: ProxyTestModelGroup(
            family: .gemini,
            models: Self.defaultGeminiModels,
            defaultModel: Self.defaultGeminiModels.first ?? "gemini-2.5-flash"
        )
    )
}

public enum AdminProxyTestEndpoint: String, Codable, Sendable, Equatable {
    case chatCompletions = "chatCompletions"
    case responses = "responses"
    case imageGenerations = "imageGenerations"
    case imageEdits = "imageEdits"
    case anthropicMessages = "anthropicMessages"
    case geminiGenerateContent = "geminiGenerateContent"
}

public struct AdminProxyTestRunRequest: Codable, Sendable, Equatable {
    public var endpoint: AdminProxyTestEndpoint
    public var model: String
    public var payloadJSON: String
    public var stream: Bool
    public var selectedAccountKey: String?
    public var proxyAPIKey: String?
    public var anthropicVersion: String?
    public var anthropicBeta: String?
    public var contentType: String?
    public var bodyBase64: String?

    public init(
        endpoint: AdminProxyTestEndpoint,
        model: String,
        payloadJSON: String,
        stream: Bool,
        selectedAccountKey: String? = nil,
        proxyAPIKey: String? = nil,
        anthropicVersion: String? = nil,
        anthropicBeta: String? = nil,
        contentType: String? = nil,
        bodyBase64: String? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.payloadJSON = payloadJSON
        self.stream = stream
        self.selectedAccountKey = selectedAccountKey
        self.proxyAPIKey = proxyAPIKey
        self.anthropicVersion = anthropicVersion
        self.anthropicBeta = anthropicBeta
        self.contentType = contentType
        self.bodyBase64 = bodyBase64
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case model
        case payloadJSON
        case payloadJson
        case payloadJSONSnake = "payload_json"
        case stream
        case selectedAccountKey
        case selectedAccountKeySnake = "selected_account_key"
        case proxyAPIKey
        case proxyApiKey
        case proxyAPIKeySnake = "proxy_api_key"
        case anthropicVersion
        case anthropicVersionSnake = "anthropic_version"
        case anthropicBeta
        case anthropicBetaSnake = "anthropic_beta"
        case contentType
        case contentTypeSnake = "content_type"
        case bodyBase64
        case bodyBase64Snake = "body_base64"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payloadJSON = try container.decodeIfPresent(String.self, forKey: .payloadJSON)
            ?? container.decodeIfPresent(String.self, forKey: .payloadJson)
            ?? container.decode(String.self, forKey: .payloadJSONSnake)
        let selectedAccountKey = try container.decodeIfPresent(String.self, forKey: .selectedAccountKey)
            ?? container.decodeIfPresent(String.self, forKey: .selectedAccountKeySnake)
        self.init(
            endpoint: try container.decode(AdminProxyTestEndpoint.self, forKey: .endpoint),
            model: try container.decode(String.self, forKey: .model),
            payloadJSON: payloadJSON,
            stream: try container.decode(Bool.self, forKey: .stream),
            selectedAccountKey: selectedAccountKey,
            proxyAPIKey: try container.decodeIfPresent(String.self, forKey: .proxyAPIKey)
                ?? container.decodeIfPresent(String.self, forKey: .proxyApiKey)
                ?? container.decodeIfPresent(String.self, forKey: .proxyAPIKeySnake),
            anthropicVersion: try container.decodeIfPresent(String.self, forKey: .anthropicVersion)
                ?? container.decodeIfPresent(String.self, forKey: .anthropicVersionSnake),
            anthropicBeta: try container.decodeIfPresent(String.self, forKey: .anthropicBeta)
                ?? container.decodeIfPresent(String.self, forKey: .anthropicBetaSnake),
            contentType: try container.decodeIfPresent(String.self, forKey: .contentType)
                ?? container.decodeIfPresent(String.self, forKey: .contentTypeSnake),
            bodyBase64: try container.decodeIfPresent(String.self, forKey: .bodyBase64)
                ?? container.decodeIfPresent(String.self, forKey: .bodyBase64Snake)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.endpoint, forKey: .endpoint)
        try container.encode(self.model, forKey: .model)
        try container.encode(self.payloadJSON, forKey: .payloadJSON)
        try container.encode(self.stream, forKey: .stream)
        try container.encodeIfPresent(self.selectedAccountKey, forKey: .selectedAccountKey)
        try container.encodeIfPresent(self.proxyAPIKey, forKey: .proxyAPIKey)
        try container.encodeIfPresent(self.anthropicVersion, forKey: .anthropicVersion)
        try container.encodeIfPresent(self.anthropicBeta, forKey: .anthropicBeta)
        try container.encodeIfPresent(self.contentType, forKey: .contentType)
        try container.encodeIfPresent(self.bodyBase64, forKey: .bodyBase64)
    }
}

public struct RequestMetricBucket: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(self.granularity)-\(self.bucketStart)-\(self.endpoint)-\(self.apiKeyHash)-\(self.accountKey)-\(self.model)" }
    public var granularity: String
    public var bucketStart: Int64
    public var endpoint: String
    public var apiKeyHash: String
    public var accountKey: String
    public var accountLabel: String
    public var model: String
    public var successCount: Int
    public var failureCount: Int
    public var authFailureCount: Int
    public var rateLimitCount: Int
    public var quotaFailureCount: Int
    public var totalLatencyMS: Int64
    public var p95LatencyMS: Int64
    public var totalInputTokens: Int64
    public var totalOutputTokens: Int64
    public var totalTokens: Int64
    public var lastError: String?

    public init(
        granularity: String,
        bucketStart: Int64,
        endpoint: String,
        apiKeyHash: String,
        accountKey: String,
        accountLabel: String,
        model: String,
        successCount: Int,
        failureCount: Int,
        authFailureCount: Int,
        rateLimitCount: Int,
        quotaFailureCount: Int,
        totalLatencyMS: Int64,
        p95LatencyMS: Int64,
        totalInputTokens: Int64,
        totalOutputTokens: Int64,
        totalTokens: Int64,
        lastError: String?
    ) {
        self.granularity = granularity
        self.bucketStart = bucketStart
        self.endpoint = endpoint
        self.apiKeyHash = apiKeyHash
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.model = model
        self.successCount = successCount
        self.failureCount = failureCount
        self.authFailureCount = authFailureCount
        self.rateLimitCount = rateLimitCount
        self.quotaFailureCount = quotaFailureCount
        self.totalLatencyMS = totalLatencyMS
        self.p95LatencyMS = p95LatencyMS
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case granularity
        case bucketStart
        case endpoint
        case apiKeyHash
        case accountKey
        case accountLabel
        case model
        case successCount
        case failureCount
        case authFailureCount
        case rateLimitCount
        case quotaFailureCount
        case totalLatencyMS
        case totalLatencyMs
        case p95LatencyMS
        case p95LatencyMs
        case totalInputTokens
        case totalOutputTokens
        case totalTokens
        case lastError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            granularity: try container.decode(String.self, forKey: .granularity),
            bucketStart: try container.decode(Int64.self, forKey: .bucketStart),
            endpoint: try container.decode(String.self, forKey: .endpoint),
            apiKeyHash: try container.decode(String.self, forKey: .apiKeyHash),
            accountKey: try container.decode(String.self, forKey: .accountKey),
            accountLabel: try container.decode(String.self, forKey: .accountLabel),
            model: try container.decode(String.self, forKey: .model),
            successCount: try container.decode(Int.self, forKey: .successCount),
            failureCount: try container.decode(Int.self, forKey: .failureCount),
            authFailureCount: try container.decode(Int.self, forKey: .authFailureCount),
            rateLimitCount: try container.decode(Int.self, forKey: .rateLimitCount),
            quotaFailureCount: try container.decode(Int.self, forKey: .quotaFailureCount),
            totalLatencyMS: try container.decodeIfPresent(Int64.self, forKey: .totalLatencyMS)
                ?? container.decode(Int64.self, forKey: .totalLatencyMs),
            p95LatencyMS: try container.decodeIfPresent(Int64.self, forKey: .p95LatencyMS)
                ?? container.decode(Int64.self, forKey: .p95LatencyMs),
            totalInputTokens: try container.decode(Int64.self, forKey: .totalInputTokens),
            totalOutputTokens: try container.decode(Int64.self, forKey: .totalOutputTokens),
            totalTokens: try container.decode(Int64.self, forKey: .totalTokens),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.granularity, forKey: .granularity)
        try container.encode(self.bucketStart, forKey: .bucketStart)
        try container.encode(self.endpoint, forKey: .endpoint)
        try container.encode(self.apiKeyHash, forKey: .apiKeyHash)
        try container.encode(self.accountKey, forKey: .accountKey)
        try container.encode(self.accountLabel, forKey: .accountLabel)
        try container.encode(self.model, forKey: .model)
        try container.encode(self.successCount, forKey: .successCount)
        try container.encode(self.failureCount, forKey: .failureCount)
        try container.encode(self.authFailureCount, forKey: .authFailureCount)
        try container.encode(self.rateLimitCount, forKey: .rateLimitCount)
        try container.encode(self.quotaFailureCount, forKey: .quotaFailureCount)
        try container.encode(self.totalLatencyMS, forKey: .totalLatencyMS)
        try container.encode(self.p95LatencyMS, forKey: .p95LatencyMS)
        try container.encode(self.totalInputTokens, forKey: .totalInputTokens)
        try container.encode(self.totalOutputTokens, forKey: .totalOutputTokens)
        try container.encode(self.totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(self.lastError, forKey: .lastError)
    }
}

public struct AdminStatsSummary: Codable, Sendable, Equatable {
    public struct NaturalTimeBucketUsage: Codable, Sendable, Equatable {
        public var bucketStart: Int64
        public var windowSeconds: Int64
        public var requestCount: Int64
        public var inputTokens: Int64
        public var outputTokens: Int64
        public var cacheHitTokens: Int64
        public var cacheMissTokens: Int64

        public init(
            bucketStart: Int64,
            windowSeconds: Int64,
            requestCount: Int64 = 0,
            inputTokens: Int64 = 0,
            outputTokens: Int64 = 0,
            cacheHitTokens: Int64 = 0,
            cacheMissTokens: Int64 = 0
        ) {
            self.bucketStart = bucketStart
            self.windowSeconds = windowSeconds
            self.requestCount = requestCount
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheHitTokens = cacheHitTokens
            self.cacheMissTokens = cacheMissTokens
        }

        private enum CodingKeys: String, CodingKey {
            case bucketStart
            case windowSeconds
            case requestCount
            case inputTokens
            case outputTokens
            case cacheHitTokens
            case cacheMissTokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                bucketStart: try container.decode(Int64.self, forKey: .bucketStart),
                windowSeconds: try container.decode(Int64.self, forKey: .windowSeconds),
                requestCount: try container.decodeIfPresent(Int64.self, forKey: .requestCount) ?? 0,
                inputTokens: try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0,
                outputTokens: try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0,
                cacheHitTokens: try container.decodeIfPresent(Int64.self, forKey: .cacheHitTokens) ?? 0,
                cacheMissTokens: try container.decodeIfPresent(Int64.self, forKey: .cacheMissTokens) ?? 0
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.bucketStart, forKey: .bucketStart)
            try container.encode(self.windowSeconds, forKey: .windowSeconds)
            try container.encode(self.requestCount, forKey: .requestCount)
            try container.encode(self.inputTokens, forKey: .inputTokens)
            try container.encode(self.outputTokens, forKey: .outputTokens)
            try container.encode(self.cacheHitTokens, forKey: .cacheHitTokens)
            try container.encode(self.cacheMissTokens, forKey: .cacheMissTokens)
        }
    }

    public struct NaturalRangeTokenUsage: Codable, Sendable, Equatable {
        public var requestCount: Int64
        public var inputTokens: Int64
        public var outputTokens: Int64
        public var cacheHitTokens: Int64
        public var cacheMissTokens: Int64

        public init(requestCount: Int64 = 0, inputTokens: Int64 = 0, outputTokens: Int64 = 0, cacheHitTokens: Int64 = 0, cacheMissTokens: Int64 = 0) {
            self.requestCount = requestCount
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheHitTokens = cacheHitTokens
            self.cacheMissTokens = cacheMissTokens
        }

        private enum CodingKeys: String, CodingKey {
            case requestCount
            case inputTokens
            case outputTokens
            case cacheHitTokens
            case cacheMissTokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                requestCount: try container.decodeIfPresent(Int64.self, forKey: .requestCount) ?? 0,
                inputTokens: try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0,
                outputTokens: try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0,
                cacheHitTokens: try container.decodeIfPresent(Int64.self, forKey: .cacheHitTokens) ?? 0,
                cacheMissTokens: try container.decodeIfPresent(Int64.self, forKey: .cacheMissTokens) ?? 0
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.requestCount, forKey: .requestCount)
            try container.encode(self.inputTokens, forKey: .inputTokens)
            try container.encode(self.outputTokens, forKey: .outputTokens)
            try container.encode(self.cacheHitTokens, forKey: .cacheHitTokens)
            try container.encode(self.cacheMissTokens, forKey: .cacheMissTokens)
        }
    }

    public struct NaturalTokenUsageSummary: Codable, Sendable, Equatable {
        public var today: NaturalRangeTokenUsage
        public var week: NaturalRangeTokenUsage
        public var month: NaturalRangeTokenUsage
        public var dailyTrend: [NaturalTimeBucketUsage]
        public var weeklyTrend: [NaturalTimeBucketUsage]
        public var monthlyTrend: [NaturalTimeBucketUsage]

        public init(
            today: NaturalRangeTokenUsage = NaturalRangeTokenUsage(),
            week: NaturalRangeTokenUsage = NaturalRangeTokenUsage(),
            month: NaturalRangeTokenUsage = NaturalRangeTokenUsage(),
            dailyTrend: [NaturalTimeBucketUsage] = [],
            weeklyTrend: [NaturalTimeBucketUsage] = [],
            monthlyTrend: [NaturalTimeBucketUsage] = []
        ) {
            self.today = today
            self.week = week
            self.month = month
            self.dailyTrend = dailyTrend
            self.weeklyTrend = weeklyTrend
            self.monthlyTrend = monthlyTrend
        }

        private enum CodingKeys: String, CodingKey {
            case today
            case week
            case month
            case dailyTrend
            case weeklyTrend
            case monthlyTrend
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                today: try container.decodeIfPresent(NaturalRangeTokenUsage.self, forKey: .today)
                    ?? NaturalRangeTokenUsage(),
                week: try container.decodeIfPresent(NaturalRangeTokenUsage.self, forKey: .week)
                    ?? NaturalRangeTokenUsage(),
                month: try container.decodeIfPresent(NaturalRangeTokenUsage.self, forKey: .month)
                    ?? NaturalRangeTokenUsage(),
                dailyTrend: try container.decodeIfPresent([NaturalTimeBucketUsage].self, forKey: .dailyTrend) ?? [],
                weeklyTrend: try container.decodeIfPresent([NaturalTimeBucketUsage].self, forKey: .weeklyTrend) ?? [],
                monthlyTrend: try container.decodeIfPresent([NaturalTimeBucketUsage].self, forKey: .monthlyTrend) ?? []
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.today, forKey: .today)
            try container.encode(self.week, forKey: .week)
            try container.encode(self.month, forKey: .month)
            try container.encode(self.dailyTrend, forKey: .dailyTrend)
            try container.encode(self.weeklyTrend, forKey: .weeklyTrend)
            try container.encode(self.monthlyTrend, forKey: .monthlyTrend)
        }
    }

    public var totalRequests: Int64
    public var totalFailures: Int64
    public var totalAuthFailures: Int64
    public var totalRateLimits: Int64
    public var totalQuotaFailures: Int64
    public var totalInputTokens: Int64
    public var totalOutputTokens: Int64
    public var totalTokens: Int64
    public var naturalTokenUsage: NaturalTokenUsageSummary
    public var latestBuckets: [RequestMetricBucket]

    public init(
        totalRequests: Int64,
        totalFailures: Int64,
        totalAuthFailures: Int64,
        totalRateLimits: Int64,
        totalQuotaFailures: Int64,
        totalInputTokens: Int64,
        totalOutputTokens: Int64,
        totalTokens: Int64,
        naturalTokenUsage: NaturalTokenUsageSummary = NaturalTokenUsageSummary(),
        latestBuckets: [RequestMetricBucket]
    ) {
        self.totalRequests = totalRequests
        self.totalFailures = totalFailures
        self.totalAuthFailures = totalAuthFailures
        self.totalRateLimits = totalRateLimits
        self.totalQuotaFailures = totalQuotaFailures
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.naturalTokenUsage = naturalTokenUsage
        self.latestBuckets = latestBuckets
    }

    private enum CodingKeys: String, CodingKey {
        case totalRequests
        case totalFailures
        case totalAuthFailures
        case totalRateLimits
        case totalQuotaFailures
        case totalInputTokens
        case totalOutputTokens
        case totalTokens
        case naturalTokenUsage
        case latestBuckets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalRequests: try container.decode(Int64.self, forKey: .totalRequests),
            totalFailures: try container.decode(Int64.self, forKey: .totalFailures),
            totalAuthFailures: try container.decode(Int64.self, forKey: .totalAuthFailures),
            totalRateLimits: try container.decode(Int64.self, forKey: .totalRateLimits),
            totalQuotaFailures: try container.decode(Int64.self, forKey: .totalQuotaFailures),
            totalInputTokens: try container.decode(Int64.self, forKey: .totalInputTokens),
            totalOutputTokens: try container.decode(Int64.self, forKey: .totalOutputTokens),
            totalTokens: try container.decode(Int64.self, forKey: .totalTokens),
            naturalTokenUsage: try container.decodeIfPresent(NaturalTokenUsageSummary.self, forKey: .naturalTokenUsage)
                ?? NaturalTokenUsageSummary(),
            latestBuckets: try container.decode([RequestMetricBucket].self, forKey: .latestBuckets)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.totalRequests, forKey: .totalRequests)
        try container.encode(self.totalFailures, forKey: .totalFailures)
        try container.encode(self.totalAuthFailures, forKey: .totalAuthFailures)
        try container.encode(self.totalRateLimits, forKey: .totalRateLimits)
        try container.encode(self.totalQuotaFailures, forKey: .totalQuotaFailures)
        try container.encode(self.totalInputTokens, forKey: .totalInputTokens)
        try container.encode(self.totalOutputTokens, forKey: .totalOutputTokens)
        try container.encode(self.totalTokens, forKey: .totalTokens)
        try container.encode(self.naturalTokenUsage, forKey: .naturalTokenUsage)
        try container.encode(self.latestBuckets, forKey: .latestBuckets)
    }
}

public struct ProxyAPIKeyUsageEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { self.apiKeyHash }
    public var apiKeyHash: String
    public var apiKey: String
    public var label: String?
    public var dataSource: ProxyDataSource
    public var enabled: Bool?
    public var isPrimary: Bool
    public var requestCount: Int64
    public var failureCount: Int64
    public var authFailureCount: Int64
    public var rateLimitCount: Int64
    public var quotaFailureCount: Int64
    public var averageLatencyMS: Int64
    public var totalInputTokens: Int64
    public var totalOutputTokens: Int64
    public var totalTokens: Int64
    public var lastUsedAt: Int64?

    public init(
        apiKeyHash: String,
        apiKey: String,
        label: String? = nil,
        dataSource: ProxyDataSource = .openAI,
        enabled: Bool? = nil,
        isPrimary: Bool = false,
        requestCount: Int64 = 0,
        failureCount: Int64 = 0,
        authFailureCount: Int64 = 0,
        rateLimitCount: Int64 = 0,
        quotaFailureCount: Int64 = 0,
        averageLatencyMS: Int64 = 0,
        totalInputTokens: Int64 = 0,
        totalOutputTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        lastUsedAt: Int64? = nil
    ) {
        self.apiKeyHash = apiKeyHash
        self.apiKey = apiKey
        self.label = label
        self.dataSource = dataSource
        self.enabled = enabled
        self.isPrimary = isPrimary
        self.requestCount = requestCount
        self.failureCount = failureCount
        self.authFailureCount = authFailureCount
        self.rateLimitCount = rateLimitCount
        self.quotaFailureCount = quotaFailureCount
        self.averageLatencyMS = averageLatencyMS
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case apiKeyHash
        case apiKey
        case label
        case dataSource
        case enabled
        case isPrimary
        case requestCount
        case failureCount
        case authFailureCount
        case rateLimitCount
        case quotaFailureCount
        case averageLatencyMS
        case averageLatencyMs
        case totalInputTokens
        case totalOutputTokens
        case totalTokens
        case lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            apiKeyHash: try container.decode(String.self, forKey: .apiKeyHash),
            apiKey: try container.decode(String.self, forKey: .apiKey),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            dataSource: try container.decodeIfPresent(ProxyDataSource.self, forKey: .dataSource) ?? .openAI,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled),
            isPrimary: try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false,
            requestCount: try container.decodeIfPresent(Int64.self, forKey: .requestCount) ?? 0,
            failureCount: try container.decodeIfPresent(Int64.self, forKey: .failureCount) ?? 0,
            authFailureCount: try container.decodeIfPresent(Int64.self, forKey: .authFailureCount) ?? 0,
            rateLimitCount: try container.decodeIfPresent(Int64.self, forKey: .rateLimitCount) ?? 0,
            quotaFailureCount: try container.decodeIfPresent(Int64.self, forKey: .quotaFailureCount) ?? 0,
            averageLatencyMS: try container.decodeIfPresent(Int64.self, forKey: .averageLatencyMS)
                ?? container.decodeIfPresent(Int64.self, forKey: .averageLatencyMs)
                ?? 0,
            totalInputTokens: try container.decodeIfPresent(Int64.self, forKey: .totalInputTokens) ?? 0,
            totalOutputTokens: try container.decodeIfPresent(Int64.self, forKey: .totalOutputTokens) ?? 0,
            totalTokens: try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0,
            lastUsedAt: try container.decodeIfPresent(Int64.self, forKey: .lastUsedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.apiKeyHash, forKey: .apiKeyHash)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encodeIfPresent(self.label, forKey: .label)
        try container.encode(self.dataSource, forKey: .dataSource)
        try container.encodeIfPresent(self.enabled, forKey: .enabled)
        try container.encode(self.isPrimary, forKey: .isPrimary)
        try container.encode(self.requestCount, forKey: .requestCount)
        try container.encode(self.failureCount, forKey: .failureCount)
        try container.encode(self.authFailureCount, forKey: .authFailureCount)
        try container.encode(self.rateLimitCount, forKey: .rateLimitCount)
        try container.encode(self.quotaFailureCount, forKey: .quotaFailureCount)
        try container.encode(self.averageLatencyMS, forKey: .averageLatencyMS)
        try container.encode(self.totalInputTokens, forKey: .totalInputTokens)
        try container.encode(self.totalOutputTokens, forKey: .totalOutputTokens)
        try container.encode(self.totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(self.lastUsedAt, forKey: .lastUsedAt)
    }
}

public struct ProxyAPIKeyUsageReport: Codable, Sendable, Equatable {
    public var from: Int64
    public var to: Int64
    public var totalRequests: Int64
    public var totalFailures: Int64
    public var totalInputTokens: Int64
    public var totalOutputTokens: Int64
    public var totalTokens: Int64
    public var entries: [ProxyAPIKeyUsageEntry]

    public init(
        from: Int64,
        to: Int64,
        totalRequests: Int64 = 0,
        totalFailures: Int64 = 0,
        totalInputTokens: Int64 = 0,
        totalOutputTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        entries: [ProxyAPIKeyUsageEntry] = []
    ) {
        self.from = from
        self.to = to
        self.totalRequests = totalRequests
        self.totalFailures = totalFailures
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.entries = entries
    }
}

public enum RequestLogTimePreset: String, Codable, Sendable, CaseIterable, Equatable {
    case last15Minutes = "15m"
    case lastHour = "1h"
    case last24Hours = "24h"
    case last7Days = "7d"
    case custom

    public var durationSeconds: Int64? {
        switch self {
        case .last15Minutes:
            return 900
        case .lastHour:
            return 3_600
        case .last24Hours:
            return 86_400
        case .last7Days:
            return 604_800
        case .custom:
            return nil
        }
    }
}

public enum RequestLogSortField: String, Codable, Sendable, CaseIterable, Equatable {
    case time
    case endpoint
    case model
    case accountLabel = "account_label"
    case status
    case latency
    case totalTokens = "total_tokens"
}

public enum RequestLogSortDirection: String, Codable, Sendable, CaseIterable, Equatable {
    case ascending = "asc"
    case descending = "desc"
}

public enum RequestLogClientSource: String, Codable, Sendable, CaseIterable, Equatable {
    case codex
    case claudeCode = "claude_code"
    case gemini
    case other
}

public struct RequestLogEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var timestamp: Int64
    public var endpoint: String
    public var upstreamURL: String?
    public var clientSource: RequestLogClientSource
    public var model: String
    public var actualModel: String?
    public var reasoningEffort: String?
    public var apiKey: String
    public var accountKey: String
    public var accountLabel: String
    public var success: Bool
    public var latencyMS: Int64
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var totalTokens: Int64
    public var cacheHitTokens: Int64?
    public var failureCategory: String
    public var errorSummary: String?
    public var hasDiagnosticRequestBody: Bool

    public init(
        id: Int64,
        timestamp: Int64,
        endpoint: String,
        upstreamURL: String? = nil,
        clientSource: RequestLogClientSource = .other,
        model: String,
        actualModel: String? = nil,
        reasoningEffort: String? = nil,
        apiKey: String,
        accountKey: String,
        accountLabel: String,
        success: Bool,
        latencyMS: Int64,
        inputTokens: Int64,
        outputTokens: Int64,
        totalTokens: Int64,
        cacheHitTokens: Int64?,
        failureCategory: String,
        errorSummary: String?,
        hasDiagnosticRequestBody: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.upstreamURL = upstreamURL
        self.clientSource = clientSource
        self.model = model
        self.actualModel = actualModel
        self.reasoningEffort = reasoningEffort
        self.apiKey = apiKey
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.success = success
        self.latencyMS = latencyMS
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheHitTokens = cacheHitTokens
        self.failureCategory = failureCategory
        self.errorSummary = errorSummary
        self.hasDiagnosticRequestBody = hasDiagnosticRequestBody
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case endpoint
        case upstreamURL
        case upstreamUrl
        case upstream_url = "upstream_url"
        case clientSource
        case client_source = "client_source"
        case model
        case actualModel
        case actual_model = "actual_model"
        case reasoningEffort
        case reasoning_effort = "reasoning_effort"
        case apiKey
        case apiKeyValue
        case accountKey
        case accountLabel
        case success
        case latencyMS
        case latencyMs
        case inputTokens
        case outputTokens
        case totalTokens
        case cacheHitTokens
        case errorSummary
        case failureCategory
        case hasDiagnosticRequestBody
        case has_diagnostic_request_body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(Int64.self, forKey: .id),
            timestamp: try container.decode(Int64.self, forKey: .timestamp),
            endpoint: try container.decode(String.self, forKey: .endpoint),
            upstreamURL: try container.decodeIfPresent(String.self, forKey: .upstreamURL)
                ?? container.decodeIfPresent(String.self, forKey: .upstreamUrl)
                ?? container.decodeIfPresent(String.self, forKey: .upstream_url),
            clientSource: RequestLogClientSource(
                rawValue: try container.decodeIfPresent(String.self, forKey: .clientSource)
                    ?? container.decodeIfPresent(String.self, forKey: .client_source)
                    ?? RequestLogClientSource.other.rawValue
            ) ?? .other,
            model: try container.decode(String.self, forKey: .model),
            actualModel: try container.decodeIfPresent(String.self, forKey: .actualModel)
                ?? container.decodeIfPresent(String.self, forKey: .actual_model),
            reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
                ?? container.decodeIfPresent(String.self, forKey: .reasoning_effort),
            apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey)
                ?? container.decodeIfPresent(String.self, forKey: .apiKeyValue)
                ?? "",
            accountKey: try container.decode(String.self, forKey: .accountKey),
            accountLabel: try container.decode(String.self, forKey: .accountLabel),
            success: try container.decode(Bool.self, forKey: .success),
            latencyMS: try container.decodeIfPresent(Int64.self, forKey: .latencyMS)
                ?? container.decode(Int64.self, forKey: .latencyMs),
            inputTokens: try container.decode(Int64.self, forKey: .inputTokens),
            outputTokens: try container.decode(Int64.self, forKey: .outputTokens),
            totalTokens: try container.decode(Int64.self, forKey: .totalTokens),
            cacheHitTokens: try container.decodeIfPresent(Int64.self, forKey: .cacheHitTokens),
            failureCategory: try container.decodeIfPresent(String.self, forKey: .failureCategory) ?? ProxyRequestTrace.FailureCategory.none.rawValue,
            errorSummary: try container.decodeIfPresent(String.self, forKey: .errorSummary),
            hasDiagnosticRequestBody: try container.decodeIfPresent(Bool.self, forKey: .hasDiagnosticRequestBody)
                ?? container.decodeIfPresent(Bool.self, forKey: .has_diagnostic_request_body)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.timestamp, forKey: .timestamp)
        try container.encode(self.endpoint, forKey: .endpoint)
        try container.encodeIfPresent(self.upstreamURL, forKey: .upstream_url)
        try container.encode(self.clientSource.rawValue, forKey: .clientSource)
        try container.encode(self.model, forKey: .model)
        try container.encodeIfPresent(self.actualModel, forKey: .actualModel)
        try container.encodeIfPresent(self.reasoningEffort, forKey: .reasoningEffort)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encode(self.accountKey, forKey: .accountKey)
        try container.encode(self.accountLabel, forKey: .accountLabel)
        try container.encode(self.success, forKey: .success)
        try container.encode(self.latencyMS, forKey: .latencyMS)
        try container.encode(self.inputTokens, forKey: .inputTokens)
        try container.encode(self.outputTokens, forKey: .outputTokens)
        try container.encode(self.totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(self.cacheHitTokens, forKey: .cacheHitTokens)
        try container.encode(self.failureCategory, forKey: .failureCategory)
        try container.encodeIfPresent(self.errorSummary, forKey: .errorSummary)
        try container.encode(self.hasDiagnosticRequestBody, forKey: .hasDiagnosticRequestBody)
    }
}

public struct RequestLogQuery: Codable, Sendable, Equatable {
    public var timePreset: RequestLogTimePreset
    public var from: Int64?
    public var to: Int64?
    public var apiKey: String?
    public var accountKey: String?
    public var clientSource: RequestLogClientSource?
    public var model: String?
    public var sortBy: RequestLogSortField
    public var sortDirection: RequestLogSortDirection
    public var page: Int
    public var pageSize: Int

    public init(
        timePreset: RequestLogTimePreset = .last24Hours,
        from: Int64? = nil,
        to: Int64? = nil,
        apiKey: String? = nil,
        accountKey: String? = nil,
        clientSource: RequestLogClientSource? = nil,
        model: String? = nil,
        sortBy: RequestLogSortField = .time,
        sortDirection: RequestLogSortDirection = .descending,
        page: Int = 1,
        pageSize: Int = 50
    ) {
        self.timePreset = timePreset
        self.from = from
        self.to = to
        self.apiKey = apiKey
        self.accountKey = accountKey
        self.clientSource = clientSource
        self.model = model
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.page = page
        self.pageSize = pageSize
    }

    public func normalized() -> RequestLogQuery {
        var copy = self
        copy.apiKey = self.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.apiKey?.isEmpty == true {
            copy.apiKey = nil
        }
        copy.accountKey = self.accountKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.accountKey?.isEmpty == true {
            copy.accountKey = nil
        }
        copy.model = self.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.model?.isEmpty == true {
            copy.model = nil
        }
        copy.page = max(1, self.page)
        copy.pageSize = min(max(1, self.pageSize), 200)
        return copy
    }

    public func effectiveTimeBounds(now: Int64 = Helpers.now()) -> (from: Int64, to: Int64) {
        let normalized = self.normalized()
        if let duration = normalized.timePreset.durationSeconds {
            return (max(0, now - duration), now)
        }

        let upperBound = normalized.to ?? now
        let lowerBound = normalized.from ?? max(0, upperBound - 86_400)
        return lowerBound <= upperBound ? (lowerBound, upperBound) : (upperBound, lowerBound)
    }

    public func timeRangeOnly() -> RequestLogQuery {
        var copy = self.normalized()
        copy.apiKey = nil
        copy.accountKey = nil
        copy.model = nil
        copy.page = 1
        return copy
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "time_preset", value: self.timePreset.rawValue),
            URLQueryItem(name: "sort_by", value: self.sortBy.rawValue),
            URLQueryItem(name: "sort_direction", value: self.sortDirection.rawValue),
            URLQueryItem(name: "page", value: "\(self.page)"),
            URLQueryItem(name: "page_size", value: "\(self.pageSize)"),
        ]
        if let from {
            items.append(URLQueryItem(name: "from", value: "\(from)"))
        }
        if let to {
            items.append(URLQueryItem(name: "to", value: "\(to)"))
        }
        if let apiKey, !apiKey.isEmpty {
            items.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        if let accountKey, !accountKey.isEmpty {
            items.append(URLQueryItem(name: "account_key", value: accountKey))
        }
        if let clientSource {
            items.append(URLQueryItem(name: "client_source", value: clientSource.rawValue))
        }
        if let model, !model.isEmpty {
            items.append(URLQueryItem(name: "model", value: model))
        }
        return items
    }
}

public struct RequestLogFilterOptions: Codable, Sendable, Equatable {
    public var availableAPIKeys: [String]
    public var availableModels: [String]

    public init(
        availableAPIKeys: [String] = [],
        availableModels: [String] = []
    ) {
        self.availableAPIKeys = availableAPIKeys
        self.availableModels = availableModels
    }

    private enum CodingKeys: String, CodingKey {
        case availableAPIKeys
        case availableApiKeys
        case availableModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            availableAPIKeys: try container.decodeIfPresent([String].self, forKey: .availableAPIKeys)
                ?? container.decodeIfPresent([String].self, forKey: .availableApiKeys)
                ?? [],
            availableModels: try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.availableAPIKeys, forKey: .availableAPIKeys)
        try container.encode(self.availableModels, forKey: .availableModels)
    }
}

public struct RequestLogPage: Codable, Sendable, Equatable {
    public var entries: [RequestLogEntry]
    public var totalCount: Int64
    public var page: Int
    public var pageSize: Int
    public var availableAPIKeys: [String]
    public var availableModels: [String]

    public init(
        entries: [RequestLogEntry] = [],
        totalCount: Int64 = 0,
        page: Int = 1,
        pageSize: Int = 50,
        availableAPIKeys: [String] = [],
        availableModels: [String] = []
    ) {
        self.entries = entries
        self.totalCount = totalCount
        self.page = page
        self.pageSize = pageSize
        self.availableAPIKeys = availableAPIKeys
        self.availableModels = availableModels
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case totalCount
        case page
        case pageSize
        case availableAPIKeys
        case availableApiKeys
        case availableModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entries: try container.decodeIfPresent([RequestLogEntry].self, forKey: .entries) ?? [],
            totalCount: try container.decodeIfPresent(Int64.self, forKey: .totalCount) ?? 0,
            page: try container.decodeIfPresent(Int.self, forKey: .page) ?? 1,
            pageSize: try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 50,
            availableAPIKeys: try container.decodeIfPresent([String].self, forKey: .availableAPIKeys)
                ?? container.decodeIfPresent([String].self, forKey: .availableApiKeys)
                ?? [],
            availableModels: try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.entries, forKey: .entries)
        try container.encode(self.totalCount, forKey: .totalCount)
        try container.encode(self.page, forKey: .page)
        try container.encode(self.pageSize, forKey: .pageSize)
        try container.encode(self.availableAPIKeys, forKey: .availableAPIKeys)
        try container.encode(self.availableModels, forKey: .availableModels)
    }
}

public struct ReasoningCacheAccountSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { self.accountKey }
    public var accountKey: String
    public var accountLabel: String
    public var entryCount: Int
    public var expiredCount: Int
    public var oldestTouchedAt: Int64?
    public var newestTouchedAt: Int64?

    public init(
        accountKey: String,
        accountLabel: String,
        entryCount: Int,
        expiredCount: Int,
        oldestTouchedAt: Int64?,
        newestTouchedAt: Int64?
    ) {
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.entryCount = max(0, entryCount)
        self.expiredCount = max(0, expiredCount)
        self.oldestTouchedAt = oldestTouchedAt
        self.newestTouchedAt = newestTouchedAt
    }
}

public struct ReasoningCacheSummary: Codable, Sendable, Equatable {
    public var totalCount: Int
    public var expiredCount: Int
    public var oldestTouchedAt: Int64?
    public var newestTouchedAt: Int64?
    public var accounts: [ReasoningCacheAccountSummary]

    public init(
        totalCount: Int = 0,
        expiredCount: Int = 0,
        oldestTouchedAt: Int64? = nil,
        newestTouchedAt: Int64? = nil,
        accounts: [ReasoningCacheAccountSummary] = []
    ) {
        self.totalCount = max(0, totalCount)
        self.expiredCount = max(0, expiredCount)
        self.oldestTouchedAt = oldestTouchedAt
        self.newestTouchedAt = newestTouchedAt
        self.accounts = accounts
    }
}

public struct ClearReasoningCacheRequest: Codable, Sendable, Equatable {
    public var expiredOnly: Bool
    public var accountKeys: [String]
    public var olderThanSeconds: Int64?
    public var clearAll: Bool

    public init(
        expiredOnly: Bool = false,
        accountKeys: [String] = [],
        olderThanSeconds: Int64? = nil,
        clearAll: Bool = false
    ) {
        self.expiredOnly = expiredOnly
        self.accountKeys = accountKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.olderThanSeconds = olderThanSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.clearAll = clearAll
    }

    private enum CodingKeys: String, CodingKey {
        case expiredOnly
        case expiredOnlySnake = "expired_only"
        case accountKeys
        case accountKeysSnake = "account_keys"
        case olderThanSeconds
        case olderThanSecondsSnake = "older_than_seconds"
        case clearAll
        case clearAllSnake = "clear_all"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            expiredOnly: try container.decodeIfPresent(Bool.self, forKey: .expiredOnly)
                ?? container.decodeIfPresent(Bool.self, forKey: .expiredOnlySnake)
                ?? false,
            accountKeys: try container.decodeIfPresent([String].self, forKey: .accountKeys)
                ?? container.decodeIfPresent([String].self, forKey: .accountKeysSnake)
                ?? [],
            olderThanSeconds: try container.decodeIfPresent(Int64.self, forKey: .olderThanSeconds)
                ?? container.decodeIfPresent(Int64.self, forKey: .olderThanSecondsSnake),
            clearAll: try container.decodeIfPresent(Bool.self, forKey: .clearAll)
                ?? container.decodeIfPresent(Bool.self, forKey: .clearAllSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.expiredOnly, forKey: .expiredOnly)
        try container.encode(self.accountKeys, forKey: .accountKeys)
        try container.encodeIfPresent(self.olderThanSeconds, forKey: .olderThanSeconds)
        try container.encode(self.clearAll, forKey: .clearAll)
    }
}

public struct ClearReasoningCacheResult: Codable, Sendable, Equatable {
    public var deletedCount: Int
    public var summary: ReasoningCacheSummary

    public init(deletedCount: Int, summary: ReasoningCacheSummary) {
        self.deletedCount = max(0, deletedCount)
        self.summary = summary
    }
}

public struct OCRCacheSummary: Codable, Sendable, Equatable {
    public var totalCount: Int
    public var expiredCount: Int
    public var oldestTouchedAt: Int64?
    public var newestTouchedAt: Int64?

    public init(
        totalCount: Int = 0,
        expiredCount: Int = 0,
        oldestTouchedAt: Int64? = nil,
        newestTouchedAt: Int64? = nil
    ) {
        self.totalCount = max(0, totalCount)
        self.expiredCount = max(0, expiredCount)
        self.oldestTouchedAt = oldestTouchedAt
        self.newestTouchedAt = newestTouchedAt
    }
}

public struct ClearOCRCacheRequest: Codable, Sendable, Equatable {
    public var expiredOnly: Bool
    public var olderThanSeconds: Int64?
    public var clearAll: Bool

    public init(
        expiredOnly: Bool = false,
        olderThanSeconds: Int64? = nil,
        clearAll: Bool = false
    ) {
        self.expiredOnly = expiredOnly
        self.olderThanSeconds = olderThanSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.clearAll = clearAll
    }

    private enum CodingKeys: String, CodingKey {
        case expiredOnly
        case expiredOnlySnake = "expired_only"
        case olderThanSeconds
        case olderThanSecondsSnake = "older_than_seconds"
        case clearAll
        case clearAllSnake = "clear_all"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            expiredOnly: try container.decodeIfPresent(Bool.self, forKey: .expiredOnly)
                ?? container.decodeIfPresent(Bool.self, forKey: .expiredOnlySnake)
                ?? false,
            olderThanSeconds: try container.decodeIfPresent(Int64.self, forKey: .olderThanSeconds)
                ?? container.decodeIfPresent(Int64.self, forKey: .olderThanSecondsSnake),
            clearAll: try container.decodeIfPresent(Bool.self, forKey: .clearAll)
                ?? container.decodeIfPresent(Bool.self, forKey: .clearAllSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.expiredOnly, forKey: .expiredOnly)
        try container.encodeIfPresent(self.olderThanSeconds, forKey: .olderThanSeconds)
        try container.encode(self.clearAll, forKey: .clearAll)
    }
}

public struct ClearOCRCacheResult: Codable, Sendable, Equatable {
    public var deletedCount: Int
    public var summary: OCRCacheSummary

    public init(deletedCount: Int, summary: OCRCacheSummary) {
        self.deletedCount = max(0, deletedCount)
        self.summary = summary
    }
}

public enum DiagnosticRequestBodyCaptureStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case captured
    case skipped
    case failed
}

public struct DiagnosticRequestBodyEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var requestLogID: Int64?
    public var createdAt: Int64
    public var endpoint: String
    public var upstreamURL: String?
    public var accountKey: String
    public var accountLabel: String
    public var model: String
    public var actualModel: String?
    public var bodySHA256: String
    public var prefixSHA256: String
    public var byteCount: Int
    public var expiresAt: Int64
    public var status: DiagnosticRequestBodyCaptureStatus
    public var errorSummary: String?

    public init(
        id: Int64 = 0,
        requestLogID: Int64? = nil,
        createdAt: Int64 = Helpers.now(),
        endpoint: String = "",
        upstreamURL: String? = nil,
        accountKey: String = "",
        accountLabel: String = "",
        model: String = "",
        actualModel: String? = nil,
        bodySHA256: String = "",
        prefixSHA256: String = "",
        byteCount: Int = 0,
        expiresAt: Int64 = Helpers.now(),
        status: DiagnosticRequestBodyCaptureStatus = .captured,
        errorSummary: String? = nil
    ) {
        self.id = id
        self.requestLogID = requestLogID
        self.createdAt = createdAt
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = upstreamURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.upstreamURL = normalizedURL.isEmpty ? nil : normalizedURL
        self.accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedActualModel = actualModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.actualModel = normalizedActualModel.isEmpty ? nil : normalizedActualModel
        self.bodySHA256 = bodySHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prefixSHA256 = prefixSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byteCount = max(0, byteCount)
        self.expiresAt = expiresAt
        self.status = status
        let normalizedError = errorSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.errorSummary = normalizedError.isEmpty ? nil : normalizedError
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case requestLogID
        case requestLogIDAlt = "requestLogId"
        case createdAt
        case endpoint
        case upstreamURL
        case upstreamURLAlt = "upstreamUrl"
        case accountKey
        case accountLabel
        case model
        case actualModel
        case bodySHA256
        case bodySHA256Alt = "bodySha256"
        case prefixSHA256
        case prefixSHA256Alt = "prefixSha256"
        case byteCount
        case expiresAt
        case status
        case errorSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0,
            requestLogID: try container.decodeIfPresent(Int64.self, forKey: .requestLogID)
                ?? container.decodeIfPresent(Int64.self, forKey: .requestLogIDAlt),
            createdAt: try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? Helpers.now(),
            endpoint: try container.decodeIfPresent(String.self, forKey: .endpoint) ?? "",
            upstreamURL: try container.decodeIfPresent(String.self, forKey: .upstreamURL)
                ?? container.decodeIfPresent(String.self, forKey: .upstreamURLAlt),
            accountKey: try container.decodeIfPresent(String.self, forKey: .accountKey) ?? "",
            accountLabel: try container.decodeIfPresent(String.self, forKey: .accountLabel) ?? "",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
            actualModel: try container.decodeIfPresent(String.self, forKey: .actualModel),
            bodySHA256: try container.decodeIfPresent(String.self, forKey: .bodySHA256)
                ?? container.decodeIfPresent(String.self, forKey: .bodySHA256Alt)
                ?? "",
            prefixSHA256: try container.decodeIfPresent(String.self, forKey: .prefixSHA256)
                ?? container.decodeIfPresent(String.self, forKey: .prefixSHA256Alt)
                ?? "",
            byteCount: try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0,
            expiresAt: try container.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? Helpers.now(),
            status: try container.decodeIfPresent(DiagnosticRequestBodyCaptureStatus.self, forKey: .status) ?? .captured,
            errorSummary: try container.decodeIfPresent(String.self, forKey: .errorSummary)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encodeIfPresent(self.requestLogID, forKey: .requestLogID)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encode(self.endpoint, forKey: .endpoint)
        try container.encodeIfPresent(self.upstreamURL, forKey: .upstreamURL)
        try container.encode(self.accountKey, forKey: .accountKey)
        try container.encode(self.accountLabel, forKey: .accountLabel)
        try container.encode(self.model, forKey: .model)
        try container.encodeIfPresent(self.actualModel, forKey: .actualModel)
        try container.encode(self.bodySHA256, forKey: .bodySHA256)
        try container.encode(self.prefixSHA256, forKey: .prefixSHA256)
        try container.encode(self.byteCount, forKey: .byteCount)
        try container.encode(self.expiresAt, forKey: .expiresAt)
        try container.encode(self.status, forKey: .status)
        try container.encodeIfPresent(self.errorSummary, forKey: .errorSummary)
    }
}

public struct DiagnosticRequestBodySummary: Codable, Sendable, Equatable {
    public var totalCount: Int
    public var capturedCount: Int
    public var expiredCount: Int
    public var totalBytes: Int64
    public var oldestCreatedAt: Int64?
    public var newestCreatedAt: Int64?

    public init(
        totalCount: Int = 0,
        capturedCount: Int = 0,
        expiredCount: Int = 0,
        totalBytes: Int64 = 0,
        oldestCreatedAt: Int64? = nil,
        newestCreatedAt: Int64? = nil
    ) {
        self.totalCount = max(0, totalCount)
        self.capturedCount = max(0, capturedCount)
        self.expiredCount = max(0, expiredCount)
        self.totalBytes = max(0, totalBytes)
        self.oldestCreatedAt = oldestCreatedAt
        self.newestCreatedAt = newestCreatedAt
    }
}

public struct ClearDiagnosticRequestBodiesRequest: Codable, Sendable, Equatable {
    public var expiredOnly: Bool
    public var olderThanSeconds: Int64?
    public var requestLogIDs: [Int64]
    public var clearAll: Bool

    public init(
        expiredOnly: Bool = false,
        olderThanSeconds: Int64? = nil,
        requestLogIDs: [Int64] = [],
        clearAll: Bool = false
    ) {
        self.expiredOnly = expiredOnly
        self.olderThanSeconds = olderThanSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.requestLogIDs = Array(Set(requestLogIDs.filter { $0 > 0 })).sorted()
        self.clearAll = clearAll
    }

    private enum CodingKeys: String, CodingKey {
        case expiredOnly
        case expiredOnlySnake = "expired_only"
        case olderThanSeconds
        case olderThanSecondsSnake = "older_than_seconds"
        case requestLogIDs
        case requestLogIDsAlt = "requestLogIds"
        case requestLogIDsSnake = "request_log_ids"
        case clearAll
        case clearAllSnake = "clear_all"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            expiredOnly: try container.decodeIfPresent(Bool.self, forKey: .expiredOnly)
                ?? container.decodeIfPresent(Bool.self, forKey: .expiredOnlySnake)
                ?? false,
            olderThanSeconds: try container.decodeIfPresent(Int64.self, forKey: .olderThanSeconds)
                ?? container.decodeIfPresent(Int64.self, forKey: .olderThanSecondsSnake),
            requestLogIDs: try container.decodeIfPresent([Int64].self, forKey: .requestLogIDs)
                ?? container.decodeIfPresent([Int64].self, forKey: .requestLogIDsAlt)
                ?? container.decodeIfPresent([Int64].self, forKey: .requestLogIDsSnake)
                ?? [],
            clearAll: try container.decodeIfPresent(Bool.self, forKey: .clearAll)
                ?? container.decodeIfPresent(Bool.self, forKey: .clearAllSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.expiredOnly, forKey: .expiredOnly)
        try container.encodeIfPresent(self.olderThanSeconds, forKey: .olderThanSeconds)
        try container.encode(self.requestLogIDs, forKey: .requestLogIDs)
        try container.encode(self.clearAll, forKey: .clearAll)
    }
}

public struct ClearDiagnosticRequestBodiesResult: Codable, Sendable, Equatable {
    public var deletedCount: Int
    public var summary: DiagnosticRequestBodySummary

    public init(deletedCount: Int, summary: DiagnosticRequestBodySummary) {
        self.deletedCount = max(0, deletedCount)
        self.summary = summary
    }
}

public struct DiagnosticRequestBodyDetail: Codable, Sendable, Equatable {
    public var entry: DiagnosticRequestBodyEntry
    public var bodyText: String?
    public var available: Bool
    public var message: String?

    public init(
        entry: DiagnosticRequestBodyEntry,
        bodyText: String? = nil,
        available: Bool = false,
        message: String? = nil
    ) {
        self.entry = entry
        self.bodyText = bodyText
        self.available = available
        self.message = message
    }
}

public enum OCRRecognitionLogStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case skipped
    case cacheHit = "cache_hit"
    case recognized
    case failed
}

public struct OCRRecognitionLogEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var createdAt: Int64
    public var endpoint: String
    public var accountKey: String
    public var accountLabel: String
    public var requestedModel: String
    public var ocrModel: String
    public var imageIndex: Int
    public var imageHash: String?
    public var mimeType: String
    public var byteCount: Int
    public var status: OCRRecognitionLogStatus
    public var cacheHit: Bool
    public var latencyMS: Int64
    public var errorSummary: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case endpoint
        case accountKey
        case accountLabel
        case requestedModel
        case ocrModel
        case imageIndex
        case imageHash
        case mimeType
        case byteCount
        case status
        case cacheHit
        case latencyMS = "latencyMs"
        case latencyMSCamel = "latencyMS"
        case errorSummary
    }

    public init(
        id: Int64 = 0,
        createdAt: Int64 = Helpers.now(),
        endpoint: String = "",
        accountKey: String = "",
        accountLabel: String = "",
        requestedModel: String = "",
        ocrModel: String = "",
        imageIndex: Int,
        imageHash: String? = nil,
        mimeType: String = "",
        byteCount: Int = 0,
        status: OCRRecognitionLogStatus,
        cacheHit: Bool = false,
        latencyMS: Int64 = 0,
        errorSummary: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestedModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ocrModel = ocrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageIndex = max(1, imageIndex)
        let normalizedImageHash = imageHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.imageHash = normalizedImageHash.isEmpty ? nil : normalizedImageHash
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byteCount = max(0, byteCount)
        self.status = status
        self.cacheHit = cacheHit
        self.latencyMS = max(0, latencyMS)
        let normalizedErrorSummary = errorSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.errorSummary = normalizedErrorSummary.isEmpty ? nil : normalizedErrorSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0,
            createdAt: try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? Helpers.now(),
            endpoint: try container.decodeIfPresent(String.self, forKey: .endpoint) ?? "",
            accountKey: try container.decodeIfPresent(String.self, forKey: .accountKey) ?? "",
            accountLabel: try container.decodeIfPresent(String.self, forKey: .accountLabel) ?? "",
            requestedModel: try container.decodeIfPresent(String.self, forKey: .requestedModel) ?? "",
            ocrModel: try container.decodeIfPresent(String.self, forKey: .ocrModel) ?? "",
            imageIndex: try container.decodeIfPresent(Int.self, forKey: .imageIndex) ?? 1,
            imageHash: try container.decodeIfPresent(String.self, forKey: .imageHash),
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "",
            byteCount: try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0,
            status: try container.decodeIfPresent(OCRRecognitionLogStatus.self, forKey: .status) ?? .failed,
            cacheHit: try container.decodeIfPresent(Bool.self, forKey: .cacheHit) ?? false,
            latencyMS: try container.decodeIfPresent(Int64.self, forKey: .latencyMS)
                ?? container.decodeIfPresent(Int64.self, forKey: .latencyMSCamel)
                ?? 0,
            errorSummary: try container.decodeIfPresent(String.self, forKey: .errorSummary)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encode(self.endpoint, forKey: .endpoint)
        try container.encode(self.accountKey, forKey: .accountKey)
        try container.encode(self.accountLabel, forKey: .accountLabel)
        try container.encode(self.requestedModel, forKey: .requestedModel)
        try container.encode(self.ocrModel, forKey: .ocrModel)
        try container.encode(self.imageIndex, forKey: .imageIndex)
        try container.encodeIfPresent(self.imageHash, forKey: .imageHash)
        try container.encode(self.mimeType, forKey: .mimeType)
        try container.encode(self.byteCount, forKey: .byteCount)
        try container.encode(self.status, forKey: .status)
        try container.encode(self.cacheHit, forKey: .cacheHit)
        try container.encode(self.latencyMS, forKey: .latencyMS)
        try container.encodeIfPresent(self.errorSummary, forKey: .errorSummary)
    }
}

public struct OCRRecognitionLogListRequest: Codable, Sendable, Equatable {
    public var status: OCRRecognitionLogStatus?
    public var limit: Int
    public var offset: Int

    public init(status: OCRRecognitionLogStatus? = nil, limit: Int = 50, offset: Int = 0) {
        self.status = status
        self.limit = min(max(limit, 1), 200)
        self.offset = max(0, offset)
    }
}

public struct OCRRecognitionLogListResponse: Codable, Sendable, Equatable {
    public var entries: [OCRRecognitionLogEntry]
    public var totalCount: Int

    public init(entries: [OCRRecognitionLogEntry] = [], totalCount: Int = 0) {
        self.entries = entries
        self.totalCount = max(0, totalCount)
    }
}

public struct OCRRecognitionResultLookupResponse: Codable, Sendable, Equatable {
    public var entry: OCRRecognitionLogEntry
    public var available: Bool
    public var text: String?
    public var message: String?

    public init(
        entry: OCRRecognitionLogEntry,
        available: Bool,
        text: String? = nil,
        message: String? = nil
    ) {
        self.entry = entry
        self.available = available
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.text = normalizedText.isEmpty ? nil : normalizedText
        self.message = normalizedMessage.isEmpty ? nil : normalizedMessage
    }
}

public struct OCRRecognitionLogSummary: Codable, Sendable, Equatable {
    public var totalCount: Int
    public var expiredCount: Int
    public var oldestCreatedAt: Int64?
    public var newestCreatedAt: Int64?

    public init(
        totalCount: Int = 0,
        expiredCount: Int = 0,
        oldestCreatedAt: Int64? = nil,
        newestCreatedAt: Int64? = nil
    ) {
        self.totalCount = max(0, totalCount)
        self.expiredCount = max(0, expiredCount)
        self.oldestCreatedAt = oldestCreatedAt
        self.newestCreatedAt = newestCreatedAt
    }
}

public struct ClearOCRRecognitionLogsRequest: Codable, Sendable, Equatable {
    public var expiredOnly: Bool
    public var olderThanSeconds: Int64?
    public var clearAll: Bool

    public init(
        expiredOnly: Bool = false,
        olderThanSeconds: Int64? = nil,
        clearAll: Bool = false
    ) {
        self.expiredOnly = expiredOnly
        self.olderThanSeconds = olderThanSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.clearAll = clearAll
    }

    private enum CodingKeys: String, CodingKey {
        case expiredOnly
        case expiredOnlySnake = "expired_only"
        case olderThanSeconds
        case olderThanSecondsSnake = "older_than_seconds"
        case clearAll
        case clearAllSnake = "clear_all"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            expiredOnly: try container.decodeIfPresent(Bool.self, forKey: .expiredOnly)
                ?? container.decodeIfPresent(Bool.self, forKey: .expiredOnlySnake)
                ?? false,
            olderThanSeconds: try container.decodeIfPresent(Int64.self, forKey: .olderThanSeconds)
                ?? container.decodeIfPresent(Int64.self, forKey: .olderThanSecondsSnake),
            clearAll: try container.decodeIfPresent(Bool.self, forKey: .clearAll)
                ?? container.decodeIfPresent(Bool.self, forKey: .clearAllSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.expiredOnly, forKey: .expiredOnly)
        try container.encodeIfPresent(self.olderThanSeconds, forKey: .olderThanSeconds)
        try container.encode(self.clearAll, forKey: .clearAll)
    }
}

public struct ClearOCRRecognitionLogsResult: Codable, Sendable, Equatable {
    public var deletedCount: Int
    public var summary: OCRRecognitionLogSummary

    public init(deletedCount: Int, summary: OCRRecognitionLogSummary) {
        self.deletedCount = max(0, deletedCount)
        self.summary = summary
    }
}


public struct OCRModelTestRequest: Codable, Sendable, Equatable {
    public var ocrModel: OCRModelConfig
    public var imageBase64: String
    public var mimeType: String
    public var prompt: String

    public init(
        ocrModel: OCRModelConfig,
        imageBase64: String,
        mimeType: String = "image/png",
        prompt: String = OCRModelConfig.defaultPrompt
    ) {
        self.ocrModel = ocrModel
        self.imageBase64 = imageBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMimeType = mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        self.mimeType = normalizedMimeType.isEmpty ? "image/png" : normalizedMimeType
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = normalizedPrompt.isEmpty ? OCRModelConfig.defaultPrompt : normalizedPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case ocrModel
        case ocrModelSnake = "ocr_model"
        case imageBase64
        case imageBase64Snake = "image_base64"
        case mimeType
        case mimeTypeSnake = "mime_type"
        case prompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ocrModel: try container.decodeIfPresent(OCRModelConfig.self, forKey: .ocrModel)
                ?? container.decodeIfPresent(OCRModelConfig.self, forKey: .ocrModelSnake)
                ?? .init(),
            imageBase64: try container.decodeIfPresent(String.self, forKey: .imageBase64)
                ?? container.decodeIfPresent(String.self, forKey: .imageBase64Snake)
                ?? "",
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
                ?? container.decodeIfPresent(String.self, forKey: .mimeTypeSnake)
                ?? "image/png",
            prompt: try container.decodeIfPresent(String.self, forKey: .prompt) ?? OCRModelConfig.defaultPrompt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.ocrModel, forKey: .ocrModel)
        try container.encode(self.imageBase64, forKey: .imageBase64)
        try container.encode(self.mimeType, forKey: .mimeType)
        try container.encode(self.prompt, forKey: .prompt)
    }
}

public struct OCRModelTestResult: Codable, Sendable, Equatable {
    public var text: String
    public var modelLabel: String
    public var latencyMS: Int64
    public var cacheHit: Bool
    public var imageHash: String
    public var mimeType: String
    public var byteCount: Int

    public init(
        text: String,
        modelLabel: String,
        latencyMS: Int64,
        cacheHit: Bool,
        imageHash: String,
        mimeType: String,
        byteCount: Int
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelLabel = modelLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latencyMS = max(0, latencyMS)
        self.cacheHit = cacheHit
        self.imageHash = imageHash.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byteCount = max(0, byteCount)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case modelLabel
        case latencyMS = "latencyMs"
        case latencyMSCamel = "latencyMS"
        case cacheHit
        case imageHash
        case mimeType
        case byteCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            modelLabel: try container.decodeIfPresent(String.self, forKey: .modelLabel) ?? "",
            latencyMS: try container.decodeIfPresent(Int64.self, forKey: .latencyMS)
                ?? container.decodeIfPresent(Int64.self, forKey: .latencyMSCamel)
                ?? 0,
            cacheHit: try container.decodeIfPresent(Bool.self, forKey: .cacheHit) ?? false,
            imageHash: try container.decodeIfPresent(String.self, forKey: .imageHash) ?? "",
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "",
            byteCount: try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.text, forKey: .text)
        try container.encode(self.modelLabel, forKey: .modelLabel)
        try container.encode(self.latencyMS, forKey: .latencyMS)
        try container.encode(self.cacheHit, forKey: .cacheHit)
        try container.encode(self.imageHash, forKey: .imageHash)
        try container.encode(self.mimeType, forKey: .mimeType)
        try container.encode(self.byteCount, forKey: .byteCount)
    }
}

public struct PreparedOAuthLogin: Codable, Sendable, Equatable {
    public var providerFamily: AccountProviderFamily
    public var authURL: String
    public var redirectURI: String

    public init(providerFamily: AccountProviderFamily = .openAI, authURL: String, redirectURI: String) {
        self.providerFamily = providerFamily
        self.authURL = authURL
        self.redirectURI = redirectURI
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode([String: String].self)

        guard let authURL = payload["auth_url"] ?? payload["authURL"] ?? payload["authUrl"] else {
            throw DecodingError.keyNotFound(
                FlexibleCodingKey(stringValue: "auth_url"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing auth_url")
            )
        }
        guard let redirectURI = payload["redirect_uri"] ?? payload["redirectURI"] ?? payload["redirectUri"] else {
            throw DecodingError.keyNotFound(
                FlexibleCodingKey(stringValue: "redirect_uri"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing redirect_uri")
            )
        }

        self.providerFamily = AccountProviderFamily(
            rawValue: payload["provider_family"] ?? payload["providerFamily"] ?? payload["provider"] ?? ""
        ) ?? .openAI
        self.authURL = authURL
        self.redirectURI = redirectURI
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "provider_family": self.providerFamily.rawValue,
            "auth_url": self.authURL,
            "redirect_uri": self.redirectURI,
        ])
    }
}

public struct AnthropicOAuthSecretBundle: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Int64?
    public var tokenType: String?
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Int64? = nil,
        tokenType: String? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
    }
}

public struct GeminiOAuthSecretBundle: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Int64?
    public var tokenType: String?
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Int64? = nil,
        tokenType: String? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
    }
}

private struct FlexibleCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

public struct AuthJsonImportInput: Codable, Sendable, Equatable {
    public var source: String
    public var content: String
    public var label: String?
    public var enabled: Bool?
    public var managedProxyNodeName: String?
    public var modelRouting: AccountModelRoutingConfig?
    public var reasoningEffort: AccountReasoningEffortConfig?
    public var automaticCooldownDisabled: Bool?

    public init(
        source: String,
        content: String,
        label: String? = nil,
        enabled: Bool? = nil,
        managedProxyNodeName: String? = nil,
        modelRouting: AccountModelRoutingConfig? = nil,
        reasoningEffort: AccountReasoningEffortConfig? = nil,
        automaticCooldownDisabled: Bool? = nil
    ) {
        self.source = source
        self.content = content
        self.label = label
        self.enabled = enabled
        self.managedProxyNodeName = AccountSummary.normalizedManagedProxyNodeName(managedProxyNodeName)
        self.modelRouting = AccountSummary.normalizedModelRouting(modelRouting)
        self.reasoningEffort = reasoningEffort
        self.automaticCooldownDisabled = automaticCooldownDisabled
    }
}

public enum ManualAPIKeyBaseURLMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case legacyAppendV1 = "legacy_append_v1"
    case exactAPIPrefix = "exact_api_prefix"
}

public enum ManualAPIKeyUpstreamAdapter: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case responses
    case chatCompletions = "chat_completions"
}

public struct ManualAPIKeyAccountInput: Codable, Sendable, Equatable {
    public var label: String?
    public var providerPreset: OpenAICompatibleProviderPreset
    public var baseURL: String
    public var baseURLMode: ManualAPIKeyBaseURLMode?
    public var upstreamAdapter: ManualAPIKeyUpstreamAdapter?
    public var apiKey: String
    public var enabled: Bool
    public var automaticCooldownDisabled: Bool
    public var supportsVision: Bool

    public init(
        label: String? = nil,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURL: String,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        apiKey: String,
        enabled: Bool = true,
        automaticCooldownDisabled: Bool = false,
        supportsVision: Bool = false
    ) {
        self.label = label
        self.providerPreset = providerPreset
        self.baseURL = baseURL
        self.baseURLMode = baseURLMode
        self.upstreamAdapter = upstreamAdapter
        self.apiKey = apiKey
        self.enabled = enabled
        self.automaticCooldownDisabled = automaticCooldownDisabled
        self.supportsVision = supportsVision
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case providerPreset
        case providerPresetSnake = "provider_preset"
        case baseURL
        case baseUrl
        case baseURLMode
        case baseURLModeSnake = "base_url_mode"
        case upstreamBaseURLModeSnake = "upstream_base_url_mode"
        case upstreamAdapter
        case upstreamAdapterSnake = "upstream_adapter"
        case apiKey
        case enabled
        case automaticCooldownDisabled
        case automaticCooldownDisabledSnake = "automatic_cooldown_disabled"
        case supportsVision
        case supportsVisionSnake = "supports_vision"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decodeIfPresent(String.self, forKey: .label),
            providerPreset: try container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPreset)
                ?? container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPresetSnake)
                ?? .genericOpenAICompatible,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? container.decode(String.self, forKey: .baseUrl),
            baseURLMode: try container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .baseURLMode)
                ?? container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .baseURLModeSnake)
                ?? container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .upstreamBaseURLModeSnake),
            upstreamAdapter: try container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapter)
                ?? container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapterSnake),
            apiKey: try container.decode(String.self, forKey: .apiKey),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            automaticCooldownDisabled: try container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabled)
                ?? container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabledSnake)
                ?? false,
            supportsVision: try container.decodeIfPresent(Bool.self, forKey: .supportsVision)
                ?? container.decodeIfPresent(Bool.self, forKey: .supportsVisionSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.label, forKey: .label)
        try container.encode(self.providerPreset, forKey: .providerPreset)
        try container.encode(self.baseURL, forKey: .baseURL)
        try container.encodeIfPresent(self.baseURLMode, forKey: .baseURLMode)
        try container.encodeIfPresent(self.upstreamAdapter, forKey: .upstreamAdapter)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.automaticCooldownDisabled, forKey: .automaticCooldownDisabled)
        try container.encode(self.supportsVision, forKey: .supportsVision)
    }
}

public struct UpdateManualAPIKeyAccountRequest: Codable, Sendable, Equatable {
    public var label: String?
    public var providerPreset: OpenAICompatibleProviderPreset
    public var baseURL: String
    public var baseURLMode: ManualAPIKeyBaseURLMode?
    public var upstreamAdapter: ManualAPIKeyUpstreamAdapter?
    public var apiKey: String
    public var enabled: Bool
    public var automaticCooldownDisabled: Bool
    public var supportsVision: Bool

    public init(
        label: String? = nil,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURL: String,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        apiKey: String,
        enabled: Bool = true,
        automaticCooldownDisabled: Bool = false,
        supportsVision: Bool = false
    ) {
        self.label = label
        self.providerPreset = providerPreset
        self.baseURL = baseURL
        self.baseURLMode = baseURLMode
        self.upstreamAdapter = upstreamAdapter
        self.apiKey = apiKey
        self.enabled = enabled
        self.automaticCooldownDisabled = automaticCooldownDisabled
        self.supportsVision = supportsVision
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case providerPreset
        case providerPresetSnake = "provider_preset"
        case baseURL
        case baseUrl
        case baseURLMode
        case baseURLModeSnake = "base_url_mode"
        case upstreamBaseURLModeSnake = "upstream_base_url_mode"
        case upstreamAdapter
        case upstreamAdapterSnake = "upstream_adapter"
        case apiKey
        case enabled
        case automaticCooldownDisabled
        case automaticCooldownDisabledSnake = "automatic_cooldown_disabled"
        case supportsVision
        case supportsVisionSnake = "supports_vision"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decodeIfPresent(String.self, forKey: .label),
            providerPreset: try container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPreset)
                ?? container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPresetSnake)
                ?? .genericOpenAICompatible,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? container.decode(String.self, forKey: .baseUrl),
            baseURLMode: try container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .baseURLMode)
                ?? container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .baseURLModeSnake)
                ?? container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .upstreamBaseURLModeSnake),
            upstreamAdapter: try container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapter)
                ?? container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapterSnake),
            apiKey: try container.decode(String.self, forKey: .apiKey),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            automaticCooldownDisabled: try container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabled)
                ?? container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabledSnake)
                ?? false,
            supportsVision: try container.decodeIfPresent(Bool.self, forKey: .supportsVision)
                ?? container.decodeIfPresent(Bool.self, forKey: .supportsVisionSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.label, forKey: .label)
        try container.encode(self.providerPreset, forKey: .providerPreset)
        try container.encode(self.baseURL, forKey: .baseURL)
        try container.encodeIfPresent(self.baseURLMode, forKey: .baseURLMode)
        try container.encodeIfPresent(self.upstreamAdapter, forKey: .upstreamAdapter)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.automaticCooldownDisabled, forKey: .automaticCooldownDisabled)
        try container.encode(self.supportsVision, forKey: .supportsVision)
    }
}

public struct ManualAPIKeyAccountDetails: Codable, Sendable, Equatable {
    public var label: String
    public var providerPreset: OpenAICompatibleProviderPreset
    public var baseURL: String
    public var baseURLMode: ManualAPIKeyBaseURLMode?
    public var upstreamAdapter: ManualAPIKeyUpstreamAdapter?
    public var apiKey: String
    public var enabled: Bool
    public var automaticCooldownDisabled: Bool
    public var supportsVision: Bool

    public init(
        label: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURL: String,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        apiKey: String,
        enabled: Bool,
        automaticCooldownDisabled: Bool = false,
        supportsVision: Bool = false
    ) {
        self.label = label
        self.providerPreset = providerPreset
        self.baseURL = baseURL
        self.baseURLMode = baseURLMode
        self.upstreamAdapter = upstreamAdapter
        self.apiKey = apiKey
        self.enabled = enabled
        self.automaticCooldownDisabled = automaticCooldownDisabled
        self.supportsVision = supportsVision
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case providerPreset
        case providerPresetSnake = "provider_preset"
        case baseURL
        case baseUrl
        case baseURLMode
        case baseURLModeSnake = "base_url_mode"
        case upstreamBaseURLModeSnake = "upstream_base_url_mode"
        case upstreamAdapter
        case upstreamAdapterSnake = "upstream_adapter"
        case apiKey
        case enabled
        case automaticCooldownDisabled
        case automaticCooldownDisabledSnake = "automatic_cooldown_disabled"
        case supportsVision
        case supportsVisionSnake = "supports_vision"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            providerPreset: try container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPreset)
                ?? container.decodeIfPresent(OpenAICompatibleProviderPreset.self, forKey: .providerPresetSnake)
                ?? .genericOpenAICompatible,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? container.decode(String.self, forKey: .baseUrl),
            baseURLMode: try container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .baseURLMode)
                ?? container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .baseURLModeSnake)
                ?? container.decodeIfPresent(ManualAPIKeyBaseURLMode.self, forKey: .upstreamBaseURLModeSnake),
            upstreamAdapter: try container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapter)
                ?? container.decodeIfPresent(ManualAPIKeyUpstreamAdapter.self, forKey: .upstreamAdapterSnake),
            apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey) ?? "",
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            automaticCooldownDisabled: try container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabled)
                ?? container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabledSnake)
                ?? false,
            supportsVision: try container.decodeIfPresent(Bool.self, forKey: .supportsVision)
                ?? container.decodeIfPresent(Bool.self, forKey: .supportsVisionSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.providerPreset, forKey: .providerPreset)
        try container.encode(self.baseURL, forKey: .baseURL)
        try container.encodeIfPresent(self.baseURLMode, forKey: .baseURLMode)
        try container.encodeIfPresent(self.upstreamAdapter, forKey: .upstreamAdapter)
        try container.encode(self.apiKey, forKey: .apiKey)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.automaticCooldownDisabled, forKey: .automaticCooldownDisabled)
        try container.encode(self.supportsVision, forKey: .supportsVision)
    }
}

public struct UpdateAccountCooldownPolicyRequest: Codable, Sendable, Equatable {
    public var automaticCooldownDisabled: Bool

    public init(automaticCooldownDisabled: Bool) {
        self.automaticCooldownDisabled = automaticCooldownDisabled
    }

    private enum CodingKeys: String, CodingKey {
        case automaticCooldownDisabled
        case automaticCooldownDisabledSnake = "automatic_cooldown_disabled"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            automaticCooldownDisabled: try container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabled)
                ?? container.decodeIfPresent(Bool.self, forKey: .automaticCooldownDisabledSnake)
                ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.automaticCooldownDisabled, forKey: .automaticCooldownDisabled)
    }
}

public struct UpdateAccountLabelRequest: Codable, Sendable, Equatable {
    public var label: String

    public init(label: String) {
        self.label = label
    }
}

public struct UpdateAccountManagedProxyNodeRequest: Codable, Sendable, Equatable {
    public var managedProxyNodeName: String?

    public init(managedProxyNodeName: String?) {
        self.managedProxyNodeName = AccountSummary.normalizedManagedProxyNodeName(managedProxyNodeName)
    }

    private enum CodingKeys: String, CodingKey {
        case managedProxyNodeName
        case managedProxyNodeNameSnake = "managed_proxy_node_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            managedProxyNodeName: try container.decodeIfPresent(String.self, forKey: .managedProxyNodeName)
                ?? container.decodeIfPresent(String.self, forKey: .managedProxyNodeNameSnake)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.managedProxyNodeName, forKey: .managedProxyNodeName)
    }
}

public struct ClearAccountManagedProxyNodesResult: Codable, Sendable, Equatable {
    public var clearedCount: Int

    public init(clearedCount: Int) {
        self.clearedCount = max(0, clearedCount)
    }

    private enum CodingKeys: String, CodingKey {
        case clearedCount
        case clearedCountSnake = "cleared_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clearedCount: try container.decodeIfPresent(Int.self, forKey: .clearedCount)
                ?? container.decodeIfPresent(Int.self, forKey: .clearedCountSnake)
                ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.clearedCount, forKey: .clearedCount)
    }
}

public struct UpdateAccountModelRoutingRequest: Codable, Sendable, Equatable {
    public var defaultTargetModel: String?
    public var mappings: [AccountModelMapping]

    public init(
        defaultTargetModel: String? = nil,
        mappings: [AccountModelMapping] = []
    ) {
        let normalized = AccountModelRoutingConfig(
            defaultTargetModel: defaultTargetModel,
            mappings: mappings
        ).normalizedOrNil
        self.defaultTargetModel = normalized?.defaultTargetModel
        self.mappings = normalized?.mappings ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case defaultTargetModel
        case defaultTargetModelSnake = "default_target_model"
        case mappings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultTargetModel: try container.decodeIfPresent(String.self, forKey: .defaultTargetModel)
                ?? container.decodeIfPresent(String.self, forKey: .defaultTargetModelSnake),
            mappings: try container.decodeIfPresent([AccountModelMapping].self, forKey: .mappings) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.defaultTargetModel, forKey: .defaultTargetModel)
        try container.encode(self.mappings, forKey: .mappings)
    }

    public var modelRouting: AccountModelRoutingConfig? {
        AccountModelRoutingConfig(
            defaultTargetModel: self.defaultTargetModel,
            mappings: self.mappings
        ).normalizedOrNil
    }
}

public struct UpdateAccountReasoningEffortRequest: Codable, Sendable, Equatable {
    public var low: String
    public var medium: String
    public var high: String
    public var xhigh: String

    public init(
        low: String = "low",
        medium: String = "medium",
        high: String = "high",
        xhigh: String = "xhigh"
    ) {
        let normalized = AccountReasoningEffortConfig(
            low: low,
            medium: medium,
            high: high,
            xhigh: xhigh
        )
        self.low = normalized.low
        self.medium = normalized.medium
        self.high = normalized.high
        self.xhigh = normalized.xhigh
    }

    private enum CodingKeys: String, CodingKey {
        case low
        case medium
        case high
        case xhigh
        case extraHigh
        case extraHighSnake = "extra_high"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            low: try container.decodeIfPresent(String.self, forKey: .low) ?? "low",
            medium: try container.decodeIfPresent(String.self, forKey: .medium) ?? "medium",
            high: try container.decodeIfPresent(String.self, forKey: .high) ?? "high",
            xhigh: try container.decodeIfPresent(String.self, forKey: .xhigh)
                ?? container.decodeIfPresent(String.self, forKey: .extraHigh)
                ?? container.decodeIfPresent(String.self, forKey: .extraHighSnake)
                ?? "xhigh"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.low, forKey: .low)
        try container.encode(self.medium, forKey: .medium)
        try container.encode(self.high, forKey: .high)
        try container.encode(self.xhigh, forKey: .xhigh)
    }

    public var reasoningEffort: AccountReasoningEffortConfig {
        AccountReasoningEffortConfig(
            low: self.low,
            medium: self.medium,
            high: self.high,
            xhigh: self.xhigh
        )
    }
}

public struct UpdateAccountEnabledRequest: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct UpdateAccountOrderRequest: Codable, Sendable, Equatable {
    public var orderedAccountIDs: [String]

    public init(orderedAccountIDs: [String]) {
        self.orderedAccountIDs = orderedAccountIDs
    }

    private enum CodingKeys: String, CodingKey {
        case orderedAccountIDs
        case orderedAccountIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            orderedAccountIDs: try container.decodeIfPresent([String].self, forKey: .orderedAccountIDs)
                ?? container.decode([String].self, forKey: .orderedAccountIds)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.orderedAccountIDs, forKey: .orderedAccountIDs)
    }
}

public struct DeleteAccountResult: Codable, Sendable, Equatable {
    public var id: String
    public var accountKey: String
    public var label: String

    public init(id: String, accountKey: String, label: String) {
        self.id = id
        self.accountKey = accountKey
        self.label = label
    }
}

public struct BatchDeleteAccountsRequest: Codable, Sendable, Equatable {
    public var accountIDs: [String]

    public init(accountIDs: [String] = []) {
        self.accountIDs = accountIDs
    }

    private enum CodingKeys: String, CodingKey {
        case accountIDs
        case accountIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accountIDs: try container.decodeIfPresent([String].self, forKey: .accountIDs)
                ?? container.decodeIfPresent([String].self, forKey: .accountIds)
                ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.accountIDs, forKey: .accountIDs)
    }
}

public struct BatchDeleteAccountFailure: Codable, Sendable, Equatable {
    public var id: String
    public var error: String

    public init(id: String, error: String) {
        self.id = id
        self.error = error
    }
}

public struct BatchDeleteAccountsResult: Codable, Sendable, Equatable {
    public var deleted: [DeleteAccountResult]
    public var failures: [BatchDeleteAccountFailure]

    public init(deleted: [DeleteAccountResult] = [], failures: [BatchDeleteAccountFailure] = []) {
        self.deleted = deleted
        self.failures = failures
    }
}

public struct ImportAccountFailure: Codable, Sendable, Equatable {
    public var source: String
    public var error: String

    public init(source: String, error: String) {
        self.source = source
        self.error = error
    }
}

public struct ImportAccountsResult: Codable, Sendable, Equatable {
    public var totalCount: Int
    public var importedCount: Int
    public var updatedCount: Int
    public var failures: [ImportAccountFailure]

    public init(totalCount: Int, importedCount: Int, updatedCount: Int, failures: [ImportAccountFailure]) {
        self.totalCount = totalCount
        self.importedCount = importedCount
        self.updatedCount = updatedCount
        self.failures = failures
    }
}

public struct SettingsEnvelope: Codable, Sendable, Equatable {
    public var config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }
}

public struct RemoteDeployStatus: Codable, Sendable, Equatable {
    public var hostID: String
    public var installed: Bool
    public var serviceInstalled: Bool
    public var running: Bool
    public var enabled: Bool
    public var architecture: String
    public var baseURL: String
    public var apiKey: String?
    public var lastError: String?
    public var logs: String?

    public init(
        hostID: String,
        installed: Bool,
        serviceInstalled: Bool,
        running: Bool,
        enabled: Bool,
        architecture: String,
        baseURL: String,
        apiKey: String?,
        lastError: String?,
        logs: String? = nil
    ) {
        self.hostID = hostID
        self.installed = installed
        self.serviceInstalled = serviceInstalled
        self.running = running
        self.enabled = enabled
        self.architecture = architecture
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.lastError = lastError
        self.logs = logs
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case hostId
        case installed
        case serviceInstalled
        case running
        case enabled
        case architecture
        case baseURL
        case baseUrl
        case apiKey
        case lastError
        case logs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostID: try container.decodeIfPresent(String.self, forKey: .hostID)
                ?? container.decode(String.self, forKey: .hostId),
            installed: try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false,
            serviceInstalled: try container.decodeIfPresent(Bool.self, forKey: .serviceInstalled) ?? false,
            running: try container.decodeIfPresent(Bool.self, forKey: .running) ?? false,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture) ?? "",
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL)
                ?? container.decode(String.self, forKey: .baseUrl),
            apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            logs: try container.decodeIfPresent(String.self, forKey: .logs)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.hostID, forKey: .hostID)
        try container.encode(self.installed, forKey: .installed)
        try container.encode(self.serviceInstalled, forKey: .serviceInstalled)
        try container.encode(self.running, forKey: .running)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.architecture, forKey: .architecture)
        try container.encode(self.baseURL, forKey: .baseURL)
        try container.encodeIfPresent(self.apiKey, forKey: .apiKey)
        try container.encodeIfPresent(self.lastError, forKey: .lastError)
        try container.encodeIfPresent(self.logs, forKey: .logs)
    }
}

public struct RemoteConnectionCheck: Codable, Sendable, Equatable {
    public var hostID: String
    public var architecture: String
    public var remoteUser: String
    public var remoteDirectoryWritable: Bool
    public var systemctlAvailable: Bool
    public var sudoAvailable: Bool
    public var localArtifactAvailable: Bool

    public init(
        hostID: String,
        architecture: String,
        remoteUser: String,
        remoteDirectoryWritable: Bool,
        systemctlAvailable: Bool,
        sudoAvailable: Bool,
        localArtifactAvailable: Bool
    ) {
        self.hostID = hostID
        self.architecture = architecture
        self.remoteUser = remoteUser
        self.remoteDirectoryWritable = remoteDirectoryWritable
        self.systemctlAvailable = systemctlAvailable
        self.sudoAvailable = sudoAvailable
        self.localArtifactAvailable = localArtifactAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case hostId
        case architecture
        case remoteUser
        case remoteDirectoryWritable
        case systemctlAvailable
        case sudoAvailable
        case localArtifactAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostID: try container.decodeIfPresent(String.self, forKey: .hostID)
                ?? container.decode(String.self, forKey: .hostId),
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture) ?? "unknown",
            remoteUser: try container.decodeIfPresent(String.self, forKey: .remoteUser) ?? "",
            remoteDirectoryWritable: try container.decodeIfPresent(Bool.self, forKey: .remoteDirectoryWritable) ?? false,
            systemctlAvailable: try container.decodeIfPresent(Bool.self, forKey: .systemctlAvailable) ?? false,
            sudoAvailable: try container.decodeIfPresent(Bool.self, forKey: .sudoAvailable) ?? false,
            localArtifactAvailable: try container.decodeIfPresent(Bool.self, forKey: .localArtifactAvailable) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.hostID, forKey: .hostID)
        try container.encode(self.architecture, forKey: .architecture)
        try container.encode(self.remoteUser, forKey: .remoteUser)
        try container.encode(self.remoteDirectoryWritable, forKey: .remoteDirectoryWritable)
        try container.encode(self.systemctlAvailable, forKey: .systemctlAvailable)
        try container.encode(self.sudoAvailable, forKey: .sudoAvailable)
        try container.encode(self.localArtifactAvailable, forKey: .localArtifactAvailable)
    }
}

public struct UpstreamUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var totalTokens: Int64
    public var cacheHitTokens: Int64?

    public init(
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        cacheHitTokens: Int64? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheHitTokens = cacheHitTokens
    }
}

public struct ProxyRequestTrace: Sendable {
    public enum FailureCategory: String, Sendable {
        case none
        case auth
        case rateLimit
        case quota
        case upstream
        case invalidRequest
        case cancelled
    }

    public var endpoint: String
    public var upstreamURL: String?
    public var timestamp: Int64
    public var apiKeyValue: String
    public var apiKeyHash: String
    public var accountKey: String
    public var accountLabel: String
    public var clientSource: RequestLogClientSource
    public var model: String
    public var actualModel: String?
    public var reasoningEffort: String?
    public var success: Bool
    public var latencyMS: Int64
    public var usage: UpstreamUsage
    public var failureCategory: FailureCategory
    public var lastError: String?

    public init(
        endpoint: String,
        upstreamURL: String? = nil,
        apiKeyHash: String,
        accountKey: String,
        accountLabel: String,
        clientSource: RequestLogClientSource = .other,
        model: String,
        actualModel: String? = nil,
        reasoningEffort: String? = nil,
        success: Bool,
        latencyMS: Int64,
        usage: UpstreamUsage = .init(),
        failureCategory: FailureCategory = .none,
        lastError: String? = nil,
        timestamp: Int64 = Helpers.now(),
        apiKeyValue: String = ""
    ) {
        self.endpoint = endpoint
        self.upstreamURL = upstreamURL
        self.timestamp = timestamp
        self.apiKeyValue = apiKeyValue
        self.apiKeyHash = apiKeyHash
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.clientSource = clientSource
        self.model = model
        self.actualModel = actualModel
        self.reasoningEffort = reasoningEffort
        self.success = success
        self.latencyMS = latencyMS
        self.usage = usage
        self.failureCategory = failureCategory
        self.lastError = lastError
    }
}

public struct ExtractedAuth: Sendable, Equatable {
    public var providerFamily: AccountProviderFamily
    public var authMode: AccountAuthMode
    public var providerPreset: OpenAICompatibleProviderPreset
    public var baseURLMode: ManualAPIKeyBaseURLMode?
    public var upstreamAdapter: ManualAPIKeyUpstreamAdapter?
    public var principalID: String
    public var accountID: String
    public var accessToken: String
    public var upstreamBaseURL: String?
    public var refreshToken: String?
    public var idToken: String?
    public var email: String?
    public var planType: String?

    public init(
        providerFamily: AccountProviderFamily? = nil,
        authMode: AccountAuthMode = .chatGPT,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        principalID: String,
        accountID: String,
        accessToken: String,
        upstreamBaseURL: String? = nil,
        refreshToken: String?,
        idToken: String?,
        email: String?,
        planType: String?
    ) {
        self.providerFamily = providerFamily ?? authMode.providerFamily
        self.authMode = authMode
        self.providerPreset = providerPreset
        self.baseURLMode = baseURLMode
        self.upstreamAdapter = upstreamAdapter
        self.principalID = principalID
        self.accountID = accountID
        self.accessToken = accessToken
        self.upstreamBaseURL = upstreamBaseURL
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.email = email
        self.planType = planType
    }
}

public enum AccountAuthMode: String, Codable, Sendable, Equatable, CaseIterable {
    case chatGPT = "openai_chatgpt_oauth"
    case openAIAPIKey = "openai_api_key"
    case anthropicAPIKey = "anthropic_api_key"
    case anthropicSubscriptionOAuth = "anthropic_subscription_oauth"
    case geminiOAuth = "gemini_api_oauth"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "chatgpt", "openai_chatgpt_oauth":
            self = .chatGPT
        case "openai_api_key":
            self = .openAIAPIKey
        case "anthropic_api_key":
            self = .anthropicAPIKey
        case "anthropic_subscription_oauth":
            self = .anthropicSubscriptionOAuth
        case "gemini_api_oauth":
            self = .geminiOAuth
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported account auth mode: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "chatgpt", "openai_chatgpt_oauth":
            self = .chatGPT
        case "openai_api_key":
            self = .openAIAPIKey
        case "anthropic_api_key":
            self = .anthropicAPIKey
        case "anthropic_subscription_oauth":
            self = .anthropicSubscriptionOAuth
        case "gemini_api_oauth":
            self = .geminiOAuth
        default:
            return nil
        }
    }

    public var providerFamily: AccountProviderFamily {
        switch self {
        case .chatGPT, .openAIAPIKey:
            return .openAI
        case .anthropicAPIKey, .anthropicSubscriptionOAuth:
            return .anthropic
        case .geminiOAuth:
            return .gemini
        }
    }

    public var isManualAPIKey: Bool {
        switch self {
        case .openAIAPIKey, .anthropicAPIKey:
            return true
        case .chatGPT, .anthropicSubscriptionOAuth, .geminiOAuth:
            return false
        }
    }

    public var primaryPinnedProxyTestDataSource: ProxyDataSource {
        switch self.providerFamily {
        case .openAI:
            return .openAI
        case .anthropic:
            return .anthropic
        case .gemini:
            return .gemini
        }
    }

    public var fallbackPinnedProxyTestCompatibleDataSources: [ProxyDataSource] {
        switch self {
        case .anthropicSubscriptionOAuth:
            return [.openAI]
        case .chatGPT, .openAIAPIKey, .anthropicAPIKey, .geminiOAuth:
            return []
        }
    }

    public var pinnedProxyTestCompatibleDataSources: [ProxyDataSource] {
        [self.primaryPinnedProxyTestDataSource] + self.fallbackPinnedProxyTestCompatibleDataSources
    }

    public func supportsPinnedProxyTest(dataSource: ProxyDataSource) -> Bool {
        if dataSource.isWildcard {
            return true
        }
        return self.pinnedProxyTestCompatibleDataSources.contains(dataSource)
    }
}

public enum OpenAICompatibleProviderPreset: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case genericOpenAICompatible = "generic_openai_compatible"
    case aliyunQwenCodingPlan = "aliyun_qwen_coding_plan"
    case anthropicAPICompatible = "anthropic_api_compatible"
    case googleGeminiCompatible = "google_gemini_compatible"

    private static let legacyDeepSeekOfficialAPIRawValue = "deepseek_official_api"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == Self.legacyDeepSeekOfficialAPIRawValue {
            self = .genericOpenAICompatible
            return
        }
        if let preset = Self(rawValue: raw) {
            self = preset
            return
        }
        self = .genericOpenAICompatible
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public var defaultBaseURL: String {
        switch self {
        case .genericOpenAICompatible:
            return OpenAICompatibleUpstream.defaultBaseURL
        case .aliyunQwenCodingPlan:
            return "https://coding.dashscope.aliyuncs.com"
        case .anthropicAPICompatible:
            return AnthropicAPIKeyUpstream.defaultBaseURL
        case .googleGeminiCompatible:
            return OpenAICompatibleUpstream.defaultGeminiBaseURL
        }
    }

    public var defaultValidationModelCandidates: [String] {
        switch self {
        case .genericOpenAICompatible:
            return []
        case .aliyunQwenCodingPlan:
            return [
                "qwen3-coder-plus",
                "qwen3-coder-next",
                "qwen3-max-2026-01-23",
                "qwen3.6-plus",
                "qwen3.5-plus",
            ]
        case .anthropicAPICompatible:
            return []
        case .googleGeminiCompatible:
            return [
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite",
                "gemini-2.5-pro",
            ]
        }
    }

    public func resolvedUpstreamModel(for requestedModel: String) -> String {
        switch self {
        case .genericOpenAICompatible:
            return requestedModel
        case .aliyunQwenCodingPlan:
            let lower = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.contains("max") {
                return "qwen3-max-2026-01-23"
            }
            if lower.contains("mini") {
                return "qwen3-coder-next"
            }
            return "qwen3-coder-plus"
        case .anthropicAPICompatible:
            return requestedModel
        case .googleGeminiCompatible:
            let lower = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.contains("max") || lower.contains("pro") {
                return "gemini-2.5-pro"
            }
            if lower.contains("mini") || lower.contains("lite") {
                return "gemini-2.5-flash-lite"
            }
            return "gemini-2.5-flash"
        }
    }

    public var providerUserAgent: String {
        switch self {
        case .genericOpenAICompatible:
            return RuntimeInfo.daemonServerToken
        case .aliyunQwenCodingPlan:
            return "OpenClaw/1.0 CodexProxyCompatibility"
        case .anthropicAPICompatible, .googleGeminiCompatible:
            return RuntimeInfo.daemonServerToken
        }
    }

    public var manualAuthMode: AccountAuthMode {
        switch self {
        case .anthropicAPICompatible:
            return .anthropicAPIKey
        case .genericOpenAICompatible, .aliyunQwenCodingPlan, .googleGeminiCompatible:
            return .openAIAPIKey
        }
    }

    public var usesOpenAIChatCompletionsAPI: Bool {
        switch self {
        case .aliyunQwenCodingPlan, .googleGeminiCompatible:
            return true
        case .genericOpenAICompatible, .anthropicAPICompatible:
            return false
        }
    }
}

public struct AccountRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var principalID: String
    public var email: String?
    public var accountID: String
    public var planType: String?
    public var providerFamily: AccountProviderFamily
    public var authMode: AccountAuthMode
    public var providerPreset: OpenAICompatibleProviderPreset
    public var upstreamBaseURL: String?
    public var managedProxyNodeName: String?
    public var modelRouting: AccountModelRoutingConfig?
    public var reasoningEffort: AccountReasoningEffortConfig
    public var supportsVision: Bool
    public var authJSON: String
    public var addedAt: Int64
    public var updatedAt: Int64
    public var enabled: Bool
    public var selectionOrder: Int64
    public var consecutiveFailureCount: Int64
    public var cooldownUntil: Int64?
    public var automaticCooldownDisabled: Bool
    public var usage: UsageSnapshot?
    public var usageWindowsVisible: Bool
    public var usageError: String?
    public var authRefreshBlocked: Bool
    public var authRefreshError: String?

    public init(
        id: String = UUID().uuidString,
        label: String,
        principalID: String,
        email: String?,
        accountID: String,
        planType: String?,
        providerFamily: AccountProviderFamily? = nil,
        authMode: AccountAuthMode = .chatGPT,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        upstreamBaseURL: String? = nil,
        managedProxyNodeName: String? = nil,
        modelRouting: AccountModelRoutingConfig? = nil,
        reasoningEffort: AccountReasoningEffortConfig = .defaultConfig,
        supportsVision: Bool = true,
        authJSON: String,
        addedAt: Int64 = Int64(Date().timeIntervalSince1970),
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970),
        enabled: Bool = true,
        selectionOrder: Int64 = 0,
        consecutiveFailureCount: Int64 = 0,
        cooldownUntil: Int64? = nil,
        automaticCooldownDisabled: Bool = false,
        usage: UsageSnapshot? = nil,
        usageWindowsVisible: Bool = true,
        usageError: String? = nil,
        authRefreshBlocked: Bool = false,
        authRefreshError: String? = nil
    ) {
        self.id = id
        self.label = label
        self.principalID = principalID
        self.email = email
        self.accountID = accountID
        self.planType = planType
        self.providerFamily = providerFamily ?? authMode.providerFamily
        self.authMode = authMode
        self.providerPreset = providerPreset
        self.upstreamBaseURL = upstreamBaseURL
        self.managedProxyNodeName = AccountSummary.normalizedManagedProxyNodeName(managedProxyNodeName)
        self.modelRouting = AccountSummary.normalizedModelRouting(modelRouting)
        self.reasoningEffort = reasoningEffort
        self.supportsVision = supportsVision
        self.authJSON = authJSON
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.selectionOrder = selectionOrder
        self.consecutiveFailureCount = consecutiveFailureCount
        self.cooldownUntil = cooldownUntil
        self.automaticCooldownDisabled = automaticCooldownDisabled
        self.usage = usage
        self.usageWindowsVisible = usageWindowsVisible
        self.usageError = usageError
        self.authRefreshBlocked = authRefreshBlocked
        self.authRefreshError = authRefreshError
    }

    public var accountKey: String {
        "\(self.principalID)|\(self.accountID)"
    }

    public var effectivePlanType: String? {
        resolvedAccountPlanType(self.usage?.planType, fallback: self.planType)
    }

    public func isCoolingDown(now: Int64 = Helpers.now()) -> Bool {
        guard self.automaticCooldownDisabled == false else { return false }
        guard let cooldownUntil else { return false }
        return cooldownUntil > now
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

func resolvedAccountPlanType(_ preferred: String?, fallback: String?) -> String? {
    for candidate in [preferred, fallback] {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return nil
}
