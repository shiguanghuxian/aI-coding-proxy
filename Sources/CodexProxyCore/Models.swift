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
        anthropicModelMappings: [AnthropicModelMapping] = []
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
            anthropicModelMappings: try container.decodeIfPresent([AnthropicModelMapping].self, forKey: .anthropicModelMappings) ?? []
        )
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
            )
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
    public var upstreamBaseURL: String?
    public var managedProxyNodeName: String?
    public var modelRouting: AccountModelRoutingConfig?
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
        upstreamBaseURL: String? = nil,
        managedProxyNodeName: String? = nil,
        modelRouting: AccountModelRoutingConfig? = nil,
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
        self.upstreamBaseURL = upstreamBaseURL
        self.managedProxyNodeName = Self.normalizedManagedProxyNodeName(managedProxyNodeName)
        self.modelRouting = Self.normalizedModelRouting(modelRouting)
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
        case upstreamBaseURL
        case upstreamBaseUrl
        case managedProxyNodeName
        case managedProxyNodeNameSnake = "managed_proxy_node_name"
        case modelRouting
        case modelRoutingSnake = "model_routing"
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
            upstreamBaseURL: try container.decodeIfPresent(String.self, forKey: .upstreamBaseURL)
                ?? container.decodeIfPresent(String.self, forKey: .upstreamBaseUrl),
            managedProxyNodeName: try container.decodeIfPresent(String.self, forKey: .managedProxyNodeName)
                ?? container.decodeIfPresent(String.self, forKey: .managedProxyNodeNameSnake),
            modelRouting: try container.decodeIfPresent(AccountModelRoutingConfig.self, forKey: .modelRouting)
                ?? container.decodeIfPresent(AccountModelRoutingConfig.self, forKey: .modelRoutingSnake),
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
        try container.encodeIfPresent(self.upstreamBaseURL, forKey: .upstreamBaseURL)
        try container.encodeIfPresent(self.managedProxyNodeName, forKey: .managedProxyNodeName)
        try container.encodeIfPresent(self.modelRouting, forKey: .modelRouting)
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
    public var anthropicMessages: ProxyTestModelGroup
    public var geminiGenerateContent: ProxyTestModelGroup

    public init(
        chatCompletions: ProxyTestModelGroup,
        responses: ProxyTestModelGroup,
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
        self.anthropicMessages = anthropicMessages
        self.geminiGenerateContent = geminiGenerateContent
    }

    private enum CodingKeys: String, CodingKey {
        case chatCompletions
        case responses
        case anthropicMessages
        case geminiGenerateContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            chatCompletions: try container.decode(ProxyTestModelGroup.self, forKey: .chatCompletions),
            responses: try container.decode(ProxyTestModelGroup.self, forKey: .responses),
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
        try container.encode(self.anthropicMessages, forKey: .anthropicMessages)
        try container.encode(self.geminiGenerateContent, forKey: .geminiGenerateContent)
    }

    private static let defaultGPTModels = ProxyTranscoder.supportedModels
    private static let defaultGPTModel = ProxyTranscoder.defaultModel
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

    public init(
        endpoint: AdminProxyTestEndpoint,
        model: String,
        payloadJSON: String,
        stream: Bool,
        selectedAccountKey: String? = nil,
        proxyAPIKey: String? = nil,
        anthropicVersion: String? = nil,
        anthropicBeta: String? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.payloadJSON = payloadJSON
        self.stream = stream
        self.selectedAccountKey = selectedAccountKey
        self.proxyAPIKey = proxyAPIKey
        self.anthropicVersion = anthropicVersion
        self.anthropicBeta = anthropicBeta
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
                ?? container.decodeIfPresent(String.self, forKey: .anthropicBetaSnake)
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

        public init(
            bucketStart: Int64,
            windowSeconds: Int64,
            requestCount: Int64 = 0,
            inputTokens: Int64 = 0,
            outputTokens: Int64 = 0
        ) {
            self.bucketStart = bucketStart
            self.windowSeconds = windowSeconds
            self.requestCount = requestCount
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        private enum CodingKeys: String, CodingKey {
            case bucketStart
            case windowSeconds
            case requestCount
            case inputTokens
            case outputTokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                bucketStart: try container.decode(Int64.self, forKey: .bucketStart),
                windowSeconds: try container.decode(Int64.self, forKey: .windowSeconds),
                requestCount: try container.decodeIfPresent(Int64.self, forKey: .requestCount) ?? 0,
                inputTokens: try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0,
                outputTokens: try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.bucketStart, forKey: .bucketStart)
            try container.encode(self.windowSeconds, forKey: .windowSeconds)
            try container.encode(self.requestCount, forKey: .requestCount)
            try container.encode(self.inputTokens, forKey: .inputTokens)
            try container.encode(self.outputTokens, forKey: .outputTokens)
        }
    }

    public struct NaturalRangeTokenUsage: Codable, Sendable, Equatable {
        public var requestCount: Int64
        public var inputTokens: Int64
        public var outputTokens: Int64

        public init(requestCount: Int64 = 0, inputTokens: Int64 = 0, outputTokens: Int64 = 0) {
            self.requestCount = requestCount
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        private enum CodingKeys: String, CodingKey {
            case requestCount
            case inputTokens
            case outputTokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                requestCount: try container.decodeIfPresent(Int64.self, forKey: .requestCount) ?? 0,
                inputTokens: try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0,
                outputTokens: try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.requestCount, forKey: .requestCount)
            try container.encode(self.inputTokens, forKey: .inputTokens)
            try container.encode(self.outputTokens, forKey: .outputTokens)
        }
    }

    public struct NaturalTokenUsageSummary: Codable, Sendable, Equatable {
        public var today: NaturalRangeTokenUsage
        public var week: NaturalRangeTokenUsage
        public var month: NaturalRangeTokenUsage
        public var dailyTrend: [NaturalTimeBucketUsage]
        public var weeklyTrend: [NaturalTimeBucketUsage]

        public init(
            today: NaturalRangeTokenUsage = NaturalRangeTokenUsage(),
            week: NaturalRangeTokenUsage = NaturalRangeTokenUsage(),
            month: NaturalRangeTokenUsage = NaturalRangeTokenUsage(),
            dailyTrend: [NaturalTimeBucketUsage] = [],
            weeklyTrend: [NaturalTimeBucketUsage] = []
        ) {
            self.today = today
            self.week = week
            self.month = month
            self.dailyTrend = dailyTrend
            self.weeklyTrend = weeklyTrend
        }

        private enum CodingKeys: String, CodingKey {
            case today
            case week
            case month
            case dailyTrend
            case weeklyTrend
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
                weeklyTrend: try container.decodeIfPresent([NaturalTimeBucketUsage].self, forKey: .weeklyTrend) ?? []
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.today, forKey: .today)
            try container.encode(self.week, forKey: .week)
            try container.encode(self.month, forKey: .month)
            try container.encode(self.dailyTrend, forKey: .dailyTrend)
            try container.encode(self.weeklyTrend, forKey: .weeklyTrend)
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
        errorSummary: String?
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
            errorSummary: try container.decodeIfPresent(String.self, forKey: .errorSummary)
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
    public var automaticCooldownDisabled: Bool?

    public init(
        source: String,
        content: String,
        label: String? = nil,
        enabled: Bool? = nil,
        managedProxyNodeName: String? = nil,
        modelRouting: AccountModelRoutingConfig? = nil,
        automaticCooldownDisabled: Bool? = nil
    ) {
        self.source = source
        self.content = content
        self.label = label
        self.enabled = enabled
        self.managedProxyNodeName = AccountSummary.normalizedManagedProxyNodeName(managedProxyNodeName)
        self.modelRouting = AccountSummary.normalizedModelRouting(modelRouting)
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

    public init(
        label: String? = nil,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURL: String,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        apiKey: String,
        enabled: Bool = true,
        automaticCooldownDisabled: Bool = false
    ) {
        self.label = label
        self.providerPreset = providerPreset
        self.baseURL = baseURL
        self.baseURLMode = baseURLMode
        self.upstreamAdapter = upstreamAdapter
        self.apiKey = apiKey
        self.enabled = enabled
        self.automaticCooldownDisabled = automaticCooldownDisabled
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

    public init(
        label: String? = nil,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURL: String,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        apiKey: String,
        enabled: Bool = true,
        automaticCooldownDisabled: Bool = false
    ) {
        self.label = label
        self.providerPreset = providerPreset
        self.baseURL = baseURL
        self.baseURLMode = baseURLMode
        self.upstreamAdapter = upstreamAdapter
        self.apiKey = apiKey
        self.enabled = enabled
        self.automaticCooldownDisabled = automaticCooldownDisabled
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

    public init(
        label: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURL: String,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        apiKey: String,
        enabled: Bool,
        automaticCooldownDisabled: Bool = false
    ) {
        self.label = label
        self.providerPreset = providerPreset
        self.baseURL = baseURL
        self.baseURLMode = baseURLMode
        self.upstreamAdapter = upstreamAdapter
        self.apiKey = apiKey
        self.enabled = enabled
        self.automaticCooldownDisabled = automaticCooldownDisabled
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
