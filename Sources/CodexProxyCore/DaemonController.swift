import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

public struct ProxyHTTPResponse: Sendable {
    public enum Body: Sendable {
        case bytes(Data)
        case stream(AsyncThrowingStream<Data, Error>)
    }

    public var statusCode: Int
    public var headers: [String: String]
    public var body: Body

    public init(statusCode: Int, headers: [String: String], body: Body) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct GeminiUpstreamError: Error, LocalizedError, Sendable {
    public var httpStatus: Int
    public var statusText: String
    public var message: String
    public var reasonCode: String?
    public var responseBody: Data
    public var rawText: String

    public init(
        httpStatus: Int,
        statusText: String,
        message: String,
        reasonCode: String? = nil,
        responseBody: Data = Data(),
        rawText: String = ""
    ) {
        self.httpStatus = httpStatus
        self.statusText = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasonCode = reasonCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.responseBody = responseBody
        self.rawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var summary: String {
        var prefix = "Gemini upstream error \(self.httpStatus)"
        if self.statusText.isEmpty == false {
            prefix += " \(self.statusText)"
        }
        if let reasonCode = self.reasonCode, reasonCode.isEmpty == false {
            prefix += " [\(reasonCode)]"
        }
        let message = self.message.isEmpty ? "Request failed." : self.message
        return "\(prefix): \(message)"
    }

    public var errorDescription: String? {
        self.summary
    }

    public var responseData: Data {
        guard self.responseBody.isEmpty == false,
              (try? JSONSerialization.jsonObject(with: self.responseBody)) != nil
        else {
            let payload: [String: Any] = [
                "error": [
                    "code": self.httpStatus,
                    "message": self.message,
                    "status": self.statusText,
                ],
            ]
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                ?? Data("{\"error\":{\"code\":\(self.httpStatus),\"message\":\"\(self.message)\",\"status\":\"\(self.statusText)\"}}".utf8)
        }
        return self.responseBody
    }

    static func fromHTTPResponse(statusCode: Int, body: Data) -> GeminiUpstreamError {
        let rawText = String(decoding: body, as: UTF8.self)
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = self.fromGeminiEvent(object, fallbackStatusCode: statusCode)
        else {
            return GeminiUpstreamError(
                httpStatus: statusCode,
                statusText: self.defaultStatusText(for: statusCode),
                message: rawText.isEmpty ? "Gemini upstream request failed." : Helpers.truncate(rawText),
                responseBody: body,
                rawText: rawText
            )
        }
        return GeminiUpstreamError(
            httpStatus: error.httpStatus,
            statusText: error.statusText,
            message: error.message,
            reasonCode: error.reasonCode,
            responseBody: body,
            rawText: rawText.isEmpty ? error.summary : rawText
        )
    }

    static func fromGeminiEvent(
        _ object: [String: Any],
        fallbackStatusCode: Int = 500
    ) -> GeminiUpstreamError? {
        guard let error = object["error"] as? [String: Any] else {
            return nil
        }

        let bodyCode = self.intValue(error["code"])
        let httpStatus = fallbackStatusCode == 200 || fallbackStatusCode == 0
            ? (bodyCode ?? 500)
            : fallbackStatusCode
        let statusText = self.nonEmptyString(error["status"]) ?? self.defaultStatusText(for: httpStatus)
        let message = self.nonEmptyString(error["message"])
            ?? "Gemini upstream request failed."
        let reasonCode = ((error["details"] as? [Any]) ?? [])
            .compactMap { detail -> String? in
                guard let detail = detail as? [String: Any] else {
                    return nil
                }
                return self.nonEmptyString(detail["reason"])
            }
            .first
        let responseBody = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        let rawText = String(decoding: responseBody, as: UTF8.self)
        return GeminiUpstreamError(
            httpStatus: httpStatus,
            statusText: statusText,
            message: message,
            reasonCode: reasonCode,
            responseBody: responseBody,
            rawText: rawText
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let int64Value as Int64:
            return Int(int64Value)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func defaultStatusText(for statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return "INVALID_ARGUMENT"
        case 401:
            return "UNAUTHENTICATED"
        case 403:
            return "PERMISSION_DENIED"
        case 429:
            return "RESOURCE_EXHAUSTED"
        default:
            return "INTERNAL"
        }
    }
}

public actor RuntimeState {
    public var activeAccountKey: String?
    public var activeAccountID: String?
    public var activeAccountLabel: String?
    public var lastError: String?
    public var pendingOAuthLogin: PendingOAuthLogin?
    public var oauthCallbackListener: OAuthCallbackListener?

    public init() {}

    public func setActive(accountKey: String?, accountID: String?, label: String?) {
        self.activeAccountKey = accountKey
        self.activeAccountID = accountID
        self.activeAccountLabel = label
        self.lastError = nil
    }

    public func clearActiveIfMatches(accountKey: String) {
        guard self.activeAccountKey == accountKey else { return }
        self.activeAccountKey = nil
        self.activeAccountID = nil
        self.activeAccountLabel = nil
    }

    public func setActiveLabelIfMatches(accountKey: String, label: String?) {
        guard self.activeAccountKey == accountKey else { return }
        self.activeAccountLabel = label
    }

    public func setLastError(_ error: String?) {
        self.lastError = error
    }

    public func setPendingOAuthLogin(_ pending: PendingOAuthLogin?) {
        self.pendingOAuthLogin = pending
    }

    public func setOAuthCallbackListener(_ listener: OAuthCallbackListener?) {
        self.oauthCallbackListener = listener
    }

    public func clearOAuthSessionIfMatches(state: String) -> OAuthCallbackListener? {
        guard self.pendingOAuthLogin?.state == state else {
            return nil
        }
        self.pendingOAuthLogin = nil
        let listener = self.oauthCallbackListener
        self.oauthCallbackListener = nil
        return listener
    }

    public func takeOAuthCallbackListener() -> OAuthCallbackListener? {
        let listener = self.oauthCallbackListener
        self.oauthCallbackListener = nil
        return listener
    }
}

private actor AnthropicStreamKeepaliveState {
    private var lastEmissionMS: Int64
    private var finished: Bool

    init(lastEmissionMS: Int64 = Helpers.nowMilliseconds(), finished: Bool = false) {
        self.lastEmissionMS = lastEmissionMS
        self.finished = finished
    }

    func noteDownstreamActivity() {
        self.lastEmissionMS = Helpers.nowMilliseconds()
    }

    func finish() {
        self.finished = true
    }

    func shouldEmitPing(intervalMS: Int64) -> Bool {
        guard !self.finished else {
            return false
        }
        let now = Helpers.nowMilliseconds()
        guard now - self.lastEmissionMS >= intervalMS else {
            return false
        }
        self.lastEmissionMS = now
        return true
    }
}

private actor AccountModelDiscoveryCache {
    private struct Entry {
        var updatedAt: Int64
        var expiresAt: Int64
        var models: [String]
    }

    private var entries: [String: Entry] = [:]

    func models(
        for accountKey: String,
        updatedAt: Int64,
        now: Int64 = Helpers.now()
    ) -> [String]? {
        guard let entry = self.entries[accountKey] else {
            return nil
        }
        guard entry.updatedAt == updatedAt, entry.expiresAt > now else {
            self.entries.removeValue(forKey: accountKey)
            return nil
        }
        return entry.models
    }

    func store(
        _ models: [String],
        for accountKey: String,
        updatedAt: Int64,
        ttlSeconds: Int64,
        now: Int64 = Helpers.now()
    ) {
        self.entries[accountKey] = Entry(
            updatedAt: updatedAt,
            expiresAt: now + ttlSeconds,
            models: models
        )
    }
}

private struct ResponsesStreamTerminalState {
    var responseID: String?
    var createdAt: Int64?
    var sawCreated = false
    var sawCompleted = false
    var sawFailed = false
    var errorMessage: String?

    mutating func observe(sseChunk: String) {
        for event in ProxyTranscoder.decodeSSE(Data(sseChunk.utf8)) {
            self.observe(event: event)
        }
    }

    mutating func ensureSyntheticIdentity() -> (responseID: String, createdAt: Int64) {
        if self.responseID == nil {
            self.responseID = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        }
        if self.createdAt == nil {
            self.createdAt = Helpers.now()
        }
        return (self.responseID!, self.createdAt!)
    }

    mutating func observe(event: SSEEvent) {
        guard let json = ProxyTranscoder.jsonObject(from: event) else {
            return
        }
        let response = json["response"] as? [String: Any]
        if let id = Self.nonEmptyString(response?["id"]) {
            self.responseID = id
        }
        if let createdAt = Self.int64Value(response?["created_at"]) {
            self.createdAt = createdAt
        }

        switch ProxyTranscoder.responseEventType(from: json) {
        case "response.created":
            self.sawCreated = true
        case "response.completed":
            self.sawCompleted = true
        case "response.failed":
            self.sawFailed = true
            self.errorMessage = Self.errorMessage(from: json, response: response)
        default:
            break
        }
    }

    private static func errorMessage(from json: [String: Any], response: [String: Any]?) -> String? {
        if let error = response?["error"] as? [String: Any],
           let message = self.nonEmptyString(error["message"])
        {
            return message
        }
        if let error = json["error"] as? [String: Any],
           let message = self.nonEmptyString(error["message"])
        {
            return message
        }
        if let message = self.nonEmptyString(response?["message"]) {
            return message
        }
        return self.nonEmptyString(json["message"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let intValue as Int64:
            return intValue
        case let intValue as Int:
            return Int64(intValue)
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }
}

private struct GeminiStreamTerminalState {
    var sawFinishReason = false
    var sawError = false
    var errorMessage: String?
    var upstreamError: GeminiUpstreamError?

    mutating func observe(sseChunk: String) {
        for event in ProxyTranscoder.decodeSSE(Data(sseChunk.utf8)) {
            self.observe(event: event)
        }
    }

    private mutating func observe(event: SSEEvent) {
        guard let json = ProxyTranscoder.jsonObject(from: event) else {
            return
        }
        if let upstreamError = GeminiUpstreamError.fromGeminiEvent(json, fallbackStatusCode: 0) {
            self.sawError = true
            self.upstreamError = upstreamError
            self.errorMessage = upstreamError.summary
        }

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        if candidates.contains(where: {
            Self.nonEmptyString($0["finishReason"]) != nil
        }) {
            self.sawFinishReason = true
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AnthropicMessagesTerminalState {
    var sawMessageStop = false

    mutating func observe(sseChunk: String) {
        for event in ProxyTranscoder.decodeSSE(Data(sseChunk.utf8)) {
            self.observe(event: event)
        }
    }

    private mutating func observe(event: SSEEvent) {
        if event.event == "message_stop" {
            self.sawMessageStop = true
            return
        }
        guard let json = ProxyTranscoder.jsonObject(from: event) else {
            return
        }
        if (json["type"] as? String) == "message_stop" {
            self.sawMessageStop = true
        }
    }
}

private enum StreamEndReason: String, Sendable {
    case completed = "completed"
    case protocolFailed = "protocol_failed"
    case prematureEOF = "premature_eof"
    case scannerError = "scanner_error"
    case writerError = "writer_error"
    case clientCancelled = "client_cancelled"
}

private actor StreamTerminalTraceCoordinator {
    enum Outcome {
        case success
        case failure
        case cancelled
    }

    private var outcome: Outcome?

    func begin(_ outcome: Outcome) -> Bool {
        guard self.outcome == nil else {
            return false
        }
        self.outcome = outcome
        return true
    }
}

private actor ManagedProxyNodeCoordinator {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard self.isLocked else {
            self.isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func release() {
        guard self.waiters.isEmpty == false else {
            self.isLocked = false
            return
        }
        let continuation = self.waiters.removeFirst()
        continuation.resume()
    }
}

private func summarizedUpstreamError(_ rawText: String) -> String {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
        return "上游请求失败，但未返回错误详情。"
    }
    guard
        let data = trimmed.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return Helpers.truncate(trimmed)
    }

    if let error = object["error"] as? [String: Any],
       let message = error["message"] as? String,
       message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    {
        return Helpers.truncate(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let message = object["error"] as? String,
       message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    {
        return Helpers.truncate(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let message = object["message"] as? String,
       message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    {
        return Helpers.truncate(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return Helpers.truncate(trimmed)
}

private struct RecordedCandidateFailure: LocalizedError {
    var rawText: String
    var shouldContinue: Bool
    var response: ProxyHTTPResponse?

    var errorDescription: String? {
        summarizedUpstreamError(self.rawText)
    }
}

private enum OpenAIUpstreamAdapter: String, Sendable {
    case responses = "responses"
    case chatCompletions = "chat_completions"

    var diagnosticLabel: String { self.rawValue }
}

private struct OpenAIAdapterAttemptContext: Sendable {
    var fallbackReason: String?

    init(fallbackReason: String? = nil) {
        self.fallbackReason = fallbackReason?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class DaemonController: @unchecked Sendable {
    @TaskLocal private static var currentCodexProjectRouteTraceContext: CodexProjectRouteTraceContext?

    private static let apiKeyFailureCooldownThreshold: Int64 = 3
    private static let apiKeyFailureCooldownSeconds: Int64 = 3_600
    private static let accountModelDiscoveryCacheTTLSeconds: Int64 = 300
    private static let refreshAllUsageConcurrencyLimit = 3
    private static let chatGPTWebImagePollTimeoutSeconds: Int64 = 120
    private static let chatGPTWebImagePollIntervalSeconds: UInt64 = 4

    public let dataDirectory: URL
    public let secretStore: SecretStore
    public let store: SQLiteStore
    public let accountService: AccountService
    public let runtimeState: RuntimeState
    public let publicBaseURLProvider: @Sendable () async throws -> String
    public let adminBaseURLProvider: @Sendable () async throws -> String
    private let manageManagedProxyRuntime: Bool
    private let managedProxyRuntime: (any ManagedProxyRuntimeControlling)?
    private let stickySessionBindings: StickySessionBindingStore
    private let managedProxyNodeCoordinator: ManagedProxyNodeCoordinator
    private let accountModelDiscoveryCache: AccountModelDiscoveryCache
    private let chatCompletionsReasoningCache: ChatCompletionsReasoningCache
    private let ocrImageProcessor: OCRImageProcessor
    private let localOCRModelManager: LocalOCRModelManager
    private let localMLXOCRRuntime: LocalMLXOCRRuntimeService
    private let adminEventHub: AdminEventHub
    private let codexDesktopSessionProjectResolver: CodexDesktopSessionProjectResolver

    public convenience init(
        dataDirectory: URL = Paths.defaultDataDirectory(),
        manageManagedProxyRuntime: Bool = true,
        publicBaseURLProvider: @escaping @Sendable () async throws -> String,
        adminBaseURLProvider: @escaping @Sendable () async throws -> String
    ) throws {
        try self.init(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: manageManagedProxyRuntime,
            publicBaseURLProvider: publicBaseURLProvider,
            adminBaseURLProvider: adminBaseURLProvider,
            secretStore: nil,
            managedProxyRuntimeOverride: nil,
            codexDesktopSessionProjectResolver: nil
        )
    }

    init(
        dataDirectory: URL = Paths.defaultDataDirectory(),
        manageManagedProxyRuntime: Bool = true,
        publicBaseURLProvider: @escaping @Sendable () async throws -> String,
        adminBaseURLProvider: @escaping @Sendable () async throws -> String,
        secretStore: SecretStore?,
        managedProxyRuntimeOverride: (any ManagedProxyRuntimeControlling)?,
        codexDesktopSessionProjectResolver: CodexDesktopSessionProjectResolver? = nil
    ) throws {
        self.dataDirectory = dataDirectory
        self.secretStore = secretStore ?? SecretStore(dataDirectory: dataDirectory)
        self.store = try SQLiteStore(dataDirectory: dataDirectory, secretStore: self.secretStore)
        self.accountService = AccountService(store: self.store, secretStore: self.secretStore)
        self.runtimeState = RuntimeState()
        self.publicBaseURLProvider = publicBaseURLProvider
        self.adminBaseURLProvider = adminBaseURLProvider
        self.manageManagedProxyRuntime = manageManagedProxyRuntime
        self.stickySessionBindings = StickySessionBindingStore()
        self.managedProxyNodeCoordinator = ManagedProxyNodeCoordinator()
        self.accountModelDiscoveryCache = AccountModelDiscoveryCache()
        self.chatCompletionsReasoningCache = ChatCompletionsReasoningCache(store: self.store)
        self.localOCRModelManager = LocalOCRModelManager(dataDirectory: dataDirectory)
        self.localMLXOCRRuntime = LocalMLXOCRRuntimeService(
            dataDirectory: dataDirectory,
            manager: self.localOCRModelManager
        )
        self.ocrImageProcessor = OCRImageProcessor(
            cache: OCRResultCache(store: self.store),
            store: self.store,
            localMLXRuntime: self.localMLXOCRRuntime
        )
        self.adminEventHub = AdminEventHub()
        self.codexDesktopSessionProjectResolver = codexDesktopSessionProjectResolver ?? CodexDesktopSessionProjectResolver()
        self.managedProxyRuntime = manageManagedProxyRuntime
            ? (managedProxyRuntimeOverride ?? ManagedProxyRuntime(dataDirectory: dataDirectory, secretStore: self.secretStore))
            : nil
    }

    public func bootstrap() async throws {
        try await self.importBootstrapSettingsIfNeeded()
        var config = try self.store.loadConfig()
        if config.adminToken.isEmpty {
            config.adminToken = try self.secretStore.adminToken()
        }
        let normalizedConfig = try self.configWithManagedProxySummary(
            self.configWithDefaultProxyAPIKeys(config).normalizedModelRoutingConfig()
        )
        try self.store.saveConfig(normalizedConfig)
        try self.persistConfigSecretMirrors(for: normalizedConfig)
        try await self.syncManagedProxyRuntime(for: normalizedConfig)
        let importConfig = try await self.loadConfigForNetworkRequests()
        try await self.importBootstrapAccountsIfNeeded(config: importConfig)
        try self.accountService.repairStoredManualAccountsIfNeeded()
        try self.ensureAnthropicAccessProxyKeyIfNeeded()
        try await self.reconcileManagedProxyAccountNodeListeners(config: normalizedConfig)
        try self.store.pruneStats(retentionDays: config.statsRetentionDays)
        self.chatCompletionsReasoningCache.pruneExpired()
        await self.ocrImageProcessor.pruneExpiredCache()
    }

    public func loadConfig() async throws -> AppConfig {
        try self.configWithManagedProxySummary(
            self.configWithDefaultProxyAPIKeys(self.store.loadConfig()).normalizedModelRoutingConfig()
        )
    }

    public func saveConfig(_ config: AppConfig) async throws -> AppConfig {
        var updated = config
        if updated.adminToken.isEmpty {
            updated.adminToken = try self.secretStore.adminToken()
        }
        let normalized = try self.configWithManagedProxySummary(
            self.configWithDefaultProxyAPIKeys(updated).normalizedModelRoutingConfig()
        )
        try self.store.saveConfig(normalized)
        try self.persistConfigSecretMirrors(for: normalized)
        try await self.syncManagedProxyRuntime(for: normalized)
        return try self.configWithManagedProxySummary(normalized)
    }

    public func shutdown() async {
        if let listener = await self.runtimeState.takeOAuthCallbackListener() {
            await listener.stop()
        }
        if let managedProxyRuntime, self.manageManagedProxyRuntime {
            await managedProxyRuntime.stop()
        }
    }

    public func status() async throws -> ProxyStatus {
        let config = try await self.loadConfig()
        let publicBaseURL = try await self.publicBaseURLProvider()
        let adminBaseURL = try await self.adminBaseURLProvider()
        return ProxyStatus(
            running: true,
            publicBaseURL: publicBaseURL,
            anthropicBaseURL: Self.anthropicBaseURL(from: publicBaseURL),
            geminiBaseURL: Self.geminiBaseURL(from: publicBaseURL),
            adminBaseURL: adminBaseURL,
            apiKey: config.primaryProxyAPIKeyRecord?.key ?? config.proxyAPIKey,
            activeAccountKey: await self.runtimeState.activeAccountKey,
            activeAccountID: await self.runtimeState.activeAccountID,
            activeAccountLabel: await self.runtimeState.activeAccountLabel,
            lastError: await self.runtimeState.lastError,
            daemonVersion: RuntimeInfo.displayVersion,
            proxyTestAdminTransportMode: .full
        )
    }

    public func authenticateProxyAPIKey(_ candidate: String) async throws -> AuthenticatedProxyKeyContext {
        let config = try await self.loadConfig()
        guard let matched = config.proxyAPIKeys.first(where: {
            $0.enabled && $0.key == candidate
        }) ?? (config.proxyAPIKey == candidate ? config.primaryProxyAPIKeyRecord : nil) else {
            throw ProxyError.message("Invalid proxy api key.")
        }
        return AuthenticatedProxyKeyContext(
            apiKeyHash: Helpers.sha256(matched.key),
            proxyKeyID: matched.id,
            dataSource: matched.dataSource,
            allowedAccountKeys: matched.allowedAccountKeys
        )
    }

    public func authenticateAdminToken(_ candidate: String) async throws {
        let config = try await self.loadConfig()
        guard candidate == config.adminToken else {
            throw ProxyError.message("Invalid admin token.")
        }
    }

    public func rotateProxyAPIKey() async throws -> ProxyStatus {
        var config = try await self.loadConfig()
        let rotatedValue = try self.secretStore.rotateProxyAPIKey()
        if let primaryID = config.primaryProxyAPIKeyID,
           let index = config.proxyAPIKeys.firstIndex(where: { $0.id == primaryID })
        {
            config.proxyAPIKeys[index].key = rotatedValue
        } else if config.proxyAPIKeys.isEmpty == false {
            config.proxyAPIKeys[0].key = rotatedValue
            config.primaryProxyAPIKeyID = config.proxyAPIKeys[0].id
        } else {
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    label: AppConfig.defaultProxyAPIKeyLabel,
                    key: rotatedValue,
                    dataSource: .all,
                    enabled: true
                ),
            ]
            config.primaryProxyAPIKeyID = config.proxyAPIKeys.first?.id
        }
        config.proxyAPIKey = rotatedValue
        let normalized = try self.configWithManagedProxySummary(
            self.configWithDefaultProxyAPIKeys(config).normalizedModelRoutingConfig()
        )
        try self.store.saveConfig(normalized)
        return try await self.status()
    }

    public func listAccounts() async throws -> [AccountSummary] {
        try await self.accountService.listAccounts()
    }

    public func importCurrentAuth(label: String?) async throws -> AccountSummary {
        let summary = try await self.withNetworkConfig {
            try await self.accountService.importCurrentAuth(label: label, config: $0)
        }
        try await self.reconcileManagedProxyAccountNodeListeners()
        return summary
    }

    public func importAuthJSONAccounts(_ items: [AuthJsonImportInput]) async throws -> ImportAccountsResult {
        let result = try await self.withNetworkConfig {
            try await self.accountService.importAuthJSONAccounts(items: items, config: $0)
        }
        try self.ensureAnthropicAccessProxyKeyIfNeeded()
        try await self.reconcileManagedProxyAccountNodeListeners()
        return result
    }

    public func manualAddAPIKeyAccount(_ input: ManualAPIKeyAccountInput) async throws -> AccountSummary {
        let summary = try await self.withNetworkConfig {
            try await self.accountService.manualAddAPIKeyAccount(input, config: $0)
        }
        try self.ensureAnthropicAccessProxyKeyIfNeeded()
        try await self.reconcileManagedProxyAccountNodeListeners()
        return summary
    }

    public func manualAPIKeyAccountDetails(id: String) async throws -> ManualAPIKeyAccountDetails {
        try self.accountService.manualAPIKeyAccountDetails(id: id)
    }

    public func updateManualAPIKeyAccount(id: String, input: UpdateManualAPIKeyAccountRequest) async throws -> AccountSummary {
        let accounts = try await self.accountService.listAccounts()
        let previous = accounts.first(where: { $0.id == id })
        guard let previous else {
            throw ProxyError.message("未找到要更新的账号")
        }

        let existingRecord = try self.store.loadAccountRecord(id: id)
        let updated = try await self.withNetworkConfig(for: existingRecord) {
            try await self.accountService.updateManualAPIKeyAccount(id: id, input: input, config: $0)
        }

        if previous.accountKey != updated.accountKey || !updated.enabled {
            await self.runtimeState.clearActiveIfMatches(accountKey: previous.accountKey)
        }
        await self.runtimeState.setActiveLabelIfMatches(accountKey: updated.accountKey, label: updated.label)

        try self.ensureAnthropicAccessProxyKeyIfNeeded()
        try await self.reconcileManagedProxyAccountNodeListeners()
        return updated
    }

    public func updateAccountLabel(id: String, input: UpdateAccountLabelRequest) async throws -> AccountSummary {
        let updated = try await self.accountService.updateAccountLabel(id: id, input: input)
        await self.runtimeState.setActiveLabelIfMatches(accountKey: updated.accountKey, label: updated.label)
        return updated
    }

    public func updateAccountManagedProxyNode(id: String, input: UpdateAccountManagedProxyNodeRequest) async throws -> AccountSummary {
        let normalizedNodeName = AccountSummary.normalizedManagedProxyNodeName(input.managedProxyNodeName)
        if let normalizedNodeName {
            try await self.validateManagedProxyNodeSelection(normalizedNodeName)
        }
        let summary = try await self.accountService.updateAccountManagedProxyNode(
            id: id,
            input: .init(managedProxyNodeName: normalizedNodeName)
        )
        try await self.reconcileManagedProxyAccountNodeListeners()
        return summary
    }

    public func clearAccountManagedProxyNodes() async throws -> ClearAccountManagedProxyNodesResult {
        let result = try self.accountService.clearAccountManagedProxyNodes()
        try await self.reconcileManagedProxyAccountNodeListeners()
        return result
    }

    public func updateAccountModelRouting(id: String, input: UpdateAccountModelRoutingRequest) async throws -> AccountSummary {
        try await self.accountService.updateAccountModelRouting(
            id: id,
            input: UpdateAccountModelRoutingRequest(
                defaultTargetModel: input.modelRouting?.defaultTargetModel,
                mappings: input.modelRouting?.mappings ?? []
            )
        )
    }

    public func updateAccountReasoningEffort(id: String, input: UpdateAccountReasoningEffortRequest) async throws -> AccountSummary {
        try await self.accountService.updateAccountReasoningEffort(id: id, input: input)
    }

    public func exportAccounts() async throws -> Data {
        try await self.accountService.exportAccounts()
    }

    public func refreshAllUsage(forceRefresh: Bool = true) async throws -> [AccountSummary] {
        let records = try self.store.listAccountRecords()
        guard records.isEmpty == false else {
            return try await self.accountService.listAccounts()
        }

        var nextIndex = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            let initialTaskCount = min(Self.refreshAllUsageConcurrencyLimit, records.count)
            for _ in 0..<initialTaskCount {
                let record = records[nextIndex]
                nextIndex += 1
                group.addTask {
                    _ = try await self.withNetworkConfig(for: record) {
                        try await self.accountService.refreshUsage(id: record.id, config: $0, forceRefresh: forceRefresh)
                    }
                }
            }

            while try await group.next() != nil {
                guard nextIndex < records.count else { continue }
                let record = records[nextIndex]
                nextIndex += 1
                group.addTask {
                    _ = try await self.withNetworkConfig(for: record) {
                        try await self.accountService.refreshUsage(id: record.id, config: $0, forceRefresh: forceRefresh)
                    }
                }
            }
        }
        return try await self.accountService.listAccounts()
    }

    public func refreshAccountUsage(id: String, forceRefresh: Bool = true) async throws -> AccountSummary {
        let record = try self.store.loadAccountRecord(id: id)
        return try await self.withNetworkConfig(for: record) {
            try await self.accountService.refreshUsage(id: id, config: $0, forceRefresh: forceRefresh)
        }
    }

    public func stopAccountCooldown(id: String) async throws -> AccountSummary {
        try await self.accountService.stopAccountCooldown(id: id)
    }

    public func updateAccountCooldownPolicy(id: String, input: UpdateAccountCooldownPolicyRequest) async throws -> AccountSummary {
        try await self.accountService.updateAccountCooldownPolicy(
            id: id,
            automaticCooldownDisabled: input.automaticCooldownDisabled
        )
    }

    public func setAccountEnabled(id: String, enabled: Bool) async throws -> AccountSummary {
        let summary = try await self.accountService.setAccountEnabled(id: id, enabled: enabled)
        if !enabled {
            await self.runtimeState.clearActiveIfMatches(accountKey: summary.accountKey)
            await self.stickySessionBindings.clear(accountKey: summary.accountKey)
            self.chatCompletionsReasoningCache.clear(accountKey: summary.accountKey)
        }
        try self.ensureAnthropicAccessProxyKeyIfNeeded()
        try await self.reconcileManagedProxyAccountNodeListeners()
        return summary
    }

    public func reorderAccounts(ids: [String]) async throws -> [AccountSummary] {
        try await self.accountService.reorderAccounts(ids: ids)
    }

    public func removeAccount(id: String) async throws -> DeleteAccountResult {
        let result = try await self.accountService.removeAccount(id: id)
        await self.runtimeState.clearActiveIfMatches(accountKey: result.accountKey)
        await self.stickySessionBindings.clear(accountKey: result.accountKey)
        self.chatCompletionsReasoningCache.clear(accountKey: result.accountKey)
        try await self.reconcileManagedProxyAccountNodeListeners()
        return result
    }

    public func removeAccounts(_ request: BatchDeleteAccountsRequest) async throws -> BatchDeleteAccountsResult {
        var seen = Set<String>()
        let accountIDs = request.accountIDs.compactMap { rawID -> String? in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.isEmpty == false, seen.insert(id).inserted else { return nil }
            return id
        }

        var deleted: [DeleteAccountResult] = []
        var failures: [BatchDeleteAccountFailure] = []
        for id in accountIDs {
            do {
                let result = try await self.accountService.removeAccount(id: id)
                await self.runtimeState.clearActiveIfMatches(accountKey: result.accountKey)
                await self.stickySessionBindings.clear(accountKey: result.accountKey)
                self.chatCompletionsReasoningCache.clear(accountKey: result.accountKey)
                deleted.append(result)
            } catch {
                failures.append(BatchDeleteAccountFailure(id: id, error: error.localizedDescription))
            }
        }

        if deleted.isEmpty == false {
            try await self.reconcileManagedProxyAccountNodeListeners()
        }
        return BatchDeleteAccountsResult(deleted: deleted, failures: failures)
    }

    public func statsSummary(apiKey: String? = nil) async throws -> AdminStatsSummary {
        try self.store.loadStatsSummary(apiKey: apiKey)
    }

    public func adminEvents() async -> AsyncStream<AdminEvent> {
        await self.adminEventHub.subscribe()
    }

    public func reasoningCacheSummary() async throws -> ReasoningCacheSummary {
        try self.chatCompletionsReasoningCache.summary()
    }

    public func clearReasoningCache(_ request: ClearReasoningCacheRequest) async throws -> ClearReasoningCacheResult {
        try self.chatCompletionsReasoningCache.clear(request)
    }

    public func ocrCacheSummary() async throws -> OCRCacheSummary {
        try await self.ocrImageProcessor.cacheSummary()
    }

    public func clearOCRCache(_ request: ClearOCRCacheRequest) async throws -> ClearOCRCacheResult {
        try await self.ocrImageProcessor.clearCache(request)
    }

    public func ocrRecognitionLogs(request: OCRRecognitionLogListRequest) async throws -> OCRRecognitionLogListResponse {
        try self.store.listOCRRecognitionLogs(request)
    }

    public func ocrRecognitionResult(logID: Int64) async throws -> OCRRecognitionResultLookupResponse {
        try self.store.loadOCRRecognitionResult(logID: logID)
    }


    public func ocrRecognitionLogSummary() async throws -> OCRRecognitionLogSummary {
        try self.store.ocrRecognitionLogSummary()
    }

    public func clearOCRRecognitionLogs(_ request: ClearOCRRecognitionLogsRequest) async throws -> ClearOCRRecognitionLogsResult {
        let deletedCount = try self.store.clearOCRRecognitionLogs(request)
        let summary = try self.store.ocrRecognitionLogSummary()
        return ClearOCRRecognitionLogsResult(deletedCount: deletedCount, summary: summary)
    }

    public func testOCRModel(_ request: OCRModelTestRequest) async throws -> OCRModelTestResult {
        var config = try await self.loadConfig()
        config.ocrModel = request.ocrModel
        config.ocrModel.enabled = true
        config.ocrModel.prompt = request.prompt
        return try await self.ocrImageProcessor.testRecognition(
            OCRModelTestRequest(
                ocrModel: config.ocrModel,
                imageBase64: request.imageBase64,
                mimeType: request.mimeType,
                prompt: request.prompt
            ),
            networkConfig: config,
            logContext: OCRRecognitionLogContext(
                endpoint: "/admin/ocr-test",
                requestedModel: config.ocrModel.recognitionModelLabel
            )
        )
    }

    public func localOCRModels() async throws -> LocalOCRModelsResponse {
        let config = try await self.loadConfig()
        let runtime = await self.localMLXOCRRuntime.status()
        return await self.localOCRModelManager.models(
            config: config.ocrModel,
            runtime: runtime
        )
    }

    public func downloadLocalOCRModel(id: String) async throws -> LocalOCRModelActionResult {
        let config = try await self.loadConfig()
        return try await self.localOCRModelManager.startDownload(id: id, config: config.ocrModel)
    }

    public func verifyLocalOCRModel(id: String) async throws -> LocalOCRModelActionResult {
        let config = try await self.loadConfig()
        return try await self.localOCRModelManager.verify(id: id, config: config.ocrModel)
    }

    public func deleteLocalOCRModel(id: String) async throws -> LocalOCRModelActionResult {
        let config = try await self.loadConfig()
        return try await self.localOCRModelManager.delete(id: id, config: config.ocrModel)
    }

    public func stopLocalOCRRuntime() async throws -> LocalMLXOCRRuntimeStatus {
        await self.localMLXOCRRuntime.stop()
        return await self.localMLXOCRRuntime.status()
    }

    public func proxyAPIKeyUsage(query: RequestLogQuery) async throws -> ProxyAPIKeyUsageReport {
        let timeOnly = query.timeRangeOnly().normalized()
        let bounds = timeOnly.effectiveTimeBounds()
        let aggregates = try self.store.loadProxyAPIKeyUsage(query: timeOnly)
        let config = try await self.loadConfig()
        let configuredByHash = Dictionary(
            uniqueKeysWithValues: config.proxyAPIKeys.map { (Helpers.sha256($0.key), $0) }
        )
        let primaryHash = config.primaryProxyAPIKeyRecord.map { Helpers.sha256($0.key) }

        var seenHashes = Set<String>()
        var entries = aggregates.map { aggregate in
            seenHashes.insert(aggregate.apiKeyHash)
            let configured = configuredByHash[aggregate.apiKeyHash]
            return ProxyAPIKeyUsageEntry(
                apiKeyHash: aggregate.apiKeyHash,
                apiKey: aggregate.apiKey,
                label: configured?.label,
                dataSource: configured?.dataSource ?? .openAI,
                enabled: configured?.enabled,
                isPrimary: aggregate.apiKeyHash == primaryHash,
                requestCount: aggregate.requestCount,
                failureCount: aggregate.failureCount,
                authFailureCount: aggregate.authFailureCount,
                rateLimitCount: aggregate.rateLimitCount,
                quotaFailureCount: aggregate.quotaFailureCount,
                averageLatencyMS: aggregate.averageLatencyMS,
                totalInputTokens: aggregate.totalInputTokens,
                totalOutputTokens: aggregate.totalOutputTokens,
                totalTokens: aggregate.totalTokens,
                lastUsedAt: aggregate.lastUsedAt
            )
        }

        for configured in config.proxyAPIKeys where seenHashes.contains(Helpers.sha256(configured.key)) == false {
            entries.append(
                ProxyAPIKeyUsageEntry(
                    apiKeyHash: Helpers.sha256(configured.key),
                    apiKey: configured.key,
                    label: configured.label,
                    dataSource: configured.dataSource,
                    enabled: configured.enabled,
                    isPrimary: configured.id == config.primaryProxyAPIKeyID,
                    lastUsedAt: nil
                )
            )
        }

        entries.sort {
            if $0.isPrimary != $1.isPrimary {
                return $0.isPrimary && !$1.isPrimary
            }
            if $0.totalTokens != $1.totalTokens {
                return $0.totalTokens > $1.totalTokens
            }
            if $0.requestCount != $1.requestCount {
                return $0.requestCount > $1.requestCount
            }
            return ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0)
        }

        return ProxyAPIKeyUsageReport(
            from: bounds.from,
            to: bounds.to,
            totalRequests: entries.map(\.requestCount).reduce(0, +),
            totalFailures: entries.map(\.failureCount).reduce(0, +),
            totalInputTokens: entries.map(\.totalInputTokens).reduce(0, +),
            totalOutputTokens: entries.map(\.totalOutputTokens).reduce(0, +),
            totalTokens: entries.map(\.totalTokens).reduce(0, +),
            entries: entries
        )
    }

    public func requestLogs(query: RequestLogQuery) async throws -> RequestLogPage {
        try self.store.loadRequestLogs(query: query)
    }

    public func requestLogFilters(query: RequestLogQuery) async throws -> RequestLogFilterOptions {
        try self.store.loadRequestLogFilterOptions(query: query)
    }

    public func exportRequestLogs(query: RequestLogQuery) async throws -> Data {
        let entries = try self.store.loadAllRequestLogs(query: query)
        return RequestLogCSVExport.data(entries: entries, maskAPIKeys: true)
    }

    public func diagnosticRequestBodySummary() async throws -> DiagnosticRequestBodySummary {
        try self.store.diagnosticRequestBodySummary()
    }

    public func diagnosticRequestBodies(requestLogID: Int64? = nil) async throws -> [DiagnosticRequestBodyEntry] {
        try self.store.listDiagnosticRequestBodies(requestLogID: requestLogID)
    }

    public func diagnosticRequestBodyDetail(id: Int64) async throws -> DiagnosticRequestBodyDetail {
        try self.store.loadDiagnosticRequestBodyDetail(id: id)
    }

    public func clearDiagnosticRequestBodies(_ request: ClearDiagnosticRequestBodiesRequest) async throws -> ClearDiagnosticRequestBodiesResult {
        try self.store.clearDiagnosticRequestBodies(request)
    }

    public func managedProxySnapshot() async throws -> ManagedProxySnapshot {
        let loadedConfig = try await self.loadConfig()
        let config = try self.configWithManagedProxySummary(loadedConfig.normalizedModelRoutingConfig())
        let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()

        guard let managedProxyRuntime else {
            return ManagedProxySnapshot(
                mode: config.outboundProxyMode,
                subscriptionConfigured: config.managedProxySummary.subscriptionConfigured,
                subscriptionURL: subscriptionURL,
                providerName: config.managedProxySummary.providerName,
                autoUpdateIntervalHours: config.managedProxySummary.autoUpdateIntervalHours,
                healthcheckURL: config.managedProxySummary.healthcheckURL,
                runtimeState: .stopped,
                controllerReachable: false,
                mixedPort: nil,
                controllerPort: nil,
                currentNodeName: nil,
                pinnedNodeName: config.managedProxySummary.selectedNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : config.managedProxySummary.selectedNodeName,
                pinnedNodeAvailable: false,
                providerUpdatedAt: nil,
                nodes: [],
                lastError: config.outboundProxyMode == .subscription && config.managedProxySummary.subscriptionConfigured
                    ? "本地服务未运行，启动服务后可加载订阅节点并测速。"
                    : nil,
                subscriptionUserinfo: nil
            )
        }

        return try await managedProxyRuntime.snapshot(config: config, subscriptionURL: subscriptionURL)
    }

    public func saveManagedProxyConfig(_ payload: ManagedProxyConfigPayload) async throws -> ManagedProxySnapshot {
        let normalizedURL = try ManagedProxyRuntime.validatedSubscriptionURL(payload.subscriptionURL)
        var config = try await self.loadConfig()
        config.managedProxySummary.providerName = ManagedProxyConfigSummary.defaultProviderName
        config.managedProxySummary.autoUpdateIntervalHours = ManagedProxyConfigSummary.defaultAutoUpdateIntervalHours

        if let normalizedURL {
            try self.secretStore.setMihomoSubscriptionURL(normalizedURL)
            config.managedProxySummary.subscriptionConfigured = true
        } else {
            try self.secretStore.setMihomoSubscriptionURL(nil)
            config.managedProxySummary.subscriptionConfigured = false
            if config.outboundProxyMode == .subscription {
                config.outboundProxyMode = .disabled
            }
        }

        let normalized = try self.configWithManagedProxySummary(config.normalizedModelRoutingConfig())
        try self.store.saveConfig(normalized)
        try await self.syncManagedProxyRuntime(for: normalized)
        return try await self.managedProxySnapshot()
    }

    public func saveManagedProxyHealthcheckConfig(
        _ payload: ManagedProxyHealthcheckConfigPayload
    ) async throws -> ManagedProxySnapshot {
        let normalizedURL = try ManagedProxyRuntime.validatedHealthcheckURL(payload.healthcheckURL)
        var config = try await self.loadConfig()
        config.managedProxySummary.healthcheckURL = normalizedURL
        let normalized = try self.configWithManagedProxySummary(config.normalizedModelRoutingConfig())
        try self.store.saveConfig(normalized)
        try await self.syncManagedProxyRuntime(for: normalized)
        return try await self.managedProxySnapshot()
    }

    public func updateManagedProxySubscription() async throws -> ManagedProxySnapshot {
        guard let managedProxyRuntime else {
            throw ProxyError.message("本地服务未运行，无法更新订阅。")
        }
        let loadedConfig = try await self.loadConfig()
        let config = try self.configWithManagedProxySummary(loadedConfig.normalizedModelRoutingConfig())
        let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
        return try await self.withManagedProxyNodeCoordinator {
            try await managedProxyRuntime.updateSubscription(config: config, subscriptionURL: subscriptionURL)
        }
    }

    public func switchManagedProxyCurrentNode(name: String) async throws -> ManagedProxySnapshot {
        guard let managedProxyRuntime else {
            throw ProxyError.message("本地服务未运行，无法切换当前节点。")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            throw ProxyError.message("请选择一个可用节点。")
        }

        let loadedConfig = try await self.loadConfig()
        let config = try self.configWithManagedProxySummary(loadedConfig.normalizedModelRoutingConfig())
        let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
        return try await self.withManagedProxyNodeCoordinator {
            try await managedProxyRuntime.selectNode(
                name: trimmedName,
                config: config,
                subscriptionURL: subscriptionURL
            )
        }
    }

    public func updateManagedProxyPinnedNode(name: String?) async throws -> ManagedProxySnapshot {
        let normalizedNodeName = AccountSummary.normalizedManagedProxyNodeName(name)
        if let normalizedNodeName {
            try await self.validateManagedProxyNodeSelection(normalizedNodeName)
        }

        var config = try await self.loadConfig()
        config.managedProxySummary.selectedNodeName = normalizedNodeName ?? ""
        let normalized = try self.configWithManagedProxySummary(config.normalizedModelRoutingConfig())
        try self.store.saveConfig(normalized)
        return try await self.managedProxySnapshot()
    }

    public func selectManagedProxyNode(name: String) async throws -> ManagedProxySnapshot {
        guard let managedProxyRuntime else {
            throw ProxyError.message("本地服务未运行，无法切换节点。")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            throw ProxyError.message("请选择一个可用节点。")
        }

        var config = try await self.loadConfig()
        config.managedProxySummary.selectedNodeName = trimmedName
        let normalized = try self.configWithManagedProxySummary(config.normalizedModelRoutingConfig())
        let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
        let snapshot = try await self.withManagedProxyNodeCoordinator {
            try await managedProxyRuntime.selectNode(
                name: trimmedName,
                config: normalized,
                subscriptionURL: subscriptionURL
            )
        }
        try self.store.saveConfig(normalized)
        return snapshot
    }

    public func healthcheckManagedProxy(nodeName: String?) async throws -> ManagedProxySnapshot {
        guard let managedProxyRuntime else {
            throw ProxyError.message("本地服务未运行，无法执行节点测速。")
        }
        let loadedConfig = try await self.loadConfig()
        let config = try self.configWithManagedProxySummary(loadedConfig.normalizedModelRoutingConfig())
        let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
        return try await self.withManagedProxyNodeCoordinator {
            try await managedProxyRuntime.healthcheck(nodeName: nodeName, config: config, subscriptionURL: subscriptionURL)
        }
    }

    public func prepareOAuthLogin(providerFamily: AccountProviderFamily = .openAI) async throws -> PreparedOAuthLogin {
        if let existing = await self.runtimeState.takeOAuthCallbackListener() {
            self.logOAuthEvent("Replacing pending OAuth session before starting a new \(providerFamily.rawValue) authorization.")
            await existing.stop()
        }
        await self.runtimeState.setPendingOAuthLogin(nil)

        let listener = try OAuthCallbackListener.bind(preferredPort: AuthService.defaultOAuthRedirectPort)
        let prepared: (PendingOAuthLogin, PreparedOAuthLogin)
        switch providerFamily {
        case .openAI:
            prepared = try AuthService.prepareOAuthLogin(callbackPort: listener.port)
        case .anthropic:
            prepared = try await self.withNetworkConfig {
                try await AnthropicAuthService.prepareOAuthLogin(callbackPort: listener.port, config: $0)
            }
        case .gemini:
            prepared = try await self.withNetworkConfig {
                try GeminiAuthService.prepareOAuthLogin(callbackPort: listener.port, config: $0)
            }
        }
        let pending = prepared.0

        await self.runtimeState.setPendingOAuthLogin(pending)
        await self.runtimeState.setOAuthCallbackListener(listener)

        listener.start(
            expiresAt: pending.expiresAt,
            onCallback: { [weak self] callbackURL, preferredLanguage in
                guard let self else {
                    return OAuthCallbackPageRenderer.failure(
                        detail: "The local OAuth controller is no longer available. Start the authorization again from AI Coding Proxy.",
                        preferredLanguage: preferredLanguage
                    )
                }
                return await self.handleOAuthBrowserCallback(
                    url: callbackURL,
                    expectedState: pending.state,
                    preferredLanguage: preferredLanguage
                )
            },
            onCancel: { [weak self] in
                await self?.cancelOAuthLogin(expectedState: pending.state)
            },
            onTimeout: { [weak self] in
                await self?.expireOAuthLogin(expectedState: pending.state)
            }
        )
        return prepared.1
    }

    public func completeOAuthCallback(
        providerFamily: AccountProviderFamily? = nil,
        url: String
    ) async throws -> AccountSummary {
        let pendingProviderFamily = await self.runtimeState.pendingOAuthLogin?.providerFamily
        let resolvedProviderFamily = providerFamily ?? pendingProviderFamily ?? .openAI
        return try await self.completeOAuthCallback(
            providerFamily: resolvedProviderFamily,
            url: url,
            expectedState: nil,
            stopListener: true
        )
    }

    public func modelsResponse(
        proxyKey: AuthenticatedProxyKeyContext,
        selectedAccountKey: String? = nil
    ) async throws -> Data {
        let models = try await self.discoveredPublicRouteModels(
            proxyKey: proxyKey,
            selectedAccountKey: selectedAccountKey
        )
        let payload: [String: Any] = [
            "object": "list",
            "data": models.map {
                [
                    "id": $0,
                    "object": "model",
                    "created": 0,
                    "owned_by": "openai",
                ]
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public func proxyTestModelsCatalog(selectedAccountKey: String? = nil) async throws -> ProxyTestModelCatalog {
        let trimmedSelectedAccountKey = self.trimmed(selectedAccountKey)
        guard let trimmedSelectedAccountKey else {
            return .defaultCatalog
        }

        let records = try self.store.listAccountRecords()
        guard let record = records.first(where: { $0.accountKey == trimmedSelectedAccountKey }) else {
            throw ProxyError.message("指定的测试账号不存在。")
        }

        let config = try await self.loadConfigForNetworkRequests()
        let models = await self.discoveredModels(
            for: record,
            config: config
        )
        return self.proxyTestCatalog(
            for: record,
            discoveredModels: models
        )
    }

    private func discoveredPublicRouteModels(
        proxyKey: AuthenticatedProxyKeyContext,
        selectedAccountKey: String?
    ) async throws -> [String] {
        let trimmedSelectedAccountKey = self.trimmed(selectedAccountKey)
        let candidates: [ProxyCandidate]
        do {
            candidates = try await self.loadCandidates(
                selectedAccountKey: trimmedSelectedAccountKey,
                dataSource: proxyKey.dataSource,
                allowedAccountKeys: proxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.openAI, .anthropic]
            )
        } catch {
            if trimmedSelectedAccountKey != nil {
                throw error
            }
            return self.defaultPublicRouteModels(for: proxyKey.dataSource)
        }

        guard !candidates.isEmpty else {
            return self.defaultPublicRouteModels(for: proxyKey.dataSource)
        }

        let config = try await self.loadConfigForNetworkRequests()
        var merged: [String] = []
        for candidate in candidates {
            merged = Self.mergeDiscoveredModels(
                merged,
                adding: await self.discoveredModels(for: candidate, config: config)
            )
        }
        merged = Self.mergeDiscoveredModels(
            merged,
            adding: self.visibleCodexProjectRouteModels(for: proxyKey, config: config)
        )

        if merged.isEmpty {
            return self.defaultPublicRouteModels(for: proxyKey.dataSource)
        }
        return merged
    }

    private func discoveredModels(
        for candidate: ProxyCandidate,
        config: AppConfig
    ) async -> [String] {
        await self.discoveredModels(
            for: candidate.record,
            auth: candidate.auth,
            config: config
        )
    }

    private func discoveredModels(
        for record: AccountRecord,
        config: AppConfig
    ) async -> [String] {
        let auth = try? AuthService.extractAuth(from: record.authJSON, secretStore: self.secretStore)
        return await self.discoveredModels(
            for: record,
            auth: auth,
            config: config
        )
    }

    private func discoveredModels(
        for record: AccountRecord,
        auth: ExtractedAuth?,
        config: AppConfig
    ) async -> [String] {
        if let cached = await self.accountModelDiscoveryCache.models(
            for: record.accountKey,
            updatedAt: record.updatedAt
        ) {
            return cached
        }

        let fallbackModels = self.fallbackDiscoveredModels(for: record, auth: auth)
        guard record.authMode.isManualAPIKey, let auth else {
            await self.accountModelDiscoveryCache.store(
                fallbackModels,
                for: record.accountKey,
                updatedAt: record.updatedAt,
                ttlSeconds: Self.accountModelDiscoveryCacheTTLSeconds
            )
            return fallbackModels
        }

        let resolvedBaseURL = auth.upstreamBaseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty == false
            ? auth.upstreamBaseURL!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : (record.upstreamBaseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty == false
                ? record.upstreamBaseURL!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : auth.providerPreset.defaultBaseURL)

        let resolvedModels: [String]
        do {
            resolvedModels = try await OpenAICompatibleUpstream.probeModels(
                config: config,
                baseURL: resolvedBaseURL,
                apiKey: auth.accessToken,
                providerPreset: auth.providerPreset,
                baseURLMode: auth.baseURLMode
            )
        } catch {
            resolvedModels = fallbackModels
        }

        let normalizedModels = Self.normalizedDiscoveredModels(
            resolvedModels,
            fallback: fallbackModels
        )
        await self.accountModelDiscoveryCache.store(
            normalizedModels,
            for: record.accountKey,
            updatedAt: record.updatedAt,
            ttlSeconds: Self.accountModelDiscoveryCacheTTLSeconds
        )
        return normalizedModels
    }

    private func fallbackDiscoveredModels(
        for record: AccountRecord,
        auth: ExtractedAuth?
    ) -> [String] {
        let effectiveAuthMode = auth?.authMode ?? record.authMode
        let effectiveProviderPreset = auth?.providerPreset ?? record.providerPreset
        switch effectiveAuthMode.primaryPinnedProxyTestDataSource {
        case .openAI:
            let presetDefaults = effectiveAuthMode.isManualAPIKey
                ? effectiveProviderPreset.defaultValidationModelCandidates
                : []
            return presetDefaults.isEmpty ? ProxyTranscoder.supportedModels : presetDefaults
        case .anthropic:
            return ProxyTestModelCatalog.defaultCatalog.anthropicMessages.models
        case .gemini:
            return ProxyTestModelCatalog.defaultCatalog.geminiGenerateContent.models
        case .all:
            return self.defaultPublicRouteModels(for: .all)
        }
    }

    private func proxyTestCatalog(
        for record: AccountRecord,
        discoveredModels: [String]
    ) -> ProxyTestModelCatalog {
        var catalog = ProxyTestModelCatalog.defaultCatalog
        switch record.authMode.primaryPinnedProxyTestDataSource {
        case .openAI:
            catalog.chatCompletions = Self.proxyTestModelGroup(
                from: catalog.chatCompletions,
                models: discoveredModels
            )
            catalog.responses = Self.proxyTestModelGroup(
                from: catalog.responses,
                models: discoveredModels
            )
        case .anthropic:
            catalog.anthropicMessages = Self.proxyTestModelGroup(
                from: catalog.anthropicMessages,
                models: discoveredModels
            )
        case .gemini:
            catalog.geminiGenerateContent = Self.proxyTestModelGroup(
                from: catalog.geminiGenerateContent,
                models: discoveredModels
            )
        case .all:
            break
        }
        return catalog
    }

    private func defaultPublicRouteModels(for dataSource: ProxyDataSource) -> [String] {
        switch dataSource {
        case .all:
            return Self.mergeDiscoveredModels(
                ProxyTranscoder.supportedModels,
                adding: ProxyTestModelCatalog.defaultCatalog.anthropicMessages.models
            )
        case .openAI:
            return ProxyTranscoder.supportedModels
        case .anthropic:
            return ProxyTestModelCatalog.defaultCatalog.anthropicMessages.models
        case .gemini:
            return []
        }
    }

    private static func normalizedDiscoveredModels(
        _ models: [String],
        fallback: [String]
    ) -> [String] {
        let normalized = self.mergeDiscoveredModels([], adding: models)
        return normalized.isEmpty ? self.mergeDiscoveredModels([], adding: fallback) : normalized
    }

    private static func mergeDiscoveredModels(
        _ current: [String],
        adding models: [String]
    ) -> [String] {
        var merged = current
        var seen = Set(current.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            merged.append(trimmed)
        }
        return merged
    }

    private static func proxyTestModelGroup(
        from group: ProxyTestModelGroup,
        models: [String]
    ) -> ProxyTestModelGroup {
        let normalizedModels = self.normalizedDiscoveredModels(models, fallback: group.models)
        let defaultModel = normalizedModels.contains(group.defaultModel)
            ? group.defaultModel
            : (normalizedModels.first ?? group.defaultModel)
        return ProxyTestModelGroup(
            family: group.family,
            models: normalizedModels,
            defaultModel: defaultModel
        )
    }

    public func proxyChatCompletions(
        body: Data,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        headers: [String: String] = [:],
        selectedAccountKey: String? = nil
    ) async throws -> ProxyHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let reasoningEffort = self.reasoningEffort(fromChatCompletionsBody: body)
        let config = try await self.loadConfigForNetworkRequests()
        let dynamicallySupportedModels = Set(
            try await self.discoveredPublicRouteModels(
                proxyKey: proxyKey,
                selectedAccountKey: selectedAccountKey
            )
        ).union(self.visibleCodexProjectRouteModels(for: proxyKey, config: config))
        let allowCustomModelPassthrough = self.isProxyTestConsoleRequest(headers: headers)
        let request = try ProxyTranscoder.convertChatCompletionsRequest(
            object,
            allowCustomModelPassthrough: allowCustomModelPassthrough,
            additionalSupportedModels: dynamicallySupportedModels
        )
        var normalizedRequest = request.request
        var requestedModel = request.model
        var effectiveProxyKey = proxyKey
        var effectiveAPIKeyValue = apiKeyValue
        var projectRouteTraceContext: CodexProjectRouteTraceContext?
        if let routeApplication = try self.codexProjectRouteApplication(
            requestedModel: requestedModel,
            requestPayload: object,
            headers: headers,
            client: .codex,
            config: config,
            authenticatedProxyKey: proxyKey
        ) {
            normalizedRequest["model"] = routeApplication.rule.targetModel
            requestedModel = routeApplication.rule.targetModel
            effectiveProxyKey = routeApplication.proxyKey
            effectiveAPIKeyValue = routeApplication.apiKeyValue
            projectRouteTraceContext = routeApplication.traceContext
        }
        let preserveRequestedCustomModel = (
            allowCustomModelPassthrough
            || ProxyTranscoder.isSupportedClientModel(
                requestedModel,
                additionalSupportedModels: dynamicallySupportedModels
            )
        ) && !ProxyTranscoder.isSupportedClientModel(requestedModel)
        let promptCacheContext = PromptCacheSupport.context(
            headers: headers,
            requestPayload: object,
            normalizedRequest: normalizedRequest,
            requestedModel: requestedModel,
            proxyKey: effectiveProxyKey
        )
        let clientSource = self.requestLogClientSource(
            headers: headers,
            promptCacheContext: promptCacheContext,
            isGeminiPublicRoute: false
        )
        return try await self.withCodexProjectRouteTraceContext(projectRouteTraceContext) {
            if effectiveProxyKey.dataSource == .anthropic {
                return try await self.forwardToAnthropicProvider(
                    endpoint: "/v1/chat/completions",
                    proxyKey: effectiveProxyKey,
                    apiKeyValue: effectiveAPIKeyValue,
                    clientSource: clientSource,
                    promptCacheContext: promptCacheContext,
                    selectedAccountKey: selectedAccountKey,
                    requestedModel: requestedModel,
                    reasoningEffort: reasoningEffort,
                    downstreamStream: request.downstreamStream,
                    normalizedRequest: normalizedRequest,
                    responseMode: .chatCompletions,
                    config: config
                )
            }
            return try await self.forwardToCodex(
                endpoint: "/v1/chat/completions",
                proxyKey: effectiveProxyKey,
                apiKeyValue: effectiveAPIKeyValue,
                clientSource: clientSource,
                promptCacheContext: promptCacheContext,
                selectedAccountKey: selectedAccountKey,
                requestedModel: requestedModel,
                reasoningEffort: reasoningEffort,
                downstreamStream: request.downstreamStream,
                codexRequest: normalizedRequest,
                responseMode: .chatCompletions,
                explicitProxyTestCustomModel: preserveRequestedCustomModel
            )
        }
    }

    public func proxyResponses(
        body: Data,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        headers: [String: String] = [:],
        selectedAccountKey: String? = nil
    ) async throws -> ProxyHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let reasoningEffort = self.reasoningEffort(fromResponsesBody: body)
        let config = try await self.loadConfigForNetworkRequests()
        let dynamicallySupportedModels = Set(
            try await self.discoveredPublicRouteModels(
                proxyKey: proxyKey,
                selectedAccountKey: selectedAccountKey
            )
        ).union(self.visibleCodexProjectRouteModels(for: proxyKey, config: config))
        let allowCustomModelPassthrough = self.isProxyTestConsoleRequest(headers: headers)
        var request = try ProxyTranscoder.normalizeResponsesRequest(
            object,
            allowCustomModelPassthrough: allowCustomModelPassthrough,
            additionalSupportedModels: dynamicallySupportedModels
        )
        var model = request["model"] as? String ?? ProxyTranscoder.defaultModel
        var effectiveProxyKey = proxyKey
        var effectiveAPIKeyValue = apiKeyValue
        var projectRouteTraceContext: CodexProjectRouteTraceContext?
        if let routeApplication = try self.codexProjectRouteApplication(
            requestedModel: model,
            requestPayload: object,
            headers: headers,
            client: .codex,
            config: config,
            authenticatedProxyKey: proxyKey
        ) {
            request["model"] = routeApplication.rule.targetModel
            model = routeApplication.rule.targetModel
            effectiveProxyKey = routeApplication.proxyKey
            effectiveAPIKeyValue = routeApplication.apiKeyValue
            projectRouteTraceContext = routeApplication.traceContext
        }
        let preserveRequestedCustomModel = (
            allowCustomModelPassthrough
            || ProxyTranscoder.isSupportedClientModel(
                model,
                additionalSupportedModels: dynamicallySupportedModels
            )
        ) && !ProxyTranscoder.isSupportedClientModel(model)
        let downstreamStream = (object["stream"] as? Bool) ?? false
        let promptCacheContext = PromptCacheSupport.context(
            headers: headers,
            requestPayload: object,
            normalizedRequest: request,
            requestedModel: model,
            proxyKey: effectiveProxyKey
        )
        let clientSource = self.requestLogClientSource(
            headers: headers,
            promptCacheContext: promptCacheContext,
            isGeminiPublicRoute: false
        )
        return try await self.withCodexProjectRouteTraceContext(projectRouteTraceContext) {
            if effectiveProxyKey.dataSource == .anthropic {
                return try await self.forwardToAnthropicProvider(
                    endpoint: "/v1/responses",
                    proxyKey: effectiveProxyKey,
                    apiKeyValue: effectiveAPIKeyValue,
                    clientSource: clientSource,
                    promptCacheContext: promptCacheContext,
                    selectedAccountKey: selectedAccountKey,
                    requestedModel: model,
                    reasoningEffort: reasoningEffort,
                    downstreamStream: downstreamStream,
                    normalizedRequest: request,
                    responseMode: .responses,
                    config: config
                )
            }
            return try await self.forwardToCodex(
                endpoint: "/v1/responses",
                proxyKey: effectiveProxyKey,
                apiKeyValue: effectiveAPIKeyValue,
                clientSource: clientSource,
                promptCacheContext: promptCacheContext,
                selectedAccountKey: selectedAccountKey,
                requestedModel: model,
                reasoningEffort: reasoningEffort,
                downstreamStream: downstreamStream,
                codexRequest: request,
                responseMode: .responses,
                explicitProxyTestCustomModel: preserveRequestedCustomModel
            )
        }
    }

    public func proxyImages(
        body: Data,
        endpoint: OpenAIImagesEndpoint,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        headers: [String: String] = [:],
        selectedAccountKey: String? = nil
    ) async throws -> ProxyHTTPResponse {
        let info = OpenAIImagesProxySupport.requestInfo(
            body: body,
            headers: headers,
            endpoint: endpoint
        )
        let requestedModel = info.model
        let promptCacheContext = PromptCacheSupport.context(
            headers: headers,
            requestPayload: info.redactedPayloadForPromptCache,
            normalizedRequest: info.redactedPayloadForPromptCache,
            requestedModel: requestedModel,
            proxyKey: proxyKey
        )
        let clientSource = self.requestLogClientSource(
            headers: headers,
            promptCacheContext: promptCacheContext,
            isGeminiPublicRoute: false
        )
        let config = try await self.loadConfigForNetworkRequests()
        let candidates = await self.prioritizedCandidates(
            try await self.loadCandidates(
                selectedAccountKey: selectedAccountKey,
                dataSource: proxyKey.dataSource,
                allowedAccountKeys: proxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.openAI],
                ignoreUsageLimitBlocks: true
            ),
            using: promptCacheContext
        )
        guard candidates.isEmpty == false else {
            throw ProxyError.message(
                self.noAvailableAccountsMessage(
                    for: proxyKey.dataSource,
                    allowedAccountKeys: proxyKey.allowedAccountKeys
                )
            )
        }

        var errors: [String] = []
        for var candidate in candidates {
            let startMS = Helpers.nowMilliseconds()
            do {
                candidate = try await self.refreshedCandidateAuthIfNeeded(candidate)
                switch candidate.auth.authMode {
                case .openAIAPIKey where candidate.auth.providerPreset == .genericOpenAICompatible:
                    return try await self.forwardImagesViaAPIKeyCandidate(
                        body: body,
                        headers: headers,
                        info: info,
                        endpoint: endpoint,
                        proxyKey: proxyKey,
                        apiKeyValue: apiKeyValue,
                        clientSource: clientSource,
                        promptCacheContext: promptCacheContext,
                        candidate: candidate,
                        config: config,
                        startMS: startMS
                    )
                case .chatGPT:
                    return try await self.forwardImagesViaChatGPTCandidate(
                        info: info,
                        endpoint: endpoint,
                        proxyKey: proxyKey,
                        apiKeyValue: apiKeyValue,
                        clientSource: clientSource,
                        promptCacheContext: promptCacheContext,
                        candidate: candidate,
                        config: config,
                        startMS: startMS
                    )
                default:
                    errors.append("\(candidate.record.label): Images API only supports OpenAI ChatGPT OAuth and Generic OpenAI Compatible API key accounts.")
                    continue
                }
            } catch let error as RecordedCandidateFailure {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.rawText)
                errors.append(message)
                await self.setLastError(message)
                if error.shouldContinue {
                    continue
                }
                if let response = error.response {
                    return response
                }
                break
            } catch {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.localizedDescription)
                errors.append(message)
                await self.setLastError(message)
                try? self.noteCandidateAttemptFailure(candidate)
                continue
            }
        }

        throw ProxyError.message(errors.isEmpty ? "没有可用账号完成 Images API 请求" : errors.joined(separator: " | "))
    }

    private func forwardImagesViaAPIKeyCandidate(
        body: Data,
        headers: [String: String],
        info: OpenAIImagesRequestInfo,
        endpoint: OpenAIImagesEndpoint,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        candidate: ProxyCandidate,
        config: AppConfig,
        startMS: Int64
    ) async throws -> ProxyHTTPResponse {
        let resolvedModel = self.resolvedImagesModel(info: info, candidate: candidate, config: config)
        let requestBody = OpenAIImagesProxySupport.bodyByApplyingModel(
            resolvedModel,
            to: body,
            headers: headers,
            info: info
        )
        let url = try self.openAIImagesURL(config: config, auth: candidate.auth, endpoint: endpoint)
        let upstreamHeaders = OpenAIImagesProxySupport.upstreamHeaders(
            apiKey: candidate.auth.accessToken,
            inboundHeaders: headers,
            providerPreset: .genericOpenAICompatible,
            defaultAccept: info.stream ? "text/event-stream" : "application/json"
        )
        return try await self.forwardImagesRawRequest(
            body: requestBody,
            url: url,
            upstreamHeaders: upstreamHeaders,
            info: info,
            endpoint: endpoint,
            proxyKey: proxyKey,
            apiKeyValue: apiKeyValue,
            clientSource: clientSource,
            promptCacheContext: promptCacheContext,
            candidate: candidate,
            requestedModel: info.model,
            actualModel: resolvedModel,
            config: config,
            startMS: startMS
        )
    }

    private func forwardImagesViaChatGPTCandidate(
        info: OpenAIImagesRequestInfo,
        endpoint: OpenAIImagesEndpoint,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        candidate: ProxyCandidate,
        config: AppConfig,
        startMS: Int64
    ) async throws -> ProxyHTTPResponse {
        let resolvedModel = self.resolvedImagesModel(info: info, candidate: candidate, config: config)
        let upstreamURL = self.chatGPTWebURL(config: config, path: "/backend-api/f/conversation")
        do {
            let imagesPayload = try await self.generateImagesViaChatGPTWeb(
                info: info,
                endpoint: endpoint,
                candidate: candidate,
                config: config,
                resolvedModel: resolvedModel
            )
            let payload = try JSONSerialization.data(withJSONObject: imagesPayload)
            try await self.recordImagesSuccess(
                endpoint: endpoint,
                upstreamURL: upstreamURL,
                proxyKey: proxyKey,
                apiKeyValue: apiKeyValue,
                clientSource: clientSource,
                candidate: candidate,
                requestedModel: info.model,
                actualModel: resolvedModel,
                latencyMS: Helpers.nowMilliseconds() - startMS,
                promptCacheContext: promptCacheContext
            )
            return ProxyHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: .bytes(payload)
            )
        } catch let failure as ChatGPTWebImageFailure {
            throw try await self.recordedImagesFailure(
                endpoint: endpoint,
                upstreamURL: failure.upstreamURL,
                proxyKey: proxyKey,
                apiKeyValue: apiKeyValue,
                clientSource: clientSource,
                candidate: candidate,
                requestedModel: info.model,
                actualModel: resolvedModel,
                statusCode: failure.statusCode,
                bodyText: failure.bodyText,
                startMS: startMS,
                shouldContinueOverride: failure.shouldContinueOverride
            )
        }
    }

    private func generateImagesViaChatGPTWeb(
        info: OpenAIImagesRequestInfo,
        endpoint: OpenAIImagesEndpoint,
        candidate: ProxyCandidate,
        config: AppConfig,
        resolvedModel: String
    ) async throws -> [String: Any] {
        let conversationURL = self.chatGPTWebURL(config: config, path: "/backend-api/f/conversation")
        guard endpoint == .generations || endpoint == .edits else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image proxy currently supports /v1/images/generations and /v1/images/edits only.",
                upstreamURL: conversationURL,
                shouldContinueOverride: true
            )
        }
        if info.responseFormat == "url" {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image proxy returns b64_json only; response_format=url requires an OpenAI API key account.",
                upstreamURL: conversationURL,
                shouldContinueOverride: true
            )
        }
        guard let prompt = info.prompt else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image proxy requires a non-empty prompt.",
                upstreamURL: conversationURL,
                shouldContinueOverride: true
            )
        }
        if endpoint == .edits {
            if info.maskImageDataURIs.isEmpty == false {
                throw ChatGPTWebImageFailure(
                    statusCode: 400,
                    bodyText: "ChatGPT OAuth image edits do not support mask inputs yet; use an OpenAI API key account for masked edits.",
                    upstreamURL: conversationURL,
                    shouldContinueOverride: true
                )
            }
            if info.inputImageDataURIs.isEmpty {
                throw ChatGPTWebImageFailure(
                    statusCode: 400,
                    bodyText: "ChatGPT OAuth image edits require at least one base64/data URL/http(s) image input; file-id-only edits are not supported.",
                    upstreamURL: conversationURL,
                    shouldContinueOverride: true
                )
            }
        }

        let count = OpenAIImagesProxySupport.chatGPTWebImageCount(info.n)
        var imageData: [Data] = []
        let session = try await self.chatGPTWebImageSession(candidate: candidate, config: config)
        let requirements = try await self.chatGPTWebImageRequirements(candidate: candidate, config: config, session: session)
        let references = try await self.chatGPTWebUploadedImageReferences(
            for: endpoint == .edits ? info.inputImageDataURIs : [],
            candidate: candidate,
            config: config,
            session: session,
            upstreamURL: conversationURL
        )
        for _ in 0..<count {
            let state = try await self.runChatGPTWebImageTurn(
                prompt: prompt,
                model: resolvedModel,
                imageReferences: references.map(\.payload),
                requirements: requirements,
                candidate: candidate,
                config: config,
                session: session
            )
            let urls = try await self.resolveChatGPTWebImageDownloadURLs(
                state: state,
                candidate: candidate,
                config: config,
                session: session
            )
            let downloaded = try await self.downloadChatGPTWebImages(
                urls: urls,
                candidate: candidate,
                config: config,
                session: session
            )
            imageData.append(contentsOf: downloaded)
        }

        guard imageData.isEmpty == false else {
            throw ChatGPTWebImageFailure(
                statusCode: 502,
                bodyText: "ChatGPT image generation response did not contain downloadable image data.",
                upstreamURL: conversationURL,
                shouldContinueOverride: true
            )
        }
        return OpenAIImagesProxySupport.chatGPTWebImagesAPIResponse(imageData: imageData)
    }

    private func chatGPTWebUploadedImageReferences(
        for imageValues: [String],
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext,
        upstreamURL: String
    ) async throws -> [ChatGPTWebUploadedImageReference] {
        var references: [ChatGPTWebUploadedImageReference] = []
        for (offset, value) in imageValues.enumerated() {
            references.append(
                try await self.chatGPTWebUploadImage(
                    value,
                    index: offset + 1,
                    candidate: candidate,
                    config: config,
                    session: session,
                    upstreamURL: upstreamURL
                )
            )
        }
        return references
    }

    private func chatGPTWebUploadImage(
        _ imageValue: String,
        index: Int,
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext,
        upstreamURL: String
    ) async throws -> ChatGPTWebUploadedImageReference {
        let image = try await self.chatGPTWebImageBinary(
            from: imageValue,
            index: index,
            candidate: candidate,
            config: config,
            upstreamURL: upstreamURL
        )
        let path = "/backend-api/files"
        let url = self.chatGPTWebURL(config: config, path: path)
        let uploadInitBody = try JSONSerialization.data(withJSONObject: [
            "file_name": image.fileName,
            "file_size": image.data.count,
            "use_case": "multimodal",
            "width": image.width,
            "height": image.height,
        ])
        let uploadInitHeaders = self.chatGPTWebHeaders(
            auth: candidate.auth,
            config: config,
            session: session,
            path: path,
            accept: "application/json",
            contentType: "application/json"
        )
        let uploadInitResponse = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: url,
                method: .POST,
                headers: uploadInitHeaders,
                body: uploadInitBody
            )
        }
        guard (200..<300).contains(uploadInitResponse.statusCode) else {
            throw ChatGPTWebImageFailure(
                statusCode: uploadInitResponse.statusCode,
                bodyText: uploadInitResponse.bodyText,
                upstreamURL: url
            )
        }
        guard let uploadObject = try? JSONSerialization.jsonObject(with: uploadInitResponse.body) as? [String: Any],
              let fileID = self.trimmedString(uploadObject["file_id"]),
              let uploadURLValue = self.trimmedString(uploadObject["upload_url"])
        else {
            throw ChatGPTWebImageFailure(
                statusCode: 502,
                bodyText: "ChatGPT image upload init response did not include file_id and upload_url.",
                upstreamURL: url,
                shouldContinueOverride: true
            )
        }

        let uploadURL = self.resolvedChatGPTWebURL(config: config, value: uploadURLValue)
        let baseURL = self.chatGPTWebBaseURL(config: config)
        let blobHeaders: [String: String] = [
            "Content-Type": image.mimeType,
            "x-ms-blob-type": "BlockBlob",
            "x-ms-version": "2020-04-08",
            "Origin": baseURL,
            "Referer": "\(baseURL)/",
            "User-Agent": session.userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8,en-US;q=0.7",
        ]
        let blobResponse = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: uploadURL,
                method: .PUT,
                headers: blobHeaders,
                body: image.data
            )
        }
        guard (200..<300).contains(blobResponse.statusCode) else {
            throw ChatGPTWebImageFailure(
                statusCode: blobResponse.statusCode,
                bodyText: blobResponse.bodyText,
                upstreamURL: uploadURL
            )
        }

        let uploadedPath = "/backend-api/files/\(self.percentEncodedPathComponent(fileID))/uploaded"
        let uploadedURL = self.chatGPTWebURL(config: config, path: uploadedPath)
        let uploadedHeaders = self.chatGPTWebHeaders(
            auth: candidate.auth,
            config: config,
            session: session,
            path: uploadedPath,
            accept: "application/json",
            contentType: "application/json"
        )
        let uploadedResponse = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: uploadedURL,
                method: .POST,
                headers: uploadedHeaders,
                body: Data("{}".utf8)
            )
        }
        guard (200..<300).contains(uploadedResponse.statusCode) else {
            throw ChatGPTWebImageFailure(
                statusCode: uploadedResponse.statusCode,
                bodyText: uploadedResponse.bodyText,
                upstreamURL: uploadedURL
            )
        }

        return ChatGPTWebUploadedImageReference(
            fileID: fileID,
            fileName: image.fileName,
            fileSize: image.data.count,
            mimeType: image.mimeType,
            width: image.width,
            height: image.height
        )
    }

    private func chatGPTWebImageBinary(
        from rawValue: String,
        index: Int,
        candidate: ProxyCandidate,
        config: AppConfig,
        upstreamURL: String
    ) async throws -> ChatGPTWebImageBinary {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image edits received an empty image input.",
                upstreamURL: upstreamURL,
                shouldContinueOverride: true
            )
        }

        let data: Data
        let mimeType: String
        if trimmed.lowercased().hasPrefix("data:") {
            let parsed = try self.chatGPTWebParseDataImage(trimmed, upstreamURL: upstreamURL)
            data = parsed.data
            mimeType = parsed.mimeType
        } else if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                try await HTTPClientFactory.request(
                    config: requestConfig,
                    url: trimmed,
                    method: .GET,
                    headers: ["Accept": "image/*,*/*;q=0.8"]
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ChatGPTWebImageFailure(
                    statusCode: response.statusCode,
                    bodyText: "ChatGPT OAuth image edit input download failed: HTTP \(response.statusCode).",
                    upstreamURL: trimmed,
                    shouldContinueOverride: true
                )
            }
            data = response.body
            mimeType = self.normalizedImageMimeType(
                response.headers["content-type"],
                data: data
            )
        } else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image edits only support base64/data URL/http(s) image inputs; file-id-only edits are not supported.",
                upstreamURL: upstreamURL,
                shouldContinueOverride: true
            )
        }

        guard data.isEmpty == false else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image edit input is empty.",
                upstreamURL: upstreamURL,
                shouldContinueOverride: true
            )
        }
        let normalizedMimeType = self.normalizedImageMimeType(mimeType, data: data)
        guard normalizedMimeType.hasPrefix("image/") else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image edits received an unsupported image format: \(mimeType).",
                upstreamURL: upstreamURL,
                shouldContinueOverride: true
            )
        }
        let dimensions = self.imageDimensions(from: data)
        let fileName = "image_\(max(index, 1)).\(self.fileExtension(forImageMimeType: normalizedMimeType))"
        return ChatGPTWebImageBinary(
            data: data,
            mimeType: normalizedMimeType,
            fileName: fileName,
            width: dimensions.width,
            height: dimensions.height
        )
    }

    private func chatGPTWebParseDataImage(_ value: String, upstreamURL: String) throws -> (mimeType: String, data: Data) {
        guard let comma = value.firstIndex(of: ",") else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image edits received an invalid data URL image input.",
                upstreamURL: upstreamURL,
                shouldContinueOverride: true
            )
        }
        let header = String(value[..<comma]).lowercased()
        guard header.contains(";base64") else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image edits require base64 data URL image inputs.",
                upstreamURL: upstreamURL,
                shouldContinueOverride: true
            )
        }
        let mimeType = header
            .dropFirst("data:".count)
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? "image/png"
        let payload = String(value[value.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else {
            throw ChatGPTWebImageFailure(
                statusCode: 400,
                bodyText: "ChatGPT OAuth image edits only support base64/data URL/http(s) image inputs; file-id-only edits are not supported.",
                upstreamURL: upstreamURL,
                shouldContinueOverride: true
            )
        }
        return (mimeType, data)
    }

    private func chatGPTWebImageSession(
        candidate: ProxyCandidate,
        config: AppConfig
    ) async throws -> ChatGPTWebImageSessionContext {
        var session = ChatGPTWebImageSessionContext()
        let path = "/"
        let url = self.chatGPTWebURL(config: config, path: path)
        let headers = self.chatGPTWebBootstrapHeaders(
            auth: candidate.auth,
            config: config,
            session: session
        )
        let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: url,
                method: .GET,
                headers: headers
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ChatGPTWebImageFailure(
                statusCode: response.statusCode,
                bodyText: response.bodyText,
                upstreamURL: url
            )
        }
        let html = String(decoding: response.body, as: UTF8.self)
        session.powResources = OpenAIImagesProxySupport.chatGPTWebPOWResources(fromHTML: html)
        return session
    }

    private func chatGPTWebImageRequirements(
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext
    ) async throws -> ChatGPTWebImageRequirements {
        let path = "/backend-api/sentinel/chat-requirements"
        let url = self.chatGPTWebURL(config: config, path: path)
        let token = OpenAIImagesProxySupport.chatGPTWebLegacyRequirementsToken(
            userAgent: session.userAgent,
            scriptSources: session.powResources.scriptSources,
            dataBuild: session.powResources.dataBuild
        )
        let body = try JSONSerialization.data(withJSONObject: ["p": token])
        let headers = self.chatGPTWebHeaders(
            auth: candidate.auth,
            config: config,
            session: session,
            path: path,
            accept: "application/json",
            contentType: "application/json"
        )
        let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: url,
                method: .POST,
                headers: headers,
                body: body
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ChatGPTWebImageFailure(
                statusCode: response.statusCode,
                bodyText: response.bodyText,
                upstreamURL: url
            )
        }
        return try self.parseChatGPTWebImageRequirements(
            body: response.body,
            upstreamURL: url,
            sourceP: "",
            session: session
        )
    }

    private func parseChatGPTWebImageRequirements(
        body: Data,
        upstreamURL: String,
        sourceP: String,
        session: ChatGPTWebImageSessionContext
    ) throws -> ChatGPTWebImageRequirements {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ChatGPTWebImageFailure(
                statusCode: 502,
                bodyText: "ChatGPT chat-requirements response was not valid JSON.",
                upstreamURL: upstreamURL
            )
        }
        if let arkose = object["arkose"] as? [String: Any],
           self.boolValue(arkose["required"]) == true
        {
            throw ChatGPTWebImageFailure(
                statusCode: 403,
                bodyText: "chat requirements requires arkose token, which is not implemented",
                upstreamURL: upstreamURL
            )
        }
        let token = self.trimmedString(object["token"])
            ?? self.trimmedString(object["chat_requirements_token"])
            ?? self.trimmedString(object["requirements_token"])
        guard let token else {
            throw ChatGPTWebImageFailure(
                statusCode: 502,
                bodyText: "ChatGPT chat-requirements response did not include a requirements token.",
                upstreamURL: upstreamURL
            )
        }
        var proofToken = ""
        if let proof = object["proofofwork"] as? [String: Any],
           self.boolValue(proof["required"]) == true,
           let seed = self.trimmedString(proof["seed"]),
           let difficulty = self.trimmedString(proof["difficulty"])
        {
            proofToken = try OpenAIImagesProxySupport.chatGPTWebProofToken(
                seed: seed,
                difficulty: difficulty,
                userAgent: session.userAgent,
                scriptSources: session.powResources.scriptSources,
                dataBuild: session.powResources.dataBuild
            )
        }
        var turnstileToken = self.trimmedString(object["turnstile_token"]) ?? ""
        if let turnstile = object["turnstile"] as? [String: Any],
           self.boolValue(turnstile["required"]) == true
        {
            if turnstileToken.isEmpty {
                turnstileToken = self.trimmedString(turnstile["turnstile_token"]) ?? ""
            }
            if turnstileToken.isEmpty {
                turnstileToken = self.trimmedString(turnstile["token"]) ?? ""
            }
            if turnstileToken.isEmpty,
               let dx = self.trimmedString(turnstile["dx"])
                    ?? self.trimmedString(object["turnstile_dx"])
            {
                turnstileToken = OpenAIImagesProxySupport.chatGPTWebTurnstileToken(
                    dx: dx,
                    sourceP: sourceP
                ) ?? ""
            }
        }
        return ChatGPTWebImageRequirements(
            token: token,
            proofToken: proofToken,
            turnstileToken: turnstileToken,
            soToken: self.trimmedString(object["so_token"]) ?? ""
        )
    }

    private func runChatGPTWebImageTurn(
        prompt: String,
        model: String,
        imageReferences: [[String: Any]] = [],
        requirements: ChatGPTWebImageRequirements,
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext
    ) async throws -> ChatGPTWebImageConversationState {
        let preparePath = "/backend-api/f/conversation/prepare"
        let prepareURL = self.chatGPTWebURL(config: config, path: preparePath)
        let prepareBody = try JSONSerialization.data(
            withJSONObject: OpenAIImagesProxySupport.chatGPTWebPreparePayload(prompt: prompt, model: model)
        )
        let prepareHeaders = self.chatGPTWebHeaders(
            auth: candidate.auth,
            config: config,
            session: session,
            path: preparePath,
            accept: "application/json",
            contentType: "application/json",
            requirements: requirements
        )
        let prepareResponse = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: prepareURL,
                method: .POST,
                headers: prepareHeaders,
                body: prepareBody
            )
        }
        guard (200..<300).contains(prepareResponse.statusCode) else {
            throw ChatGPTWebImageFailure(
                statusCode: prepareResponse.statusCode,
                bodyText: prepareResponse.bodyText,
                upstreamURL: prepareURL,
                shouldContinueOverride: OpenAIImagesProxySupport.isResponsesBridgeCompatibilityFailure(
                    statusCode: prepareResponse.statusCode,
                    bodyText: prepareResponse.bodyText
                ) ? true : nil
            )
        }
        guard let prepareObject = try? JSONSerialization.jsonObject(with: prepareResponse.body) as? [String: Any],
              let conduitToken = self.trimmedString(prepareObject["conduit_token"])
        else {
            throw ChatGPTWebImageFailure(
                statusCode: 502,
                bodyText: "ChatGPT image prepare response did not include a conduit token.",
                upstreamURL: prepareURL,
                shouldContinueOverride: true
            )
        }

        let conversationPath = "/backend-api/f/conversation"
        let conversationURL = self.chatGPTWebURL(config: config, path: conversationPath)
        let conversationBody = try JSONSerialization.data(
            withJSONObject: OpenAIImagesProxySupport.chatGPTWebConversationPayload(
                prompt: prompt,
                model: model,
                imageReferences: imageReferences
            )
        )
        let conversationHeaders = self.chatGPTWebHeaders(
            auth: candidate.auth,
            config: config,
            session: session,
            path: conversationPath,
            accept: "text/event-stream",
            contentType: "application/json",
            requirements: requirements,
            conduitToken: conduitToken
        )
        let streamResponse = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.stream(
                config: requestConfig,
                url: conversationURL,
                method: .POST,
                headers: conversationHeaders,
                body: conversationBody
            )
        }
        guard (200..<300).contains(streamResponse.statusCode) else {
            let body = try await self.collectBody(from: streamResponse.body)
            let bodyText = String(decoding: body, as: UTF8.self)
            throw ChatGPTWebImageFailure(
                statusCode: streamResponse.statusCode,
                bodyText: bodyText,
                upstreamURL: conversationURL,
                shouldContinueOverride: OpenAIImagesProxySupport.isResponsesBridgeCompatibilityFailure(
                    statusCode: streamResponse.statusCode,
                    bodyText: bodyText
                ) ? true : nil
            )
        }

        var state = ChatGPTWebImageConversationState()
        var decoder = SSEIncrementalDecoder()
        for try await chunk in streamResponse.body {
            for event in decoder.append(chunk) {
                state.merge(OpenAIImagesProxySupport.chatGPTWebConversationState(from: [event]))
            }
        }
        for event in decoder.finish() {
            state.merge(OpenAIImagesProxySupport.chatGPTWebConversationState(from: [event]))
        }
        if state.hasImageReferences {
            return state
        }
        if let conversationID = state.conversationID {
            let polled = try await self.pollChatGPTWebImageConversation(
                conversationID: conversationID,
                candidate: candidate,
                config: config,
                session: session
            )
            state.merge(polled)
            if state.hasImageReferences {
                return state
            }
        }
        let message = state.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw ChatGPTWebImageFailure(
            statusCode: state.blocked || state.toolInvoked == false ? 400 : 502,
            bodyText: message?.isEmpty == false ? message! : "ChatGPT image generation completed without image references.",
            upstreamURL: conversationURL,
            shouldContinueOverride: true
        )
    }

    private func pollChatGPTWebImageConversation(
        conversationID: String,
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext
    ) async throws -> ChatGPTWebImageConversationState {
        let path = "/backend-api/conversation/\(self.percentEncodedPathComponent(conversationID))"
        let url = self.chatGPTWebURL(config: config, path: path)
        let deadline = Helpers.now() + Self.chatGPTWebImagePollTimeoutSeconds
        var attempt = 0
        while Helpers.now() <= deadline {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: Self.chatGPTWebImagePollIntervalSeconds * 1_000_000_000)
            }
            attempt += 1
            let headers = self.chatGPTWebHeaders(
                auth: candidate.auth,
                config: config,
                session: session,
                path: path,
                accept: "application/json"
            )
            let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                try await HTTPClientFactory.request(
                    config: requestConfig,
                    url: url,
                    method: .GET,
                    headers: headers
                )
            }
            if (200..<300).contains(response.statusCode) {
                let state = OpenAIImagesProxySupport.chatGPTWebConversationState(
                    fromConversationDocument: response.body
                )
                if state.hasImageReferences {
                    return state
                }
                continue
            }
            if [429, 500, 502, 503, 504].contains(response.statusCode) {
                continue
            }
            throw ChatGPTWebImageFailure(
                statusCode: response.statusCode,
                bodyText: response.bodyText,
                upstreamURL: url
            )
        }
        throw ChatGPTWebImageFailure(
            statusCode: 504,
            bodyText: "ChatGPT image generation timed out while waiting for image references.",
            upstreamURL: url,
            shouldContinueOverride: true
        )
    }

    private func resolveChatGPTWebImageDownloadURLs(
        state: ChatGPTWebImageConversationState,
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext
    ) async throws -> [String] {
        var urls: [String] = []
        for fileID in state.fileIDs where fileID != "file_upload" {
            let path = "/backend-api/files/\(self.percentEncodedPathComponent(fileID))/download"
            let url = self.chatGPTWebURL(config: config, path: path)
            let response = try await self.chatGPTWebGET(
                candidate: candidate,
                config: config,
                session: session,
                path: path,
                url: url
            )
            guard (200..<300).contains(response.statusCode) else {
                throw ChatGPTWebImageFailure(statusCode: response.statusCode, bodyText: response.bodyText, upstreamURL: url)
            }
            if let downloadURL = OpenAIImagesProxySupport.chatGPTWebDownloadURL(from: response.body) {
                urls.append(self.resolvedChatGPTWebURL(config: config, value: downloadURL))
            }
        }
        if urls.isEmpty, let conversationID = state.conversationID {
            for sedimentID in state.sedimentIDs {
                let path = "/backend-api/conversation/\(self.percentEncodedPathComponent(conversationID))/attachment/\(self.percentEncodedPathComponent(sedimentID))/download"
                let url = self.chatGPTWebURL(config: config, path: path)
                let response = try await self.chatGPTWebGET(
                    candidate: candidate,
                    config: config,
                    session: session,
                    path: path,
                    url: url
                )
                guard (200..<300).contains(response.statusCode) else {
                    throw ChatGPTWebImageFailure(statusCode: response.statusCode, bodyText: response.bodyText, upstreamURL: url)
                }
                if let downloadURL = OpenAIImagesProxySupport.chatGPTWebDownloadURL(from: response.body) {
                    urls.append(self.resolvedChatGPTWebURL(config: config, value: downloadURL))
                }
            }
        }
        guard urls.isEmpty == false else {
            throw ChatGPTWebImageFailure(
                statusCode: 502,
                bodyText: "ChatGPT image generation did not provide downloadable image URLs.",
                upstreamURL: self.chatGPTWebURL(config: config, path: "/backend-api/f/conversation"),
                shouldContinueOverride: true
            )
        }
        return urls
    }

    private func downloadChatGPTWebImages(
        urls: [String],
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext
    ) async throws -> [Data] {
        var images: [Data] = []
        for url in urls {
            let headers = self.chatGPTWebDownloadHeaders(auth: candidate.auth, config: config, session: session, url: url)
            let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                try await HTTPClientFactory.request(
                    config: requestConfig,
                    url: url,
                    method: .GET,
                    headers: headers
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ChatGPTWebImageFailure(
                    statusCode: response.statusCode,
                    bodyText: response.bodyText,
                    upstreamURL: url
                )
            }
            images.append(response.body)
        }
        return images
    }

    private func chatGPTWebGET(
        candidate: ProxyCandidate,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext,
        path: String,
        url: String
    ) async throws -> SimpleHTTPResponse {
        let headers = self.chatGPTWebHeaders(
            auth: candidate.auth,
            config: config,
            session: session,
            path: path,
            accept: "application/json"
        )
        return try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: url,
                method: .GET,
                headers: headers
            )
        }
    }

    private func chatGPTWebURL(config: AppConfig, path: String) -> String {
        "\(self.chatGPTWebBaseURL(config: config))\(path)"
    }

    private func resolvedChatGPTWebURL(config: AppConfig, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        if trimmed.hasPrefix("/") {
            return "\(self.chatGPTWebBaseURL(config: config))\(trimmed)"
        }
        return "\(self.chatGPTWebBaseURL(config: config))/\(trimmed)"
    }

    private func chatGPTWebBaseURL(config: AppConfig) -> String {
        config.chatGPTBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func chatGPTWebBootstrapHeaders(
        auth: ExtractedAuth,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext
    ) -> [String: String] {
        var headers = self.chatGPTWebBaseHeaders(auth: auth, config: config, session: session)
        headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
        headers["Sec-Fetch-Dest"] = "document"
        headers["Sec-Fetch-Mode"] = "navigate"
        headers["Sec-Fetch-Site"] = "none"
        headers["Sec-Fetch-User"] = "?1"
        headers["Upgrade-Insecure-Requests"] = "1"
        return headers
    }

    private func chatGPTWebHeaders(
        auth: ExtractedAuth,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext,
        path: String,
        accept: String,
        contentType: String? = nil,
        requirements: ChatGPTWebImageRequirements? = nil,
        conduitToken: String? = nil
    ) -> [String: String] {
        var headers = self.chatGPTWebBaseHeaders(auth: auth, config: config, session: session)
        headers["Accept"] = accept
        headers["Sec-Fetch-Dest"] = "empty"
        headers["Sec-Fetch-Mode"] = "cors"
        headers["Sec-Fetch-Site"] = "same-origin"
        headers["X-OpenAI-Target-Path"] = path
        headers["X-OpenAI-Target-Route"] = path
        if let contentType {
            headers["Content-Type"] = contentType
        }
        if let requirements {
            headers["OpenAI-Sentinel-Chat-Requirements-Token"] = requirements.token
            if requirements.proofToken.isEmpty == false {
                headers["OpenAI-Sentinel-Proof-Token"] = requirements.proofToken
            }
        }
        if let conduitToken, conduitToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            headers["X-Conduit-Token"] = conduitToken
        }
        if accept.contains("event-stream") {
            headers["X-Oai-Turn-Trace-Id"] = UUID().uuidString.lowercased()
        }
        return headers
    }

    private func chatGPTWebBaseHeaders(
        auth: ExtractedAuth,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext
    ) -> [String: String] {
        let baseURL = self.chatGPTWebBaseURL(config: config)
        return [
            "Authorization": "Bearer \(auth.accessToken)",
            "User-Agent": session.userAgent,
            "Origin": baseURL,
            "Referer": "\(baseURL)/",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8,en-US;q=0.7",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "Priority": "u=1, i",
            "Sec-Ch-Ua": session.secChUa,
            "Sec-Ch-Ua-Arch": #""x86""#,
            "Sec-Ch-Ua-Bitness": #""64""#,
            "Sec-Ch-Ua-Full-Version": #""143.0.3650.96""#,
            "Sec-Ch-Ua-Full-Version-List": #""Microsoft Edge";v="143.0.3650.96", "Chromium";v="143.0.7499.147", "Not A(Brand";v="24.0.0.0""#,
            "Sec-Ch-Ua-Mobile": session.secChUaMobile,
            "Sec-Ch-Ua-Model": #""""#,
            "Sec-Ch-Ua-Platform": session.secChUaPlatform,
            "Sec-Ch-Ua-Platform-Version": #""19.0.0""#,
            "OAI-Device-Id": session.deviceID,
            "OAI-Session-Id": session.sessionID,
            "OAI-Language": "zh-CN",
            "OAI-Client-Version": session.clientVersion,
            "OAI-Client-Build-Number": session.clientBuildNumber,
            "ChatGPT-Account-Id": auth.accountID,
        ]
    }

    private func chatGPTWebDownloadHeaders(
        auth: ExtractedAuth,
        config: AppConfig,
        session: ChatGPTWebImageSessionContext,
        url: String
    ) -> [String: String] {
        let baseURL = self.chatGPTWebBaseURL(config: config)
        guard url.hasPrefix(baseURL),
              let path = URL(string: url)?.path
        else {
            return [
                "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                "User-Agent": session.userAgent,
            ]
        }
        return self.chatGPTWebHeaders(
            auth: auth,
            config: config,
            session: session,
            path: path,
            accept: "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
        )
    }

    private func normalizedImageMimeType(_ value: String?, data: Data) -> String {
        let contentType = value?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let contentType, ["image/png", "image/jpeg", "image/jpg", "image/webp", "image/gif"].contains(contentType) {
            return contentType == "image/jpg" ? "image/jpeg" : contentType
        }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x47, 0x49, 0x46]) {
            return "image/gif"
        }
        if bytes.count >= 12,
           Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50]
        {
            return "image/webp"
        }
        return contentType ?? "application/octet-stream"
    }

    private func fileExtension(forImageMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "png"
        }
    }

    private func imageDimensions(from data: Data) -> (width: Int, height: Int) {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return (0, 0)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (width, height)
        #else
        return (0, 0)
        #endif
    }

    private func percentEncodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func trimmedString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        let lower = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["1", "true", "yes"].contains(lower)
    }

    private func forwardImagesRawRequest(
        body: Data,
        url: String,
        upstreamHeaders: [String: String],
        info: OpenAIImagesRequestInfo,
        endpoint: OpenAIImagesEndpoint,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        candidate: ProxyCandidate,
        requestedModel: String,
        actualModel: String,
        config: AppConfig,
        startMS: Int64
    ) async throws -> ProxyHTTPResponse {
        if info.stream {
            let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                try await HTTPClientFactory.stream(
                    config: requestConfig,
                    url: url,
                    method: .POST,
                    headers: upstreamHeaders,
                    body: body
                )
            }
            if (200..<300).contains(response.statusCode) == false {
                let data = try await self.collectBody(from: response.body)
                let text = String(decoding: data, as: UTF8.self)
                throw try await self.recordedImagesFailure(
                    endpoint: endpoint,
                    upstreamURL: url,
                    proxyKey: proxyKey,
                    apiKeyValue: apiKeyValue,
                    clientSource: clientSource,
                    candidate: candidate,
                    requestedModel: requestedModel,
                    actualModel: actualModel,
                    statusCode: response.statusCode,
                    bodyText: text,
                    startMS: startMS
                )
            }
            await self.setActive(candidate)
            await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
            return self.makeImagesStreamingProxyResponse(
                upstreamBody: response.body,
                statusCode: response.statusCode,
                headers: response.headers,
                endpoint: endpoint,
                upstreamURL: url,
                proxyKey: proxyKey,
                apiKeyValue: apiKeyValue,
                clientSource: clientSource,
                candidate: candidate,
                requestedModel: requestedModel,
                actualModel: actualModel,
                startMS: startMS
            )
        }

        let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
            try await HTTPClientFactory.request(
                config: requestConfig,
                url: url,
                method: .POST,
                headers: upstreamHeaders,
                body: body
            )
        }
        if (200..<300).contains(response.statusCode) == false {
            throw try await self.recordedImagesFailure(
                endpoint: endpoint,
                upstreamURL: url,
                proxyKey: proxyKey,
                apiKeyValue: apiKeyValue,
                clientSource: clientSource,
                candidate: candidate,
                requestedModel: requestedModel,
                actualModel: actualModel,
                statusCode: response.statusCode,
                bodyText: response.bodyText,
                startMS: startMS
            )
        }
        try await self.recordImagesSuccess(
            endpoint: endpoint,
            upstreamURL: url,
            proxyKey: proxyKey,
            apiKeyValue: apiKeyValue,
            clientSource: clientSource,
            candidate: candidate,
            requestedModel: requestedModel,
            actualModel: actualModel,
            latencyMS: Helpers.nowMilliseconds() - startMS,
            promptCacheContext: promptCacheContext
        )
        return ProxyHTTPResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: .bytes(response.body)
        )
    }

    private func recordedImagesFailure(
        endpoint: OpenAIImagesEndpoint,
        upstreamURL: String,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        candidate: ProxyCandidate,
        requestedModel: String,
        actualModel: String,
        statusCode: Int,
        bodyText: String,
        startMS: Int64,
        shouldContinueOverride: Bool? = nil
    ) async throws -> RecordedCandidateFailure {
        let category = self.classifyFailure(status: statusCode, text: bodyText)
        let publicMessage = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: bodyText)
        let latency = Helpers.nowMilliseconds() - startMS
        try self.recordTrace(
            ProxyRequestTrace(
                endpoint: endpoint.rawValue,
                upstreamURL: upstreamURL,
                apiKeyHash: proxyKey.apiKeyHash,
                accountKey: candidate.record.accountKey,
                accountLabel: candidate.record.label,
                clientSource: clientSource,
                model: requestedModel,
                actualModel: actualModel,
                success: false,
                latencyMS: latency,
                failureCategory: category,
                lastError: Helpers.truncate(bodyText),
                apiKeyValue: apiKeyValue
            )
        )
        await self.setLastError(publicMessage)
        let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
            category: category,
            candidate: candidate,
            recordUsage: candidate.record.usage,
            usageError: candidate.record.usageError,
            text: bodyText
        )
        try self.noteCandidateAttemptFailure(candidate)
        return RecordedCandidateFailure(
            rawText: bodyText,
            shouldContinue: shouldContinueOverride
                ?? (shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate))
        )
    }

    private func recordImagesSuccess(
        endpoint: OpenAIImagesEndpoint,
        upstreamURL: String,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        candidate: ProxyCandidate,
        requestedModel: String,
        actualModel: String,
        latencyMS: Int64,
        promptCacheContext: PromptCacheContext
    ) async throws {
        await self.setActive(candidate)
        try self.recordTrace(
            ProxyRequestTrace(
                endpoint: endpoint.rawValue,
                upstreamURL: upstreamURL,
                apiKeyHash: proxyKey.apiKeyHash,
                accountKey: candidate.record.accountKey,
                accountLabel: candidate.record.label,
                clientSource: clientSource,
                model: requestedModel,
                actualModel: actualModel,
                success: true,
                latencyMS: latencyMS,
                apiKeyValue: apiKeyValue
            )
        )
        try self.noteCandidateAttemptSuccess(candidate)
        await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
    }

    private func makeImagesStreamingProxyResponse(
        upstreamBody: AsyncThrowingStream<Data, Error>,
        statusCode: Int,
        headers: [String: String],
        endpoint: OpenAIImagesEndpoint,
        upstreamURL: String,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        candidate: ProxyCandidate,
        requestedModel: String,
        actualModel: String,
        startMS: Int64
    ) -> ProxyHTTPResponse {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for try await chunk in upstreamBody {
                        continuation.yield(chunk)
                    }
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint.rawValue,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: true,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            apiKeyValue: apiKeyValue
                        )
                    )
                    try? self.noteCandidateAttemptSuccess(candidate)
                    continuation.finish()
                } catch is CancellationError {
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint.rawValue,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: false,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            failureCategory: .cancelled,
                            lastError: "cancelled",
                            apiKeyValue: apiKeyValue
                        )
                    )
                    continuation.finish()
                } catch {
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint.rawValue,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: false,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            failureCategory: .upstream,
                            lastError: Helpers.truncate(error.localizedDescription),
                            apiKeyValue: apiKeyValue
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
        return ProxyHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: .stream(stream)
        )
    }

    private func resolvedImagesModel(
        info: OpenAIImagesRequestInfo,
        candidate: ProxyCandidate,
        config: AppConfig
    ) -> String {
        self.resolveProxyRequestModel(
            requestedModel: info.model,
            sourceAnthropicModel: nil,
            record: candidate.record,
            config: config,
            auth: candidate.auth
        ).resolvedRequestModel
    }

    private func openAIImagesURL(
        config: AppConfig,
        auth: ExtractedAuth,
        endpoint: OpenAIImagesEndpoint
    ) throws -> String {
        let baseURL = auth.upstreamBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = (baseURL?.isEmpty == false ? baseURL! : OpenAICompatibleUpstream.defaultBaseURL)
        return try OpenAICompatibleUpstream.imagesURL(
            from: resolvedBaseURL,
            endpoint: endpoint,
            providerPreset: auth.providerPreset,
            baseURLMode: auth.baseURLMode
        )
    }

    public func proxyAnthropicMessages(
        body: Data,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        headers: [String: String] = [:],
        selectedAccountKey: String? = nil,
        anthropicVersion: String,
        anthropicBeta: String?
    ) async throws -> ProxyHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let request = try AnthropicTranscoder.normalizeMessagesRequest(object)
        let config = try await self.loadConfigForNetworkRequests()
        var rawAnthropicRequest = object
        var normalizedRequest = request.request
        var requestedModel = request.responseModel
        var effectiveProxyKey = proxyKey
        var effectiveAPIKeyValue = apiKeyValue
        var projectRouteTraceContext: CodexProjectRouteTraceContext?
        if let routeApplication = try self.projectRouteApplication(
            requestedModel: requestedModel,
            client: .claudeCode,
            config: config,
            authenticatedProxyKey: proxyKey
        ) {
            rawAnthropicRequest["model"] = routeApplication.rule.targetModel
            normalizedRequest["model"] = routeApplication.rule.targetModel
            requestedModel = routeApplication.rule.targetModel
            effectiveProxyKey = routeApplication.proxyKey
            effectiveAPIKeyValue = routeApplication.apiKeyValue
            projectRouteTraceContext = routeApplication.traceContext
        }
        let promptCacheContext = PromptCacheSupport.context(
            headers: headers,
            requestPayload: rawAnthropicRequest,
            normalizedRequest: normalizedRequest,
            requestedModel: requestedModel,
            proxyKey: effectiveProxyKey,
            sourceAnthropicPayload: rawAnthropicRequest
        )
        let clientSource = self.requestLogClientSource(
            headers: headers,
            promptCacheContext: promptCacheContext,
            isGeminiPublicRoute: false
        )
        return try await self.withCodexProjectRouteTraceContext(projectRouteTraceContext) {
            if effectiveProxyKey.dataSource == .anthropic {
                var response = try await self.forwardToAnthropicProvider(
                    endpoint: "/v1/messages",
                    proxyKey: effectiveProxyKey,
                    apiKeyValue: effectiveAPIKeyValue,
                    clientSource: clientSource,
                    promptCacheContext: promptCacheContext,
                    selectedAccountKey: selectedAccountKey,
                    requestedModel: requestedModel,
                    downstreamStream: request.downstreamStream,
                    normalizedRequest: normalizedRequest,
                    responseMode: .anthropicMessages,
                    sourceAnthropicModel: requestedModel,
                    rawAnthropicRequest: rawAnthropicRequest,
                    anthropicVersion: anthropicVersion,
                    anthropicBeta: anthropicBeta,
                    config: config
                )
                response.headers.merge(
                    self.anthropicResponseHeaders(
                        version: anthropicVersion,
                        beta: anthropicBeta,
                        contentType: request.downstreamStream
                            ? "text/event-stream; charset=utf-8"
                            : "application/json; charset=utf-8"
                    ),
                    uniquingKeysWith: { _, new in new }
                )
                return response
            }
            var response = try await self.forwardToCodex(
                endpoint: "/v1/messages",
                proxyKey: effectiveProxyKey,
                apiKeyValue: effectiveAPIKeyValue,
                clientSource: clientSource,
                promptCacheContext: promptCacheContext,
                selectedAccountKey: selectedAccountKey,
                requestedModel: requestedModel,
                downstreamStream: request.downstreamStream,
                codexRequest: normalizedRequest,
                responseMode: .anthropicMessages,
                sourceAnthropicModel: requestedModel
            )
            response.headers.merge(
                self.anthropicResponseHeaders(
                    version: anthropicVersion,
                    beta: anthropicBeta,
                    contentType: request.downstreamStream
                        ? "text/event-stream; charset=utf-8"
                        : "application/json; charset=utf-8"
                ),
                uniquingKeysWith: { _, new in new }
            )
            return response
        }
    }

    public func geminiModelsResponse() async throws -> Data {
        let payload: [String: Any] = [
            "models": self.geminiSourceModels().map { self.geminiModelObject(for: $0) },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public func geminiModelResponse(model: String) async throws -> Data {
        let normalizedModel = self.normalizedGeminiSourceModel(model)
        return try JSONSerialization.data(withJSONObject: self.geminiModelObject(for: normalizedModel))
    }

    public func proxyGeminiGenerateContent(
        body: Data,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        headers: [String: String] = [:],
        selectedAccountKey: String? = nil,
        model: String,
        downstreamStream: Bool
    ) async throws -> ProxyHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        var request = try GeminiTranscoder.normalizeGenerateContentRequest(object, model: model)
        let promptCacheContext = PromptCacheSupport.context(
            headers: headers,
            requestPayload: object,
            normalizedRequest: request.request,
            requestedModel: request.responseModel,
            proxyKey: proxyKey,
            preferGeminiCLIStickySession: true,
            allowManualAPIKeyStickyBinding: true
        )
        let clientSource = self.requestLogClientSource(
            headers: headers,
            promptCacheContext: promptCacheContext,
            isGeminiPublicRoute: true
        )
        request.context.isGeminiCLISession = promptCacheContext.isGeminiCLISession
        try self.ensureGeminiPublicRouteCLISession(promptCacheContext)
        return try await self.forwardGeminiGenerateContent(
            body: body,
            rawGeminiRequest: object,
            proxyKey: proxyKey,
            apiKeyValue: apiKeyValue,
            clientSource: clientSource,
            promptCacheContext: promptCacheContext,
            selectedAccountKey: selectedAccountKey,
            requestedModel: request.responseModel,
            downstreamStream: downstreamStream,
            normalizedRequest: request.request,
            context: request.context
        )
    }

    public func countGeminiTokens(
        body: Data,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        headers: [String: String] = [:],
        selectedAccountKey: String? = nil,
        model: String
    ) async throws -> ProxyHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        var request = try GeminiTranscoder.normalizeCountTokensRequest(object, model: model)
        let config = try await self.loadConfigForNetworkRequests()
        let promptCacheContext = PromptCacheSupport.context(
            headers: headers,
            requestPayload: object,
            normalizedRequest: request.request,
            requestedModel: request.responseModel,
            proxyKey: proxyKey,
            preferGeminiCLIStickySession: true,
            allowManualAPIKeyStickyBinding: true
        )
        let clientSource = self.requestLogClientSource(
            headers: headers,
            promptCacheContext: promptCacheContext,
            isGeminiPublicRoute: true
        )
        request.context.isGeminiCLISession = promptCacheContext.isGeminiCLISession
        try self.ensureGeminiPublicRouteCLISession(promptCacheContext)
        let candidates = await self.prioritizedCandidates(
            try await self.loadCandidates(
                selectedAccountKey: selectedAccountKey,
                dataSource: proxyKey.dataSource,
                allowedAccountKeys: proxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.gemini]
            ),
            using: promptCacheContext
        )
        guard !candidates.isEmpty else {
            throw ProxyError.message(self.geminiPublicRouteRequiresGoogleGeminiLoginMessage())
        }

        var errors: [String] = []
        for var candidate in candidates {
            let startMS = Helpers.nowMilliseconds()
            do {
                guard candidate.record.authMode == .geminiOAuth else {
                    errors.append(self.geminiPublicRouteRequiresGoogleGeminiLoginMessage())
                    continue
                }
                candidate = try await self.refreshedCandidateAuthIfNeeded(candidate)

                return try await self.countGeminiTokensViaGeminiProvider(
                    rawGeminiRequest: object,
                    proxyKey: proxyKey,
                    apiKeyValue: apiKeyValue,
                    clientSource: clientSource,
                    promptCacheContext: promptCacheContext,
                    candidate: candidate,
                    config: config,
                    requestedModel: request.responseModel,
                    startMS: startMS
                )
            } catch let error as RecordedCandidateFailure {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.rawText)
                errors.append(message)
                await self.setLastError(message)
                if error.shouldContinue {
                    continue
                }
                if let response = error.response {
                    return response
                }
                break
            } catch {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.localizedDescription)
                errors.append(message)
                await self.setLastError(message)
                try? self.noteCandidateAttemptFailure(candidate)
                continue
            }
        }

        throw ProxyError.message(errors.isEmpty ? "没有可用账号完成请求" : errors.joined(separator: " | "))
    }

    private func reasoningEffort(fromChatCompletionsBody body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? NSDictionary else {
            return nil
        }
        return self.trimmedReasoningEffort(object["reasoning_effort"])
    }

    private func reasoningEffort(fromResponsesBody body: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? NSDictionary,
            let reasoning = object["reasoning"] as? NSDictionary
        else {
            return nil
        }
        return self.trimmedReasoningEffort(reasoning["effort"])
    }

    private func trimmedReasoningEffort(_ rawValue: Any?) -> String? {
        guard let value = rawValue as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func requestLogClientSource(
        headers: [String: String],
        promptCacheContext: PromptCacheContext,
        isGeminiPublicRoute: Bool
    ) -> RequestLogClientSource {
        if self.trimmedHeader("x-claude-code-session-id", in: headers) != nil {
            return .claudeCode
        }
        if isGeminiPublicRoute || self.trimmedHeader("x-gemini-api-privileged-user-id", in: headers) != nil {
            return .gemini
        }
        if promptCacheContext.sessionIdentifier != nil {
            return .codex
        }
        return .other
    }

    private func trimmedHeader(_ name: String, in headers: [String: String]) -> String? {
        let alternateName = name.contains("_")
            ? name.replacingOccurrences(of: "_", with: "-")
            : name.replacingOccurrences(of: "-", with: "_")
        let value = headers[name]
            ?? headers[name.lowercased()]
            ?? headers[alternateName]
            ?? headers[alternateName.lowercased()]
            ?? headers.first(where: {
                let key = $0.key.lowercased()
                return key == name.lowercased() || key == alternateName.lowercased()
            })?.value
            ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func adminProxyTestRun(_ input: AdminProxyTestRunRequest) async throws -> ProxyHTTPResponse {
        let body: Data
        if let bodyBase64 = self.trimmed(input.bodyBase64) {
            guard let decoded = Data(base64Encoded: bodyBase64) else {
                throw ProxyError.message("Admin proxy test bodyBase64 must be valid base64.")
            }
            body = decoded
        } else {
            guard let payloadBody = input.payloadJSON.data(using: .utf8) else {
                throw ProxyError.message("Admin proxy test payload must be valid UTF-8 JSON.")
            }
            body = payloadBody
        }
        let selectedAccountKey = self.trimmed(input.selectedAccountKey)
        let proxyAPIKey = self.trimmed(input.proxyAPIKey)
        if input.endpoint == .geminiGenerateContent, proxyAPIKey == nil {
            return try await self.adminProxyTestRunForGeminiOAuth(
                payload: input,
                body: body,
                selectedAccountKey: selectedAccountKey
            )
        }

        guard let proxyAPIKey else {
            throw ProxyError.message("Admin proxy test route requires `proxyAPIKey` for this endpoint.")
        }

        var headers = self.adminProxyTestHeaders(
            selectedAccountKey: selectedAccountKey,
            anthropicVersion: input.anthropicVersion,
            anthropicBeta: input.anthropicBeta
        )
        if let contentType = self.trimmed(input.contentType) {
            headers["content-type"] = contentType
        }
        let proxyKey = try await self.authenticateProxyAPIKey(proxyAPIKey)

        switch input.endpoint {
        case .chatCompletions:
            return try await self.proxyChatCompletions(
                body: body,
                proxyKey: proxyKey,
                apiKeyValue: proxyAPIKey,
                headers: headers,
                selectedAccountKey: selectedAccountKey
            )
        case .responses:
            return try await self.proxyResponses(
                body: body,
                proxyKey: proxyKey,
                apiKeyValue: proxyAPIKey,
                headers: headers,
                selectedAccountKey: selectedAccountKey
            )
        case .imageGenerations:
            return try await self.proxyImages(
                body: body,
                endpoint: .generations,
                proxyKey: proxyKey,
                apiKeyValue: proxyAPIKey,
                headers: headers,
                selectedAccountKey: selectedAccountKey
            )
        case .imageEdits:
            return try await self.proxyImages(
                body: body,
                endpoint: .edits,
                proxyKey: proxyKey,
                apiKeyValue: proxyAPIKey,
                headers: headers,
                selectedAccountKey: selectedAccountKey
            )
        case .anthropicMessages:
            return try await self.proxyAnthropicMessages(
                body: body,
                proxyKey: proxyKey,
                apiKeyValue: proxyAPIKey,
                headers: headers,
                selectedAccountKey: selectedAccountKey,
                anthropicVersion: self.trimmed(input.anthropicVersion) ?? AnthropicTranscoder.defaultAnthropicVersion,
                anthropicBeta: self.trimmed(input.anthropicBeta)
            )
        case .geminiGenerateContent:
            let model = self.normalizedGeminiSourceModel(input.model)
            guard model.isEmpty == false else {
                throw ProxyError.message("Admin proxy test route requires a Gemini model.")
            }
            return try await self.proxyGeminiGenerateContent(
                body: body,
                proxyKey: proxyKey,
                apiKeyValue: proxyAPIKey,
                headers: headers,
                selectedAccountKey: selectedAccountKey,
                model: model,
                downstreamStream: input.stream
            )
        }
    }

    private func adminProxyTestRunForGeminiOAuth(
        payload input: AdminProxyTestRunRequest,
        body: Data,
        selectedAccountKey: String?
    ) async throws -> ProxyHTTPResponse {
        guard let selectedAccountKey else {
            throw ProxyError.message("Admin proxy test route requires `selectedAccountKey`.")
        }

        let model = self.normalizedGeminiSourceModel(input.model)
        guard model.isEmpty == false else {
            throw ProxyError.message("Admin proxy test route requires a Gemini model.")
        }

        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        var request = try GeminiTranscoder.normalizeGenerateContentRequest(object, model: model)
        request.context.isGeminiCLISession = false

        let records = try self.store.listAccountRecords()
        let selectedCandidate = try self.selectedCandidate(
            accountKey: selectedAccountKey,
            records: records,
            now: Helpers.now(),
            dataSource: .gemini,
            allowedProviderFamilies: [.gemini]
        )
        guard selectedCandidate.record.authMode == .geminiOAuth else {
            throw ProxyError.message(self.adminGeminiProxyTestRequiresGoogleGeminiLoginMessage())
        }

        let proxyKey = AuthenticatedProxyKeyContext(
            apiKeyHash: "admin-proxy-test",
            proxyKeyID: "admin-proxy-test",
            dataSource: .gemini,
            allowedAccountKeys: [selectedAccountKey]
        )
        let promptCacheContext = PromptCacheContext(
            sourcePromptCacheKey: nil,
            sessionIdentifier: nil,
            metadataUserID: nil,
            claudeCodeSessionID: nil,
            seedMaterial: nil,
            geminiCLIStickySessionKey: nil,
            isGeminiCLISession: false,
            upstreamPromptCacheKey: nil,
            upstreamSessionID: nil,
            allowManualAPIKeyStickyBinding: false
        )

        return try await self.forwardGeminiGenerateContent(
            body: body,
            rawGeminiRequest: object,
            proxyKey: proxyKey,
            apiKeyValue: "admin-proxy-test",
            clientSource: .other,
            promptCacheContext: promptCacheContext,
            selectedAccountKey: selectedAccountKey,
            requestedModel: request.responseModel,
            downstreamStream: input.stream,
            normalizedRequest: request.request,
            context: request.context
        )
    }

    private func forwardGeminiGenerateContent(
        body: Data,
        rawGeminiRequest: [String: Any],
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        selectedAccountKey: String?,
        requestedModel: String,
        downstreamStream: Bool,
        normalizedRequest: [String: Any],
        context: GeminiRequestContext
    ) async throws -> ProxyHTTPResponse {
        let config = try await self.loadConfigForNetworkRequests()
        let endpoint = downstreamStream
            ? "/v1beta/models/\(requestedModel):streamGenerateContent"
            : "/v1beta/models/\(requestedModel):generateContent"
        let candidates = await self.prioritizedCandidates(
            try await self.loadCandidates(
                selectedAccountKey: selectedAccountKey,
                dataSource: proxyKey.dataSource,
                allowedAccountKeys: proxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.gemini]
            ),
            using: promptCacheContext
        )
        guard !candidates.isEmpty else {
            throw ProxyError.message(self.geminiPublicRouteRequiresGoogleGeminiLoginMessage())
        }

        var errors: [String] = []
        for var candidate in candidates {
            let startMS = Helpers.nowMilliseconds()
            do {
                guard candidate.record.authMode == .geminiOAuth else {
                    errors.append(self.geminiPublicRouteRequiresGoogleGeminiLoginMessage())
                    continue
                }
                candidate = try await self.refreshedCandidateAuthIfNeeded(candidate)
                let modelResolution = self.resolveProxyRequestModel(
                    requestedModel: requestedModel,
                    sourceAnthropicModel: nil,
                    record: candidate.record,
                    config: config,
                    auth: candidate.auth
                )
                let resolvedUpstreamModel = modelResolution.resolvedRequestModel

                let upstream = GeminiAuthService.apiRequest(
                    auth: candidate.auth,
                    method: downstreamStream ? "streamGenerateContent" : "generateContent",
                    accept: downstreamStream ? "text/event-stream" : "application/json",
                    streaming: downstreamStream
                )
                let upstreamURL = upstream.url
                let preparedGeminiRequest = await self.preparedGeminiNativeRequestPayload(
                    rawRequest: rawGeminiRequest,
                    candidate: candidate,
                    context: promptCacheContext,
                    config: config
                )
                let upstreamBody = try GeminiAuthService.generateContentRequestBody(
                    rawRequest: preparedGeminiRequest,
                    model: resolvedUpstreamModel,
                    authJSON: candidate.record.authJSON,
                    sessionID: promptCacheContext.upstreamSessionID
                )

                if downstreamStream {
                    let response = try await self.withNetworkConfig(for: candidate.record) {
                        try await HTTPClientFactory.stream(
                            config: $0,
                            url: upstream.url,
                            method: .POST,
                            headers: upstream.headers,
                            body: upstreamBody
                        )
                    }

                    if (200..<300).contains(response.statusCode) == false {
                        let failureData = try await self.collectBody(from: response.body)
                        let upstreamError = GeminiUpstreamError.fromHTTPResponse(
                            statusCode: response.statusCode,
                            body: failureData
                        )
                        let category = self.classifyFailure(
                            status: upstreamError.httpStatus,
                            text: upstreamError.rawText
                        )
                        let publicMessage = self.publicFacingCandidateFailureMessage(
                            candidate: candidate,
                            rawText: upstreamError.summary
                        )
                        errors.append(publicMessage)
                        let latency = Helpers.nowMilliseconds() - startMS
                        try self.recordTrace(
                            ProxyRequestTrace(
                                endpoint: endpoint,
                                upstreamURL: upstreamURL,
                                apiKeyHash: proxyKey.apiKeyHash,
                                accountKey: candidate.record.accountKey,
                                accountLabel: candidate.record.label,
                                clientSource: clientSource,
                                model: requestedModel,
                                actualModel: resolvedUpstreamModel,
                                success: false,
                                latencyMS: latency,
                                failureCategory: category,
                                lastError: Helpers.truncate(upstreamError.summary),
                                apiKeyValue: apiKeyValue
                            )
                        )
                        await self.setLastError(publicMessage)
                        let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                            category: category,
                            candidate: candidate,
                            recordUsage: candidate.record.usage,
                            usageError: candidate.record.usageError,
                            text: upstreamError.rawText
                        )
                        try self.noteCandidateAttemptFailure(candidate)
                        if shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                            continue
                        }
                        return self.geminiUpstreamProxyResponse(
                            for: upstreamError,
                            contentType: response.headers["content-type"]
                        )
                    }

                    await self.setActive(candidate)
                    return self.makeGeminiPassthroughStreamingResponse(
                        upstreamBody: response.body,
                        statusCode: response.statusCode,
                        headers: response.headers,
                        endpoint: endpoint,
                        upstreamURL: upstream.url,
                        apiKeyHash: proxyKey.apiKeyHash,
                        apiKeyValue: apiKeyValue,
                        clientSource: clientSource,
                        requestedModel: requestedModel,
                        actualModel: resolvedUpstreamModel,
                        candidate: candidate,
                        startMS: startMS,
                        promptCacheContext: promptCacheContext
                    )
                }

                let response = try await self.withNetworkConfig(for: candidate.record) {
                    try await HTTPClientFactory.request(
                        config: $0,
                        url: upstream.url,
                        method: .POST,
                        headers: upstream.headers,
                        body: upstreamBody
                    )
                }

                if (200..<300).contains(response.statusCode) == false {
                    let upstreamError = GeminiUpstreamError.fromHTTPResponse(
                        statusCode: response.statusCode,
                        body: response.body
                    )
                    let category = self.classifyFailure(
                        status: upstreamError.httpStatus,
                        text: upstreamError.rawText
                    )
                    let publicMessage = self.publicFacingCandidateFailureMessage(
                        candidate: candidate,
                        rawText: upstreamError.summary
                    )
                    errors.append(publicMessage)
                    let latency = Helpers.nowMilliseconds() - startMS
                    try self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: resolvedUpstreamModel,
                            success: false,
                            latencyMS: latency,
                            failureCategory: category,
                            lastError: Helpers.truncate(upstreamError.summary),
                            apiKeyValue: apiKeyValue
                        )
                    )
                    await self.setLastError(publicMessage)
                    let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                        category: category,
                        candidate: candidate,
                        recordUsage: candidate.record.usage,
                        usageError: candidate.record.usageError,
                        text: upstreamError.rawText
                    )
                    try self.noteCandidateAttemptFailure(candidate)
                    if shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                        continue
                    }
                    return self.geminiUpstreamProxyResponse(
                        for: upstreamError,
                        contentType: response.headers["content-type"]
                    )
                }

                let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
                let unwrappedPayload = try GeminiAuthService.unwrappedGenerateContentResponse(from: payload)
                let usage = self.geminiUsage(from: payload)
                let latency = Helpers.nowMilliseconds() - startMS
                await self.setActive(candidate)
                try self.recordTrace(
                    ProxyRequestTrace(
                        endpoint: endpoint,
                        upstreamURL: upstreamURL,
                        apiKeyHash: proxyKey.apiKeyHash,
                        accountKey: candidate.record.accountKey,
                        accountLabel: candidate.record.label,
                        clientSource: clientSource,
                        model: requestedModel,
                        actualModel: resolvedUpstreamModel,
                        success: true,
                        latencyMS: latency,
                        usage: usage,
                        apiKeyValue: apiKeyValue
                    )
                )
                try self.noteCandidateAttemptSuccess(candidate)
                await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                return ProxyHTTPResponse(
                    statusCode: response.statusCode,
                    headers: [
                        "content-type": response.headers["content-type"] ?? "application/json; charset=utf-8",
                    ],
                    body: .bytes(try JSONSerialization.data(withJSONObject: unwrappedPayload))
                )
            } catch let error as RecordedCandidateFailure {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.rawText)
                errors.append(message)
                await self.setLastError(message)
                if error.shouldContinue {
                    continue
                }
                if let response = error.response {
                    return response
                }
                break
            } catch {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.localizedDescription)
                errors.append(message)
                await self.setLastError(message)
                try? self.noteCandidateAttemptFailure(candidate)
                continue
            }
        }

        throw ProxyError.message(errors.isEmpty ? "没有可用账号完成请求" : errors.joined(separator: " | "))
    }

    private func countGeminiTokensViaGeminiProvider(
        rawGeminiRequest: [String: Any],
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        candidate: ProxyCandidate,
        config: AppConfig,
        requestedModel: String,
        startMS: Int64
    ) async throws -> ProxyHTTPResponse {
        let modelResolution = self.resolveProxyRequestModel(
            requestedModel: requestedModel,
            sourceAnthropicModel: nil,
            record: candidate.record,
            config: config,
            auth: candidate.auth
        )
        let resolvedUpstreamModel = modelResolution.resolvedRequestModel
        let upstream = GeminiAuthService.apiRequest(
            auth: candidate.auth,
            method: "countTokens",
            accept: "application/json"
        )
        let upstreamURL = upstream.url
        let preparedGeminiRequest = await self.preparedGeminiNativeRequestPayload(
            rawRequest: rawGeminiRequest,
            candidate: candidate,
            context: promptCacheContext,
            config: config
        )
        let requestBody = try GeminiAuthService.countTokensRequestBody(
            rawRequest: preparedGeminiRequest,
            model: resolvedUpstreamModel
        )
        let response = try await self.withNetworkConfig(for: candidate.record) {
            try await HTTPClientFactory.request(
                config: $0,
                url: upstream.url,
                method: .POST,
                headers: upstream.headers,
                body: requestBody
            )
        }

        if (200..<300).contains(response.statusCode) == false {
            let upstreamError = GeminiUpstreamError.fromHTTPResponse(
                statusCode: response.statusCode,
                body: response.body
            )
            let category = self.classifyFailure(
                status: upstreamError.httpStatus,
                text: upstreamError.rawText
            )
            let latency = Helpers.nowMilliseconds() - startMS
            try self.recordTrace(
                ProxyRequestTrace(
                    endpoint: "/v1beta/models/\(requestedModel):countTokens",
                    upstreamURL: upstreamURL,
                    apiKeyHash: proxyKey.apiKeyHash,
                    accountKey: candidate.record.accountKey,
                    accountLabel: candidate.record.label,
                    clientSource: clientSource,
                    model: requestedModel,
                    actualModel: resolvedUpstreamModel,
                    success: false,
                    latencyMS: latency,
                    failureCategory: category,
                    lastError: Helpers.truncate(upstreamError.summary),
                    apiKeyValue: apiKeyValue
                )
            )
            await self.setLastError(
                self.publicFacingCandidateFailureMessage(
                    candidate: candidate,
                    rawText: upstreamError.summary
                )
            )
            let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                category: category,
                candidate: candidate,
                recordUsage: candidate.record.usage,
                usageError: candidate.record.usageError,
                text: upstreamError.rawText
            )
            try self.noteCandidateAttemptFailure(candidate)
            throw RecordedCandidateFailure(
                rawText: upstreamError.summary,
                shouldContinue: shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate),
                response: self.geminiUpstreamProxyResponse(
                    for: upstreamError,
                    contentType: response.headers["content-type"]
                )
            )
        }

        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        let usage = self.geminiUsage(from: payload)
        let latency = Helpers.nowMilliseconds() - startMS
        await self.setActive(candidate)
        try self.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1beta/models/\(requestedModel):countTokens",
                upstreamURL: upstreamURL,
                apiKeyHash: proxyKey.apiKeyHash,
                accountKey: candidate.record.accountKey,
                accountLabel: candidate.record.label,
                clientSource: clientSource,
                model: requestedModel,
                actualModel: resolvedUpstreamModel,
                success: true,
                latencyMS: latency,
                usage: usage,
                apiKeyValue: apiKeyValue
            )
        )
        try self.noteCandidateAttemptSuccess(candidate)
        await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
        return ProxyHTTPResponse(
            statusCode: response.statusCode,
            headers: [
                "content-type": response.headers["content-type"] ?? "application/json; charset=utf-8",
            ],
            body: .bytes(response.body)
        )
    }

    private func geminiUpstreamProxyResponse(
        for error: GeminiUpstreamError,
        contentType: String?
    ) -> ProxyHTTPResponse {
        ProxyHTTPResponse(
            statusCode: error.httpStatus,
            headers: [
                "content-type": self.geminiErrorContentType(contentType),
            ],
            body: .bytes(error.responseData)
        )
    }

    private func geminiErrorContentType(_ contentType: String?) -> String {
        let trimmed = contentType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "application/json; charset=utf-8" : trimmed
    }

    public func countAnthropicTokens(
        body: Data,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        headers: [String: String] = [:],
        selectedAccountKey: String? = nil,
        anthropicVersion: String,
        anthropicBeta: String?
    ) async throws -> ProxyHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let request = try AnthropicTranscoder.normalizeCountTokensRequest(object)
        let config = try await self.loadConfigForNetworkRequests()
        var rawAnthropicRequest = object
        var normalizedRequest = request.request
        var requestedModel = request.responseModel
        var effectiveProxyKey = proxyKey
        var effectiveAPIKeyValue = apiKeyValue
        var projectRouteTraceContext: CodexProjectRouteTraceContext?
        if let routeApplication = try self.projectRouteApplication(
            requestedModel: requestedModel,
            client: .claudeCode,
            config: config,
            authenticatedProxyKey: proxyKey
        ) {
            rawAnthropicRequest["model"] = routeApplication.rule.targetModel
            normalizedRequest["model"] = routeApplication.rule.targetModel
            requestedModel = routeApplication.rule.targetModel
            effectiveProxyKey = routeApplication.proxyKey
            effectiveAPIKeyValue = routeApplication.apiKeyValue
            projectRouteTraceContext = routeApplication.traceContext
        }
        let promptCacheContext = PromptCacheSupport.context(
            headers: headers,
            requestPayload: rawAnthropicRequest,
            normalizedRequest: normalizedRequest,
            requestedModel: requestedModel,
            proxyKey: effectiveProxyKey,
            sourceAnthropicPayload: rawAnthropicRequest
        )
        let clientSource = self.requestLogClientSource(
            headers: headers,
            promptCacheContext: promptCacheContext,
            isGeminiPublicRoute: false
        )
        return try await self.withCodexProjectRouteTraceContext(projectRouteTraceContext) {
            if effectiveProxyKey.dataSource == .anthropic {
                return try await self.countAnthropicTokensViaAnthropicProvider(
                    proxyKey: effectiveProxyKey,
                    apiKeyValue: effectiveAPIKeyValue,
                    clientSource: clientSource,
                    promptCacheContext: promptCacheContext,
                    selectedAccountKey: selectedAccountKey,
                    request: normalizedRequest,
                    requestedModel: requestedModel,
                    rawAnthropicRequest: rawAnthropicRequest,
                    anthropicVersion: anthropicVersion,
                    anthropicBeta: anthropicBeta,
                    config: config
                )
            }
        let candidates = await self.prioritizedCandidates(
            try await self.loadCandidates(
                selectedAccountKey: selectedAccountKey,
                dataSource: effectiveProxyKey.dataSource,
                allowedAccountKeys: effectiveProxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.openAI, .anthropic]
            ),
            using: promptCacheContext
        )
        guard !candidates.isEmpty else {
            throw ProxyError.message(
                self.noAvailableAccountsMessage(
                    for: effectiveProxyKey.dataSource,
                    allowedAccountKeys: effectiveProxyKey.allowedAccountKeys
                )
            )
        }

        var errors: [String] = []
        for var candidate in candidates {
            let startMS = Helpers.nowMilliseconds()
            do {
                candidate = try await self.refreshedCandidateAuthIfNeeded(candidate)

                if candidate.record.providerFamily == .anthropic {
                    return try await self.countAnthropicTokensViaAnthropicProvider(
                        proxyKey: effectiveProxyKey,
                        apiKeyValue: effectiveAPIKeyValue,
                        clientSource: clientSource,
                        promptCacheContext: promptCacheContext,
                        selectedAccountKey: candidate.record.accountKey,
                        request: normalizedRequest,
                        requestedModel: requestedModel,
                        rawAnthropicRequest: rawAnthropicRequest,
                        anthropicVersion: anthropicVersion,
                        anthropicBeta: anthropicBeta,
                        config: config
                    )
                }

                let (resolvedRequest, modelResolution) = self.resolvedCodexRequest(
                    normalizedRequest,
                    requestedModel: requestedModel,
                    sourceAnthropicModel: requestedModel,
                    record: candidate.record,
                    config: config,
                    auth: candidate.auth
                )
                let compatibleRequest = PromptCacheSupport.applyCodexPromptCache(
                    to: resolvedRequest,
                    context: promptCacheContext,
                    auth: candidate.auth
                )
                let adapterUsesChatCompletions = self.usesOpenAIChatCompletionsAdapter(candidate.auth)
                let effectiveRequestedModel = (compatibleRequest["model"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedUpstreamModel = modelResolution.usesAccountModelRouting
                    ? (effectiveRequestedModel?.isEmpty == false ? effectiveRequestedModel! : requestedModel)
                    : candidate.auth.providerPreset.resolvedUpstreamModel(
                    for: effectiveRequestedModel?.isEmpty == false ? effectiveRequestedModel! : requestedModel
                )
                var upstreamDiagnosticMetadata: [String: String] = [:]
                var upstreamRequestBody: [String: Any]
                if adapterUsesChatCompletions {
                    let builtRequest = self.upstreamChatCompletionsRequestWithDiagnostics(
                        from: compatibleRequest,
                        upstreamModel: resolvedUpstreamModel,
                        stream: false,
                        auth: candidate.auth
                    )
                    upstreamRequestBody = builtRequest.body
                    upstreamDiagnosticMetadata = builtRequest.metadata
                } else {
                    upstreamRequestBody = self.compatibleCodexRequest(
                        compatibleRequest,
                        for: candidate.auth,
                        preserveResolvedModel: modelResolution.usesAccountModelRouting
                    )
                }
                if adapterUsesChatCompletions {
                    upstreamRequestBody = self.applyAccountReasoningEffortMapping(
                        to: upstreamRequestBody,
                        candidate: candidate,
                        rawReasoningEffort: nil
                    )
                    let preparedRequest = self.preparedChatCompletionsRequestForReasoningHistory(
                        upstreamRequestBody,
                        candidate: candidate,
                        promptCacheContext: promptCacheContext,
                        forceToolHistoryProtection: rawAnthropicRequest["thinking"] != nil
                    )
                    upstreamRequestBody = preparedRequest.body
                    upstreamDiagnosticMetadata.merge(preparedRequest.metadata) { _, new in new }
                }
                let actualModel = self.loggedActualModel(from: upstreamRequestBody)
                let serialized = try JSONSerialization.data(withJSONObject: upstreamRequestBody)
                let candidateAuth = candidate.auth
                let upstreamSessionID = promptCacheContext.upstreamSessionID
                let (response, upstreamURL) = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                    var upstream = self.upstreamRequest(
                        for: candidateAuth,
                        config: requestConfig,
                        accept: "application/json"
                    )
                    if candidateAuth.authMode == .chatGPT,
                       let sessionID = upstreamSessionID
                    {
                        upstream.headers["session_id"] = sessionID
                    }
                    let response = adapterUsesChatCompletions
                        ? try await self.chatCompletionsAPIKeyRequest(
                            config: requestConfig,
                            url: upstream.url,
                            headers: upstream.headers,
                            body: serialized
                        )
                        : try await HTTPClientFactory.request(
                            config: requestConfig,
                            url: upstream.url,
                            method: .POST,
                            headers: upstream.headers,
                            body: serialized
                        )
                    return (response, upstream.url)
                }

                if (200..<300).contains(response.statusCode) == false {
                    let text = response.bodyText
                    let category = self.classifyFailure(status: response.statusCode, text: text)
                    errors.append(self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text))
                    let latency = Helpers.nowMilliseconds() - startMS
                    try self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: "/v1/messages/count_tokens",
                            upstreamURL: upstreamURL,
                            apiKeyHash: effectiveProxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: false,
                            latencyMS: latency,
                            failureCategory: category,
                            lastError: Helpers.truncate(text),
                            apiKeyValue: effectiveAPIKeyValue
                        )
                    )
                    await self.setLastError("\(candidate.record.label): \(Helpers.truncate(text))")
                    let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                        category: category,
                        candidate: candidate,
                        recordUsage: candidate.record.usage,
                        usageError: candidate.record.usageError,
                        text: text
                    )
                    try self.noteCandidateAttemptFailure(candidate)
                    if shouldContinueAfterRecovery {
                        continue
                    }
                    if self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                        continue
                    }
                    break
                }

                await self.setActive(candidate)
                let completed: [String: Any]
                if adapterUsesChatCompletions {
                    let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
                    completed = ProxyTranscoder.completedResponse(
                        fromChatCompletion: object,
                        requestedModel: requestedModel,
                        input: compatibleRequest["input"]
                    )
                    self.chatCompletionsReasoningCache.record(
                        completedResponse: completed,
                        accountKey: candidate.record.accountKey,
                        sessionKey: self.chatCompletionsReasoningSessionKey(from: promptCacheContext)
                    )
                } else {
                    guard let resolvedCompleted = self.completedResponse(from: response.body) else {
                        throw ProxyError.message("上游未返回可解析的 completed response")
                    }
                    completed = resolvedCompleted
                }

                let usage = ProxyTranscoder.usageFromCompletedResponse(completed)
                let payload = try JSONSerialization.data(withJSONObject: AnthropicTranscoder.countTokensResponse(from: usage))
                let latency = Helpers.nowMilliseconds() - startMS
                try self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: "/v1/messages/count_tokens",
                            upstreamURL: upstreamURL,
                            apiKeyHash: effectiveProxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: true,
                            latencyMS: latency,
                            usage: usage,
                            apiKeyValue: effectiveAPIKeyValue
                        )
                    )
                try self.noteCandidateAttemptSuccess(candidate)
                await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                return ProxyHTTPResponse(
                    statusCode: 200,
                    headers: self.anthropicResponseHeaders(
                        version: anthropicVersion,
                        beta: anthropicBeta,
                        contentType: "application/json; charset=utf-8"
                    ),
                    body: .bytes(payload)
                )
            } catch let error as RecordedCandidateFailure {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.rawText)
                errors.append(message)
                await self.setLastError(message)
                if error.shouldContinue {
                    continue
                }
                if let response = error.response {
                    return response
                }
                break
            } catch {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.localizedDescription)
                errors.append(message)
                await self.setLastError(message)
                try? self.noteCandidateAttemptFailure(candidate)
                continue
            }
        }

        throw ProxyError.message(errors.isEmpty ? "没有可用账号完成请求" : errors.joined(separator: " | "))
        }
    }

    private func handleOAuthBrowserCallback(
        url: String,
        expectedState: String,
        preferredLanguage: OAuthCallbackPageLanguage
    ) async -> OAuthCallbackPageResponse {
        do {
            let providerFamily = await self.runtimeState.pendingOAuthLogin?.providerFamily ?? .openAI
            let account = try await self.completeOAuthCallback(
                providerFamily: providerFamily,
                url: url,
                expectedState: expectedState,
                stopListener: false
            )
            return OAuthCallbackPageRenderer.success(
                accountLabel: account.label,
                preferredLanguage: preferredLanguage
            )
        } catch {
            return OAuthCallbackPageRenderer.failure(
                detail: error.localizedDescription,
                preferredLanguage: preferredLanguage
            )
        }
    }

    private func expireOAuthLogin(expectedState: String) async {
        self.logOAuthEvent("Expiring OAuth session for state \(expectedState).")
        _ = await self.runtimeState.clearOAuthSessionIfMatches(state: expectedState)
    }

    private func cancelOAuthLogin(expectedState: String) async {
        self.logOAuthEvent("Cancelling OAuth session for state \(expectedState).")
        _ = await self.runtimeState.clearOAuthSessionIfMatches(state: expectedState)
    }

    private func completeOAuthCallback(
        providerFamily: AccountProviderFamily,
        url: String,
        expectedState: String?,
        stopListener: Bool
    ) async throws -> AccountSummary {
        let pending = await self.runtimeState.pendingOAuthLogin
        guard let pending else {
            throw ProxyError.message("没有进行中的 OAuth 登录")
        }
        if let expectedState, pending.state != expectedState {
            throw ProxyError.message("当前 OAuth 会话已失效，请重新生成授权链接")
        }

        do {
            let config = try await self.loadConfigForNetworkRequests()
            let authJSON: String
            switch providerFamily {
            case .openAI:
                authJSON = try await AuthService.completeOAuthCallback(pending: pending, callbackURL: url, config: config)
            case .anthropic:
                authJSON = try await AnthropicAuthService.completeOAuthCallback(
                    pending: pending,
                    callbackURL: url,
                    config: config,
                    secretStore: self.secretStore
                )
            case .gemini:
                authJSON = try await GeminiAuthService.completeOAuthCallback(
                    pending: pending,
                    callbackURL: url,
                    config: config,
                    secretStore: self.secretStore
                )
            }
            let summary = try await self.importCompletedOAuthAccount(
                authJSON: authJSON,
                providerFamily: providerFamily,
                config: config
            )
            try await self.finishOAuthSession(state: pending.state, stopListener: stopListener)
            return summary
        } catch {
            self.logOAuthEvent(
                "OAuth completion failed for \(providerFamily.rawValue); keeping the current session active for retry. " +
                    Helpers.truncate(error.localizedDescription)
            )
            throw error
        }
    }

    func importCompletedOAuthAccount(
        authJSON: String,
        providerFamily: AccountProviderFamily,
        config: AppConfig
    ) async throws -> AccountSummary {
        let result = try await self.accountService.importAuthJSONAccounts(
            items: [.init(source: "oauth", content: authJSON, label: nil)],
            config: config
        )
        if let failure = result.failures.first {
            throw ProxyError.message(failure.error)
        }
        let extracted = try AuthService.extractAuth(from: authJSON, secretStore: self.secretStore)
        let key = AuthService.accountKey(from: extracted)
        if providerFamily == .openAI {
            try self.accountService.updateUsageWindowsVisible(accountKey: key, visible: false)
        }
        let accounts = try await self.accountService.listAccounts()
        guard let summary = accounts.first(where: { $0.accountKey == key }) else {
            throw ProxyError.message("OAuth 账号导入后未找到账号")
        }
        try self.ensureAnthropicAccessProxyKeyIfNeeded()
        try await self.reconcileManagedProxyAccountNodeListeners(config: config)
        return summary
    }

    private func finishOAuthSession(state: String, stopListener: Bool) async throws {
        self.logOAuthEvent("Finishing OAuth session for state \(state).")
        let listener = await self.runtimeState.clearOAuthSessionIfMatches(state: state)
        if stopListener, let listener {
            await listener.stop()
        }
    }

    private func forwardToAnthropicProvider(
        endpoint: String,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        selectedAccountKey: String? = nil,
        requestedModel: String,
        reasoningEffort: String? = nil,
        downstreamStream: Bool,
        normalizedRequest: [String: Any],
        responseMode: ResponseMode,
        sourceAnthropicModel: String? = nil,
        geminiRequestContext: GeminiRequestContext? = nil,
        rawAnthropicRequest: [String: Any]? = nil,
        anthropicVersion: String? = nil,
        anthropicBeta: String? = nil,
        config: AppConfig? = nil
    ) async throws -> ProxyHTTPResponse {
        let resolvedConfig: AppConfig
        if let providedConfig = config {
            resolvedConfig = providedConfig
        } else {
            resolvedConfig = try await self.loadConfigForNetworkRequests()
        }
        let candidates = await self.prioritizedCandidates(
            try await self.loadCandidates(
                selectedAccountKey: selectedAccountKey,
                dataSource: .anthropic,
                allowedAccountKeys: proxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.anthropic]
            ),
            using: promptCacheContext
        )
        guard !candidates.isEmpty else {
            throw ProxyError.message(
                self.noAvailableAccountsMessage(
                    for: .anthropic,
                    allowedAccountKeys: proxyKey.allowedAccountKeys
                )
            )
        }

        var errors: [String] = []
        for var candidate in candidates {
            let startMS = Helpers.nowMilliseconds()
            do {
                candidate = try await self.refreshedCandidateAuthIfNeeded(candidate)

                let modelResolution = self.resolveProxyRequestModel(
                    requestedModel: requestedModel,
                    sourceAnthropicModel: sourceAnthropicModel,
                    record: candidate.record,
                    config: resolvedConfig,
                    auth: candidate.auth
                )
                let upstreamModel = modelResolution.usesAccountModelRouting
                    ? modelResolution.resolvedRequestModel
                    : self.resolveOpenAIToAnthropicModel(
                        requestedModel: modelResolution.resolvedRequestModel
                    )
                let preparedRawAnthropicRequest: [String: Any]?
                if let rawAnthropicRequest {
                    preparedRawAnthropicRequest = await self.anthropicRequestByApplyingOCRIfNeeded(
                        rawAnthropicRequest,
                        candidate: candidate,
                        config: resolvedConfig,
                        endpoint: "/v1/messages",
                        requestedModel: requestedModel
                    )
                } else {
                    preparedRawAnthropicRequest = nil
                }
                let anthropicRequest = preparedRawAnthropicRequest.map {
                    self.preparedAnthropicRequestPayload(
                        rawPayload: $0,
                        upstreamModel: upstreamModel,
                        stream: downstreamStream,
                        candidate: candidate
                    )
                } ?? AnthropicUpstreamBridge.normalizeRequest(
                    normalizedRequest,
                    upstreamModel: upstreamModel,
                    stream: downstreamStream
                )
                let actualModel = self.loggedActualModel(from: anthropicRequest)
                let serialized = try JSONSerialization.data(withJSONObject: anthropicRequest)
                let upstreamRequest = self.anthropicUpstreamRequest(
                    for: candidate.auth,
                    path: "/v1/messages",
                    stream: downstreamStream,
                    anthropicVersion: anthropicVersion ?? AnthropicTranscoder.defaultAnthropicVersion,
                    anthropicBeta: anthropicBeta
                )
                let upstreamHeaders = PromptCacheSupport.applyAnthropicSessionHeader(
                    to: upstreamRequest.headers,
                    context: promptCacheContext
                )
                let upstreamURL = upstreamRequest.url

                if downstreamStream {
                    let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                        try await HTTPClientFactory.stream(
                            config: requestConfig,
                            url: upstreamURL,
                            method: .POST,
                            headers: upstreamHeaders,
                            body: serialized
                        )
                    }
                    if (200..<300).contains(response.statusCode) == false {
                        let body = try await self.collectBody(from: response.body)
                        let text = String(decoding: body, as: UTF8.self)
                        let category = self.classifyFailure(status: response.statusCode, text: text)
                        errors.append(self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text))
                        let latency = Helpers.nowMilliseconds() - startMS
                        try self.recordTrace(
                            ProxyRequestTrace(
                                endpoint: endpoint,
                                upstreamURL: upstreamURL,
                                apiKeyHash: proxyKey.apiKeyHash,
                                accountKey: candidate.record.accountKey,
                                accountLabel: candidate.record.label,
                                clientSource: clientSource,
                                model: requestedModel,
                                actualModel: actualModel,
                                reasoningEffort: reasoningEffort,
                                success: false,
                                latencyMS: latency,
                                failureCategory: category,
                                lastError: Helpers.truncate(text),
                                apiKeyValue: apiKeyValue
                            )
                        )
                        await self.setLastError("\(candidate.record.label): \(Helpers.truncate(text))")
                        let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                            category: category,
                            candidate: candidate,
                            recordUsage: candidate.record.usage,
                            usageError: candidate.record.usageError,
                            text: text
                        )
                        try self.noteCandidateAttemptFailure(candidate)
                        if shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                            continue
                        }
                        break
                    }

                    await self.setActive(candidate)
                    if responseMode == .anthropicMessages {
                        await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                        return self.makeAnthropicPassthroughStreamingResponse(
                            upstreamBody: response.body,
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            apiKeyValue: apiKeyValue,
                            clientSource: clientSource,
                            requestedModel: requestedModel,
                            actualModel: actualModel,
                            candidate: candidate,
                            startMS: startMS,
                            reasoningEffort: reasoningEffort,
                            anthropicVersion: anthropicVersion ?? AnthropicTranscoder.defaultAnthropicVersion,
                            anthropicBeta: anthropicBeta
                        )
                    }
                    let syntheticStream = self.anthropicToSyntheticResponseStream(
                        upstreamBody: response.body,
                        requestedModel: requestedModel
                    )
                    await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                    return self.makeStreamingProxyResponse(
                        upstreamBody: syntheticStream,
                        endpoint: endpoint,
                        upstreamURL: upstreamURL,
                        apiKeyHash: proxyKey.apiKeyHash,
                        apiKeyValue: apiKeyValue,
                        clientSource: clientSource,
                        requestedModel: requestedModel,
                        actualModel: actualModel,
                        responseMode: responseMode,
                        geminiRequestContext: geminiRequestContext,
                        candidate: candidate,
                        startMS: startMS,
                        reasoningEffort: reasoningEffort
                    )
                }

                let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                    try await HTTPClientFactory.request(
                        config: requestConfig,
                        url: upstreamURL,
                        method: .POST,
                        headers: upstreamHeaders,
                        body: serialized
                    )
                }
                if (200..<300).contains(response.statusCode) == false {
                    let text = response.bodyText
                    let category = self.classifyFailure(status: response.statusCode, text: text)
                    errors.append(self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text))
                    let latency = Helpers.nowMilliseconds() - startMS
                    try self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            reasoningEffort: reasoningEffort,
                            success: false,
                            latencyMS: latency,
                            failureCategory: category,
                            lastError: Helpers.truncate(text),
                            apiKeyValue: apiKeyValue
                        )
                    )
                    await self.setLastError("\(candidate.record.label): \(Helpers.truncate(text))")
                    let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                        category: category,
                        candidate: candidate,
                        recordUsage: candidate.record.usage,
                        usageError: candidate.record.usageError,
                        text: text
                    )
                    try self.noteCandidateAttemptFailure(candidate)
                    if shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                        continue
                    }
                    break
                }

                await self.setActive(candidate)
                let anthropicMessage = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
                let normalizedAnthropicMessage = self.normalizedAnthropicMessage(anthropicMessage)
                let usage = self.anthropicUsage(from: normalizedAnthropicMessage)
                let payload: Data
                switch responseMode {
                case .anthropicMessages:
                    payload = try JSONSerialization.data(withJSONObject: normalizedAnthropicMessage)
                case .responses:
                    let completed = AnthropicUpstreamBridge.completedResponse(
                        from: normalizedAnthropicMessage,
                        requestedModel: requestedModel
                    )
                    payload = try JSONSerialization.data(withJSONObject: completed)
                case .chatCompletions:
                    let completed = AnthropicUpstreamBridge.completedResponse(
                        from: normalizedAnthropicMessage,
                        requestedModel: requestedModel
                    )
                    payload = try JSONSerialization.data(
                        withJSONObject: ProxyTranscoder.chatCompletionFromCompletedResponse(
                            completedResponse: completed,
                            requestedModel: requestedModel
                        )
                    )
                case .geminiGenerateContent:
                    let completed = AnthropicUpstreamBridge.completedResponse(
                        from: normalizedAnthropicMessage,
                        requestedModel: requestedModel
                    )
                    payload = try JSONSerialization.data(
                        withJSONObject: GeminiTranscoder.generateContentResponse(
                            from: completed,
                            requestedModel: requestedModel,
                            context: geminiRequestContext ?? .default(sourceModel: requestedModel)
                        )
                    )
                }

                let latency = Helpers.nowMilliseconds() - startMS
                try self.recordTrace(
                    ProxyRequestTrace(
                        endpoint: endpoint,
                        upstreamURL: upstreamURL,
                        apiKeyHash: proxyKey.apiKeyHash,
                        accountKey: candidate.record.accountKey,
                        accountLabel: candidate.record.label,
                        clientSource: clientSource,
                        model: requestedModel,
                        actualModel: actualModel,
                        reasoningEffort: reasoningEffort,
                        success: true,
                        latencyMS: latency,
                        usage: usage,
                        apiKeyValue: apiKeyValue
                    )
                )
                try self.noteCandidateAttemptSuccess(candidate)
                await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                return ProxyHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: .bytes(payload)
                )
            } catch let error as RecordedCandidateFailure {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.rawText)
                errors.append(message)
                await self.setLastError(message)
                if error.shouldContinue {
                    continue
                }
                if let response = error.response {
                    return response
                }
                break
            } catch {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.localizedDescription)
                errors.append(message)
                await self.setLastError(message)
                try? self.noteCandidateAttemptFailure(candidate)
                continue
            }
        }

        throw ProxyError.message(
            errors.isEmpty
                ? self.noAvailableAccountsMessage(for: .anthropic, allowedAccountKeys: proxyKey.allowedAccountKeys)
                : errors.joined(separator: " | ")
        )
    }

    private func countAnthropicTokensViaAnthropicProvider(
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        selectedAccountKey: String?,
        request: [String: Any],
        requestedModel: String,
        rawAnthropicRequest: [String: Any]? = nil,
        anthropicVersion: String,
        anthropicBeta: String?,
        config: AppConfig? = nil
    ) async throws -> ProxyHTTPResponse {
        let resolvedConfig: AppConfig
        if let providedConfig = config {
            resolvedConfig = providedConfig
        } else {
            resolvedConfig = try await self.loadConfigForNetworkRequests()
        }
        let candidates = await self.prioritizedCandidates(
            try await self.loadCandidates(
                selectedAccountKey: selectedAccountKey,
                dataSource: .anthropic,
                allowedAccountKeys: proxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.anthropic]
            ),
            using: promptCacheContext
        )
        guard !candidates.isEmpty else {
            throw ProxyError.message(
                self.noAvailableAccountsMessage(
                    for: .anthropic,
                    allowedAccountKeys: proxyKey.allowedAccountKeys
                )
            )
        }

        var errors: [String] = []
        for var candidate in candidates {
            let startMS = Helpers.nowMilliseconds()
            do {
                candidate = try await self.refreshedCandidateAuthIfNeeded(candidate)

                let modelResolution = self.resolveProxyRequestModel(
                    requestedModel: requestedModel,
                    sourceAnthropicModel: requestedModel,
                    record: candidate.record,
                    config: resolvedConfig,
                    auth: candidate.auth
                )
                let upstreamModel = modelResolution.usesAccountModelRouting
                    ? modelResolution.resolvedRequestModel
                    : self.resolveOpenAIToAnthropicModel(
                        requestedModel: modelResolution.resolvedRequestModel
                    )
                let preparedRawAnthropicRequest: [String: Any]?
                if let rawAnthropicRequest {
                    preparedRawAnthropicRequest = await self.anthropicRequestByApplyingOCRIfNeeded(
                        rawAnthropicRequest,
                        candidate: candidate,
                        config: resolvedConfig,
                        endpoint: "/v1/messages/count_tokens",
                        requestedModel: requestedModel
                    )
                } else {
                    preparedRawAnthropicRequest = nil
                }
                var anthropicRequest = preparedRawAnthropicRequest.map {
                    self.preparedAnthropicRequestPayload(
                        rawPayload: $0,
                        upstreamModel: upstreamModel,
                        stream: false,
                        candidate: candidate
                    )
                } ?? AnthropicUpstreamBridge.normalizeRequest(
                    request,
                    upstreamModel: upstreamModel,
                    stream: false
                )
                anthropicRequest.removeValue(forKey: "stream")
                let actualModel = self.loggedActualModel(from: anthropicRequest)
                let serialized = try JSONSerialization.data(withJSONObject: anthropicRequest)
                let upstreamRequest = self.anthropicUpstreamRequest(
                    for: candidate.auth,
                    path: "/v1/messages/count_tokens",
                    stream: false,
                    anthropicVersion: anthropicVersion,
                    anthropicBeta: anthropicBeta
                )
                let upstreamHeaders = PromptCacheSupport.applyAnthropicSessionHeader(
                    to: upstreamRequest.headers,
                    context: promptCacheContext
                )
                let upstreamURL = upstreamRequest.url
                let response = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                    try await HTTPClientFactory.request(
                        config: requestConfig,
                        url: upstreamURL,
                        method: .POST,
                        headers: upstreamHeaders,
                        body: serialized
                    )
                }
                if (200..<300).contains(response.statusCode) == false {
                    let text = response.bodyText
                    let category = self.classifyFailure(status: response.statusCode, text: text)
                    errors.append(self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text))
                    let latency = Helpers.nowMilliseconds() - startMS
                    try self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: "/v1/messages/count_tokens",
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: false,
                            latencyMS: latency,
                            failureCategory: category,
                            lastError: Helpers.truncate(text),
                            apiKeyValue: apiKeyValue
                        )
                    )
                    await self.setLastError("\(candidate.record.label): \(Helpers.truncate(text))")
                    let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                        category: category,
                        candidate: candidate,
                        recordUsage: candidate.record.usage,
                        usageError: candidate.record.usageError,
                        text: text
                    )
                    try self.noteCandidateAttemptFailure(candidate)
                    if shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                        continue
                    }
                    break
                }

                await self.setActive(candidate)
                let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
                let inputTokens = self.int64Value(payload["input_tokens"]) ?? 0
                let latency = Helpers.nowMilliseconds() - startMS
                try self.recordTrace(
                    ProxyRequestTrace(
                        endpoint: "/v1/messages/count_tokens",
                        upstreamURL: upstreamURL,
                        apiKeyHash: proxyKey.apiKeyHash,
                        accountKey: candidate.record.accountKey,
                        accountLabel: candidate.record.label,
                        clientSource: clientSource,
                        model: requestedModel,
                        actualModel: actualModel,
                        success: true,
                        latencyMS: latency,
                        usage: UpstreamUsage(inputTokens: inputTokens, outputTokens: 0, totalTokens: inputTokens, cacheHitTokens: nil),
                        apiKeyValue: apiKeyValue
                    )
                )
                try self.noteCandidateAttemptSuccess(candidate)
                await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                return ProxyHTTPResponse(
                    statusCode: 200,
                    headers: self.anthropicResponseHeaders(
                        version: anthropicVersion,
                        beta: anthropicBeta,
                        contentType: "application/json; charset=utf-8"
                    ),
                    body: .bytes(response.body)
                )
            } catch let error as RecordedCandidateFailure {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.rawText)
                errors.append(message)
                await self.setLastError(message)
                if error.shouldContinue {
                    continue
                }
                if let response = error.response {
                    return response
                }
                break
            } catch {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.localizedDescription)
                errors.append(message)
                await self.setLastError(message)
                try? self.noteCandidateAttemptFailure(candidate)
                continue
            }
        }

        throw ProxyError.message(
            errors.isEmpty
                ? self.noAvailableAccountsMessage(for: .anthropic, allowedAccountKeys: proxyKey.allowedAccountKeys)
                : errors.joined(separator: " | ")
        )
    }

    private func forwardToCodexViaOpenAIAPIKeyCandidate(
        endpoint: String,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        candidate: ProxyCandidate,
        requestedModel: String,
        reasoningEffort: String? = nil,
        downstreamStream: Bool,
        codexRequest: [String: Any],
        responseMode: ResponseMode,
        sourceAnthropicModel: String?,
        geminiRequestContext: GeminiRequestContext?,
        explicitProxyTestCustomModel: Bool,
        config: AppConfig,
        startMS: Int64
    ) async throws -> ProxyHTTPResponse {
        let (resolvedRequest, modelResolution) = self.resolvedCodexRequest(
            codexRequest,
            requestedModel: requestedModel,
            sourceAnthropicModel: sourceAnthropicModel,
            record: candidate.record,
            config: config,
            auth: candidate.auth
        )
        let compatibleRequest = PromptCacheSupport.applyCodexPromptCache(
            to: resolvedRequest,
            context: promptCacheContext,
            auth: candidate.auth
        )
        let upstreamCompatibleRequest = await self.requestByApplyingOCRIfNeeded(
            compatibleRequest,
            candidate: candidate,
            config: config,
            endpoint: endpoint,
            requestedModel: requestedModel
        )
        let adapters = self.openAIUpstreamAdapters(for: candidate.auth)

        for adapter in adapters {
            var upstreamDiagnosticMetadata: [String: String] = [:]
            var upstreamRequestBody: [String: Any]
            if adapter == .chatCompletions {
                let builtRequest = self.openAIUpstreamRequestBodyWithDiagnostics(
                    from: upstreamCompatibleRequest,
                    requestedModel: requestedModel,
                    auth: candidate.auth,
                    adapter: adapter,
                    stream: downstreamStream,
                    preserveCustomModel: explicitProxyTestCustomModel,
                    useResolvedModelAsFinalUpstreamModel: modelResolution.usesAccountModelRouting
                )
                upstreamRequestBody = builtRequest.body
                upstreamDiagnosticMetadata = builtRequest.metadata
            } else {
                upstreamRequestBody = self.openAIUpstreamRequestBody(
                    from: upstreamCompatibleRequest,
                    requestedModel: requestedModel,
                    auth: candidate.auth,
                    adapter: adapter,
                    stream: downstreamStream,
                    preserveCustomModel: explicitProxyTestCustomModel,
                    useResolvedModelAsFinalUpstreamModel: modelResolution.usesAccountModelRouting
                )
            }
            if adapter == .chatCompletions {
                upstreamRequestBody = self.applyAccountReasoningEffortMapping(
                    to: upstreamRequestBody,
                    candidate: candidate,
                    rawReasoningEffort: reasoningEffort
                )
                let preparedRequest = self.preparedChatCompletionsRequestForReasoningHistory(
                    upstreamRequestBody,
                    candidate: candidate,
                    promptCacheContext: promptCacheContext
                )
                upstreamRequestBody = preparedRequest.body
                upstreamDiagnosticMetadata.merge(preparedRequest.metadata) { _, new in new }
            }
            let actualModel = self.loggedActualModel(from: upstreamRequestBody)
            let serialized = try JSONSerialization.data(withJSONObject: upstreamRequestBody)

            if downstreamStream {
                let (response, upstreamURL, diagnosticRequestBodyID) = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                    var upstream = self.openAIUpstreamRequest(
                        for: candidate.auth,
                        config: requestConfig,
                        accept: "text/event-stream",
                        adapter: adapter
                    )
                    if candidate.auth.authMode == .chatGPT,
                       let sessionID = promptCacheContext.upstreamSessionID
                    {
                        upstream.headers["session_id"] = sessionID
                    }
                    let diagnosticRequestBodyID = self.captureDiagnosticRequestBodyIfNeeded(
                        config: config,
                        endpoint: endpoint,
                        upstreamURL: upstream.url,
                        candidate: candidate,
                        requestedModel: requestedModel,
                        actualModel: actualModel,
                        body: serialized,
                        bodyObject: upstreamRequestBody,
                        metadata: upstreamDiagnosticMetadata
                    )
                    return (
                        adapter == .chatCompletions
                            ? try await self.chatCompletionsAPIKeyStream(
                                config: requestConfig,
                                url: upstream.url,
                                headers: upstream.headers,
                                body: serialized
                            )
                            : try await HTTPClientFactory.stream(
                                config: requestConfig,
                                url: upstream.url,
                                method: .POST,
                                headers: upstream.headers,
                                body: serialized
                            ),
                        upstream.url,
                        diagnosticRequestBodyID
                    )
                }
                if (200..<300).contains(response.statusCode) == false {
                    let body = try await self.collectBody(from: response.body)
                    let text = String(decoding: body, as: UTF8.self)
                    let category = self.classifyFailure(status: response.statusCode, text: text)
                    let publicMessage = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text)
                    let latency = Helpers.nowMilliseconds() - startMS
                    try self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            reasoningEffort: reasoningEffort,
                            success: false,
                            latencyMS: latency,
                            failureCategory: category,
                            lastError: Helpers.truncate(text),
                            apiKeyValue: apiKeyValue
                        ),
                        diagnosticRequestBodyID: diagnosticRequestBodyID
                    )
                    await self.setLastError(publicMessage)
                    let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                        category: category,
                        candidate: candidate,
                        recordUsage: candidate.record.usage,
                        usageError: candidate.record.usageError,
                        text: text
                    )
                    try self.noteCandidateAttemptFailure(candidate)
                    throw RecordedCandidateFailure(
                        rawText: text,
                        shouldContinue: shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate)
                    )
                }

                await self.setActive(candidate)
                let streamInputData = self.syntheticResponseInputData(from: upstreamCompatibleRequest["input"])
                let adaptedBody = adapter == .chatCompletions
                    ? self.openAIChatToSyntheticResponseStream(
                        upstreamBody: response.body,
                        requestedModel: requestedModel,
                        inputData: streamInputData,
                        reasoningCacheAccountKey: candidate.record.accountKey,
                        reasoningCacheSessionKey: self.chatCompletionsReasoningSessionKey(from: promptCacheContext)
                    )
                    : response.body
                await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                return self.makeStreamingProxyResponse(
                    upstreamBody: adaptedBody,
                    endpoint: endpoint,
                    upstreamURL: upstreamURL,
                    apiKeyHash: proxyKey.apiKeyHash,
                    apiKeyValue: apiKeyValue,
                    clientSource: clientSource,
                    requestedModel: requestedModel,
                    actualModel: actualModel,
                    responseMode: responseMode,
                    geminiRequestContext: geminiRequestContext,
                    candidate: candidate,
                    startMS: startMS,
                    reasoningEffort: reasoningEffort,
                    diagnosticRequestBodyID: diagnosticRequestBodyID
                )
            }

            let (response, upstreamURL, diagnosticRequestBodyID) = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                var upstream = self.openAIUpstreamRequest(
                    for: candidate.auth,
                    config: requestConfig,
                    accept: "application/json",
                    adapter: adapter
                )
                if candidate.auth.authMode == .chatGPT,
                   let sessionID = promptCacheContext.upstreamSessionID
                {
                    upstream.headers["session_id"] = sessionID
                }
                let diagnosticRequestBodyID = self.captureDiagnosticRequestBodyIfNeeded(
                    config: config,
                    endpoint: endpoint,
                    upstreamURL: upstream.url,
                    candidate: candidate,
                    requestedModel: requestedModel,
                    actualModel: actualModel,
                    body: serialized,
                    bodyObject: upstreamRequestBody,
                    metadata: upstreamDiagnosticMetadata
                )
                return (
                    adapter == .chatCompletions
                        ? try await self.chatCompletionsAPIKeyRequest(
                            config: requestConfig,
                            url: upstream.url,
                            headers: upstream.headers,
                            body: serialized
                        )
                        : try await HTTPClientFactory.request(
                            config: requestConfig,
                            url: upstream.url,
                            method: .POST,
                            headers: upstream.headers,
                            body: serialized
                        ),
                    upstream.url,
                    diagnosticRequestBodyID
                )
            }

            if (200..<300).contains(response.statusCode) == false {
                let text = response.bodyText
                let category = self.classifyFailure(status: response.statusCode, text: text)
                let publicMessage = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text)
                let latency = Helpers.nowMilliseconds() - startMS
                try self.recordTrace(
                    ProxyRequestTrace(
                        endpoint: endpoint,
                        upstreamURL: upstreamURL,
                        apiKeyHash: proxyKey.apiKeyHash,
                        accountKey: candidate.record.accountKey,
                        accountLabel: candidate.record.label,
                        clientSource: clientSource,
                        model: requestedModel,
                        actualModel: actualModel,
                        reasoningEffort: reasoningEffort,
                        success: false,
                        latencyMS: latency,
                        failureCategory: category,
                        lastError: Helpers.truncate(text),
                        apiKeyValue: apiKeyValue
                    ),
                    diagnosticRequestBodyID: diagnosticRequestBodyID
                )
                await self.setLastError(publicMessage)
                let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                    category: category,
                    candidate: candidate,
                    recordUsage: candidate.record.usage,
                    usageError: candidate.record.usageError,
                    text: text
                )
                try self.noteCandidateAttemptFailure(candidate)
                throw RecordedCandidateFailure(
                    rawText: text,
                    shouldContinue: shouldContinueAfterRecovery || self.shouldContinueAfterFailure(category: category, candidate: candidate)
                )
            }

            await self.setActive(candidate)
            let completed: [String: Any]
            let usageRecognized: Bool
            if adapter == .chatCompletions {
                let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
                usageRecognized = ProxyTranscoder.hasRecognizableUsage(inUsageObject: object["usage"])
                completed = ProxyTranscoder.completedResponse(
                    fromChatCompletion: object,
                    requestedModel: requestedModel,
                    input: upstreamCompatibleRequest["input"]
                )
                self.chatCompletionsReasoningCache.record(
                    completedResponse: completed,
                    accountKey: candidate.record.accountKey,
                    sessionKey: self.chatCompletionsReasoningSessionKey(from: promptCacheContext)
                )
            } else {
                let events = ProxyTranscoder.decodeSSE(response.body)
                guard let rawCompleted = self.completedResponse(from: response.body) else {
                    throw ProxyError.message("上游未返回 response.completed")
                }
                usageRecognized = ProxyTranscoder.hasRecognizableUsage(in: rawCompleted)
                completed = ProxyTranscoder.completedResponseByEnsuringAssistantText(
                    rawCompleted,
                    fallbackText: ProxyTranscoder.extractAssistantText(from: events)
                )
            }
            let usage = ProxyTranscoder.usageFromCompletedResponse(completed)
            let payload: Data
            switch responseMode {
            case .chatCompletions:
                payload = try JSONSerialization.data(withJSONObject: ProxyTranscoder.chatCompletionFromCompletedResponse(completedResponse: completed, requestedModel: requestedModel))
            case .responses:
                payload = try JSONSerialization.data(withJSONObject: completed)
            case .anthropicMessages:
                payload = try JSONSerialization.data(withJSONObject: AnthropicTranscoder.messageResponse(from: completed, requestedModel: requestedModel))
            case .geminiGenerateContent:
                payload = try JSONSerialization.data(
                    withJSONObject: GeminiTranscoder.generateContentResponse(
                        from: completed,
                        requestedModel: requestedModel,
                        context: geminiRequestContext ?? .default(sourceModel: requestedModel)
                    )
                )
            }
            let latency = Helpers.nowMilliseconds() - startMS
            let successDiagnostic = usageRecognized
                ? nil
                : self.openAICompatibleMissingUsageDiagnostic(adapter: adapter)
            try self.recordTrace(
                ProxyRequestTrace(
                    endpoint: endpoint,
                    upstreamURL: upstreamURL,
                    apiKeyHash: proxyKey.apiKeyHash,
                    accountKey: candidate.record.accountKey,
                    accountLabel: candidate.record.label,
                    clientSource: clientSource,
                    model: requestedModel,
                    actualModel: actualModel,
                    reasoningEffort: reasoningEffort,
                    success: true,
                    latencyMS: latency,
                    usage: usage,
                    lastError: successDiagnostic.map { Helpers.truncate($0) },
                    apiKeyValue: apiKeyValue
                ),
                diagnosticRequestBodyID: diagnosticRequestBodyID
            )
            try self.noteCandidateAttemptSuccess(candidate)
            await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
            return ProxyHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: .bytes(payload)
            )
        }

        throw ProxyError.message("没有可用账号完成请求")
    }

    private func forwardToCodex(
        endpoint: String,
        proxyKey: AuthenticatedProxyKeyContext,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        promptCacheContext: PromptCacheContext,
        selectedAccountKey: String? = nil,
        requestedModel: String,
        reasoningEffort: String? = nil,
        downstreamStream: Bool,
        codexRequest: [String: Any],
        responseMode: ResponseMode,
        sourceAnthropicModel: String? = nil,
        geminiRequestContext: GeminiRequestContext? = nil,
        explicitProxyTestCustomModel: Bool = false
    ) async throws -> ProxyHTTPResponse {
        let config = try await self.loadConfigForNetworkRequests()
        let candidates = await self.prioritizedCandidates(
            try await self.loadCandidates(
                selectedAccountKey: selectedAccountKey,
                dataSource: proxyKey.dataSource,
                allowedAccountKeys: proxyKey.allowedAccountKeys,
                allowedProviderFamilies: [.openAI, .anthropic]
            ),
            using: promptCacheContext
        )
        guard !candidates.isEmpty else {
            throw ProxyError.message(
                self.noAvailableAccountsMessage(
                    for: proxyKey.dataSource,
                    allowedAccountKeys: proxyKey.allowedAccountKeys
                )
            )
        }

        var errors: [String] = []
        for var candidate in candidates {
            let startMS = Helpers.nowMilliseconds()
            do {
                candidate = try await self.refreshedCandidateAuthIfNeeded(candidate)

                if candidate.record.providerFamily == .anthropic {
                    return try await self.forwardToAnthropicProvider(
                        endpoint: endpoint,
                        proxyKey: proxyKey,
                        apiKeyValue: apiKeyValue,
                        clientSource: clientSource,
                        promptCacheContext: promptCacheContext,
                        selectedAccountKey: candidate.record.accountKey,
                        requestedModel: requestedModel,
                        reasoningEffort: reasoningEffort,
                        downstreamStream: downstreamStream,
                        normalizedRequest: codexRequest,
                        responseMode: responseMode,
                        sourceAnthropicModel: sourceAnthropicModel,
                        geminiRequestContext: geminiRequestContext,
                        config: config
                    )
                }

                if candidate.auth.authMode == .openAIAPIKey {
                    return try await self.forwardToCodexViaOpenAIAPIKeyCandidate(
                        endpoint: endpoint,
                        proxyKey: proxyKey,
                        apiKeyValue: apiKeyValue,
                        clientSource: clientSource,
                        promptCacheContext: promptCacheContext,
                        candidate: candidate,
                        requestedModel: requestedModel,
                        reasoningEffort: reasoningEffort,
                        downstreamStream: downstreamStream,
                        codexRequest: codexRequest,
                        responseMode: responseMode,
                        sourceAnthropicModel: sourceAnthropicModel,
                        geminiRequestContext: geminiRequestContext,
                        explicitProxyTestCustomModel: explicitProxyTestCustomModel,
                        config: config,
                        startMS: startMS
                    )
                }

                let (resolvedRequest, modelResolution) = self.resolvedCodexRequest(
                    codexRequest,
                    requestedModel: requestedModel,
                    sourceAnthropicModel: sourceAnthropicModel,
                    record: candidate.record,
                    config: config,
                    auth: candidate.auth
                )
                let compatibleRequest = PromptCacheSupport.applyCodexPromptCache(
                    to: resolvedRequest,
                    context: promptCacheContext,
                    auth: candidate.auth
                )
                let upstreamCompatibleRequest = await self.requestByApplyingOCRIfNeeded(
                    compatibleRequest,
                    candidate: candidate,
                    config: config,
                    endpoint: endpoint,
                    requestedModel: requestedModel
                )
                let adapterUsesChatCompletions = self.usesOpenAIChatCompletionsAdapter(candidate.auth)
                let effectiveRequestedModel = (upstreamCompatibleRequest["model"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedUpstreamModel = modelResolution.usesAccountModelRouting
                    ? (effectiveRequestedModel?.isEmpty == false ? effectiveRequestedModel! : requestedModel)
                    : candidate.auth.providerPreset.resolvedUpstreamModel(
                    for: effectiveRequestedModel?.isEmpty == false ? effectiveRequestedModel! : requestedModel
                )
                var upstreamDiagnosticMetadata: [String: String] = [:]
                var upstreamRequestBody: [String: Any]
                if adapterUsesChatCompletions {
                    let builtRequest = self.upstreamChatCompletionsRequestWithDiagnostics(
                        from: upstreamCompatibleRequest,
                        upstreamModel: resolvedUpstreamModel,
                        stream: downstreamStream,
                        auth: candidate.auth
                    )
                    upstreamRequestBody = builtRequest.body
                    upstreamDiagnosticMetadata = builtRequest.metadata
                } else {
                    upstreamRequestBody = self.compatibleCodexRequest(
                        upstreamCompatibleRequest,
                        for: candidate.auth,
                        preserveResolvedModel: modelResolution.usesAccountModelRouting
                    )
                }
                if adapterUsesChatCompletions {
                    upstreamRequestBody = self.applyAccountReasoningEffortMapping(
                        to: upstreamRequestBody,
                        candidate: candidate,
                        rawReasoningEffort: reasoningEffort
                    )
                    let preparedRequest = self.preparedChatCompletionsRequestForReasoningHistory(
                        upstreamRequestBody,
                        candidate: candidate,
                        promptCacheContext: promptCacheContext
                    )
                    upstreamRequestBody = preparedRequest.body
                    upstreamDiagnosticMetadata.merge(preparedRequest.metadata) { _, new in new }
                }
                let actualModel = self.loggedActualModel(from: upstreamRequestBody)
                let serialized = try JSONSerialization.data(withJSONObject: upstreamRequestBody)

                if downstreamStream {
                    let candidateAuth = candidate.auth
                    let upstreamSessionID = promptCacheContext.upstreamSessionID
                    let (response, upstreamURL, diagnosticRequestBodyID) = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                        var upstream = self.upstreamRequest(for: candidateAuth, config: requestConfig)
                        if candidateAuth.authMode == .chatGPT,
                           let sessionID = upstreamSessionID
                        {
                            upstream.headers["session_id"] = sessionID
                        }
                        let diagnosticRequestBodyID = self.captureDiagnosticRequestBodyIfNeeded(
                            config: config,
                            endpoint: endpoint,
                            upstreamURL: upstream.url,
                            candidate: candidate,
                            requestedModel: requestedModel,
                            actualModel: actualModel,
                            body: serialized,
                            bodyObject: upstreamRequestBody,
                            metadata: upstreamDiagnosticMetadata
                        )
                        return (
                            adapterUsesChatCompletions
                                ? try await self.chatCompletionsAPIKeyStream(
                                    config: requestConfig,
                                    url: upstream.url,
                                    headers: upstream.headers,
                                    body: serialized
                                )
                                : try await HTTPClientFactory.stream(
                                    config: requestConfig,
                                    url: upstream.url,
                                    method: .POST,
                                    headers: upstream.headers,
                                    body: serialized
                                ),
                            upstream.url,
                            diagnosticRequestBodyID
                        )
                    }
                    if (200..<300).contains(response.statusCode) == false {
                        let body = try await self.collectBody(from: response.body)
                        let text = String(decoding: body, as: UTF8.self)
                        let category = self.classifyFailure(status: response.statusCode, text: text)
                        errors.append(self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text))
                        let latency = Helpers.nowMilliseconds() - startMS
                        try self.recordTrace(
                            ProxyRequestTrace(
                                endpoint: endpoint,
                                upstreamURL: upstreamURL,
                                apiKeyHash: proxyKey.apiKeyHash,
                                accountKey: candidate.record.accountKey,
                                accountLabel: candidate.record.label,
                                clientSource: clientSource,
                                model: requestedModel,
                                actualModel: actualModel,
                                reasoningEffort: reasoningEffort,
                                success: false,
                                latencyMS: latency,
                                failureCategory: category,
                                lastError: Helpers.truncate(text),
                                apiKeyValue: apiKeyValue
                            ),
                            diagnosticRequestBodyID: diagnosticRequestBodyID
                        )
                        await self.setLastError("\(candidate.record.label): \(Helpers.truncate(text))")
                        let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                            category: category,
                            candidate: candidate,
                            recordUsage: candidate.record.usage,
                            usageError: candidate.record.usageError,
                            text: text
                        )
                        try self.noteCandidateAttemptFailure(candidate)
                        if shouldContinueAfterRecovery {
                            continue
                        }
                        if self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                            continue
                        }
                        break
                    }

                    await self.setActive(candidate)
                    let streamInputData = self.syntheticResponseInputData(from: upstreamCompatibleRequest["input"])
                    let adaptedBody = adapterUsesChatCompletions
                        ? self.openAIChatToSyntheticResponseStream(
                            upstreamBody: response.body,
                            requestedModel: requestedModel,
                            inputData: streamInputData,
                            reasoningCacheAccountKey: candidate.record.accountKey,
                            reasoningCacheSessionKey: self.chatCompletionsReasoningSessionKey(from: promptCacheContext)
                        )
                        : response.body
                    await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                    return self.makeStreamingProxyResponse(
                        upstreamBody: adaptedBody,
                        endpoint: endpoint,
                        upstreamURL: upstreamURL,
                        apiKeyHash: proxyKey.apiKeyHash,
                        apiKeyValue: apiKeyValue,
                        clientSource: clientSource,
                        requestedModel: requestedModel,
                        actualModel: actualModel,
                        responseMode: responseMode,
                        geminiRequestContext: geminiRequestContext,
                        candidate: candidate,
                        startMS: startMS,
                        reasoningEffort: reasoningEffort,
                        diagnosticRequestBodyID: diagnosticRequestBodyID
                    )
                }

                let candidateAuth = candidate.auth
                let upstreamSessionID = promptCacheContext.upstreamSessionID
                let (response, upstreamURL, diagnosticRequestBodyID) = try await self.withNetworkConfig(for: candidate.record) { requestConfig in
                    var upstream = self.upstreamRequest(for: candidateAuth, config: requestConfig)
                    if candidateAuth.authMode == .chatGPT,
                       let sessionID = upstreamSessionID
                    {
                        upstream.headers["session_id"] = sessionID
                    }
                    let diagnosticRequestBodyID = self.captureDiagnosticRequestBodyIfNeeded(
                        config: config,
                        endpoint: endpoint,
                        upstreamURL: upstream.url,
                        candidate: candidate,
                        requestedModel: requestedModel,
                        actualModel: actualModel,
                        body: serialized,
                        bodyObject: upstreamRequestBody,
                        metadata: upstreamDiagnosticMetadata
                    )
                    return (
                        adapterUsesChatCompletions
                            ? try await self.chatCompletionsAPIKeyRequest(
                                config: requestConfig,
                                url: upstream.url,
                                headers: upstream.headers,
                                body: serialized
                            )
                            : try await HTTPClientFactory.request(
                                config: requestConfig,
                                url: upstream.url,
                                method: .POST,
                                headers: upstream.headers,
                                body: serialized
                            ),
                        upstream.url,
                        diagnosticRequestBodyID
                    )
                }

                if (200..<300).contains(response.statusCode) == false {
                    let text = response.bodyText
                    let category = self.classifyFailure(status: response.statusCode, text: text)
                    errors.append(self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: text))
                    let latency = Helpers.nowMilliseconds() - startMS
                    try self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: proxyKey.apiKeyHash,
                            accountKey: candidate.record.accountKey,
                            accountLabel: candidate.record.label,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            reasoningEffort: reasoningEffort,
                            success: false,
                            latencyMS: latency,
                            failureCategory: category,
                            lastError: Helpers.truncate(text),
                            apiKeyValue: apiKeyValue
                        ),
                        diagnosticRequestBodyID: diagnosticRequestBodyID
                    )
                    await self.setLastError("\(candidate.record.label): \(Helpers.truncate(text))")
                    let shouldContinueAfterRecovery = try await self.handleRecoverableFailure(
                        category: category,
                        candidate: candidate,
                        recordUsage: candidate.record.usage,
                        usageError: candidate.record.usageError,
                        text: text
                    )
                    try self.noteCandidateAttemptFailure(candidate)
                    if shouldContinueAfterRecovery {
                        continue
                    }
                    if self.shouldContinueAfterFailure(category: category, candidate: candidate) {
                        continue
                    }
                    break
                }

                await self.setActive(candidate)
                let completed: [String: Any]
                if adapterUsesChatCompletions {
                    let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
                    completed = ProxyTranscoder.completedResponse(
                        fromChatCompletion: object,
                        requestedModel: requestedModel,
                        input: upstreamCompatibleRequest["input"]
                    )
                    self.chatCompletionsReasoningCache.record(
                        completedResponse: completed,
                        accountKey: candidate.record.accountKey,
                        sessionKey: self.chatCompletionsReasoningSessionKey(from: promptCacheContext)
                    )
                } else {
                    let events = ProxyTranscoder.decodeSSE(response.body)
                    guard let rawCompleted = self.completedResponse(from: response.body) else {
                        throw ProxyError.message("上游未返回 response.completed")
                    }
                    completed = ProxyTranscoder.completedResponseByEnsuringAssistantText(
                        rawCompleted,
                        fallbackText: ProxyTranscoder.extractAssistantText(from: events)
                    )
                }
                let usage = ProxyTranscoder.usageFromCompletedResponse(completed)
                let payload: Data
                switch responseMode {
                case .chatCompletions:
                    payload = try JSONSerialization.data(withJSONObject: ProxyTranscoder.chatCompletionFromCompletedResponse(completedResponse: completed, requestedModel: requestedModel))
                case .responses:
                    payload = try JSONSerialization.data(withJSONObject: completed)
                case .anthropicMessages:
                    payload = try JSONSerialization.data(withJSONObject: AnthropicTranscoder.messageResponse(from: completed, requestedModel: requestedModel))
                case .geminiGenerateContent:
                    payload = try JSONSerialization.data(
                        withJSONObject: GeminiTranscoder.generateContentResponse(
                            from: completed,
                            requestedModel: requestedModel,
                            context: geminiRequestContext ?? .default(sourceModel: requestedModel)
                        )
                    )
                }
                let latency = Helpers.nowMilliseconds() - startMS
                try self.recordTrace(
                    ProxyRequestTrace(
                        endpoint: endpoint,
                        upstreamURL: upstreamURL,
                        apiKeyHash: proxyKey.apiKeyHash,
                        accountKey: candidate.record.accountKey,
                        accountLabel: candidate.record.label,
                        clientSource: clientSource,
                        model: requestedModel,
                        actualModel: actualModel,
                        reasoningEffort: reasoningEffort,
                        success: true,
                        latencyMS: latency,
                        usage: usage,
                        apiKeyValue: apiKeyValue
                    ),
                    diagnosticRequestBodyID: diagnosticRequestBodyID
                )
                try self.noteCandidateAttemptSuccess(candidate)
                await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                return ProxyHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: .bytes(payload)
                )
            } catch let error as RecordedCandidateFailure {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.rawText)
                errors.append(message)
                await self.setLastError(message)
                if error.shouldContinue {
                    continue
                }
                if let response = error.response {
                    return response
                }
                break
            } catch {
                let message = self.publicFacingCandidateFailureMessage(candidate: candidate, rawText: error.localizedDescription)
                errors.append(message)
                await self.setLastError(message)
                try? self.noteCandidateAttemptFailure(candidate)
                continue
            }
        }
        throw ProxyError.message(errors.isEmpty ? "没有可用账号完成请求" : errors.joined(separator: " | "))
    }

    private func loadCandidates(
        selectedAccountKey: String? = nil,
        dataSource: ProxyDataSource,
        allowedAccountKeys: [String] = [],
        allowedProviderFamilies: Set<AccountProviderFamily>? = nil,
        ignoreUsageLimitBlocks: Bool = false
    ) async throws -> [ProxyCandidate] {
        let now = Helpers.now()
        let records = try self.store.listAccountRecords()
        let trimmedSelectedAccountKey = selectedAccountKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let allowedAccountKeySet = Set(ProxyAPIKeyRecord.normalizedAllowedAccountKeys(allowedAccountKeys))
        if !trimmedSelectedAccountKey.isEmpty {
            guard allowedAccountKeySet.isEmpty || allowedAccountKeySet.contains(trimmedSelectedAccountKey) else {
                throw ProxyError.message(self.disallowedSelectedAccountMessage())
            }
            return [
                try self.selectedCandidate(
                    accountKey: trimmedSelectedAccountKey,
                    records: records,
                    now: now,
                    dataSource: dataSource,
                    allowedProviderFamilies: allowedProviderFamilies,
                    ignoreUsageLimitBlocks: ignoreUsageLimitBlocks
                ),
            ]
        }
        var configurationErrors: [String] = []
        let candidates = try records.compactMap { rawRecord -> ProxyCandidate? in
            var record = rawRecord
            guard record.enabled else { return nil }
            guard dataSource.allows(providerFamily: record.providerFamily) else { return nil }
            if let allowedProviderFamilies, !allowedProviderFamilies.contains(record.providerFamily) {
                return nil
            }
            guard allowedAccountKeySet.isEmpty || allowedAccountKeySet.contains(record.accountKey) else { return nil }
            if record.authMode.isManualAPIKey {
                record = try self.accountService.repairedStoredManualAccountIfNeeded(record)
                if let configurationError = self.manualAPIKeyConfigurationError(for: record) {
                    configurationErrors.append("\(record.label): \(configurationError)")
                    return nil
                }
            }
            guard ignoreUsageLimitBlocks || UsageLimitWindowSupport.isBlocked(record.usage, now: now) == false else { return nil }
            if record.authMode.isManualAPIKey {
                if let cooldownUntil = record.cooldownUntil, cooldownUntil <= now {
                    try self.store.updateAccountFailureState(id: record.id, consecutiveFailureCount: 0, cooldownUntil: nil)
                    record.consecutiveFailureCount = 0
                    record.cooldownUntil = nil
                }
                guard record.isCoolingDown(now: now) == false else { return nil }
            }
            guard let auth = try? AuthService.extractAuth(from: record.authJSON, secretStore: self.secretStore) else {
                if let configurationError = self.manualAPIKeyConfigurationError(for: record) {
                    configurationErrors.append("\(record.label): \(configurationError)")
                }
                return nil
            }
            return ProxyCandidate(record: record, auth: auth)
        }
        if candidates.isEmpty, configurationErrors.isEmpty == false {
            throw ProxyError.message(configurationErrors.joined(separator: " | "))
        }
        return candidates
    }

    private func selectedCandidate(
        accountKey: String,
        records: [AccountRecord],
        now: Int64,
        dataSource: ProxyDataSource,
        allowedProviderFamilies: Set<AccountProviderFamily>? = nil,
        ignoreUsageLimitBlocks: Bool = false
    ) throws -> ProxyCandidate {
        guard var record = records.first(where: { $0.accountKey == accountKey }) else {
            throw ProxyError.message("指定的测试账号不存在。")
        }
        guard record.authMode.supportsPinnedProxyTest(dataSource: dataSource) else {
            throw ProxyError.message("指定的测试账号与当前 API Key 的数据源不匹配。")
        }
        if let allowedProviderFamilies, !allowedProviderFamilies.contains(record.providerFamily) {
            throw ProxyError.message("指定的测试账号与当前请求协议不兼容。")
        }
        guard record.enabled else {
            throw ProxyError.message("指定的测试账号已禁用。")
        }
        guard ignoreUsageLimitBlocks || UsageLimitWindowSupport.isBlocked(record.usage, now: now) == false else {
            throw ProxyError.message("指定的测试账号当前额度窗口受限，暂不可用于测试。")
        }

        if record.authMode.isManualAPIKey {
            record = try self.accountService.repairedStoredManualAccountIfNeeded(record)
            if let configurationError = self.manualAPIKeyConfigurationError(for: record) {
                throw ProxyError.message("指定的测试账号配置有误：\(configurationError)")
            }
            if let cooldownUntil = record.cooldownUntil, cooldownUntil <= now {
                try self.store.updateAccountFailureState(id: record.id, consecutiveFailureCount: 0, cooldownUntil: nil)
                record.consecutiveFailureCount = 0
                record.cooldownUntil = nil
            }
            guard record.isCoolingDown(now: now) == false else {
                throw ProxyError.message("指定的测试账号当前处于 API Key 冷却期，暂不可用于测试。")
            }
        }

        guard let auth = try? AuthService.extractAuth(from: record.authJSON, secretStore: self.secretStore) else {
            if let configurationError = self.manualAPIKeyConfigurationError(for: record) {
                throw ProxyError.message("指定的测试账号配置有误：\(configurationError)")
            }
            throw ProxyError.message("指定的测试账号授权无效，请重新导入或更新。")
        }
        return ProxyCandidate(record: record, auth: auth)
    }

    private func prioritizedCandidates(
        _ candidates: [ProxyCandidate],
        using context: PromptCacheContext
    ) async -> [ProxyCandidate] {
        guard let stickySessionKey = context.stickySessionKey,
              stickySessionKey.isEmpty == false,
              let accountKey = await self.stickySessionBindings.accountKey(for: stickySessionKey),
              let index = candidates.firstIndex(where: { $0.record.accountKey == accountKey }),
              context.allowManualAPIKeyStickyBinding || candidates[index].record.authMode.isManualAPIKey == false,
              index > 0
        else {
            return candidates
        }

        var prioritized = candidates
        let bound = prioritized.remove(at: index)
        prioritized.insert(bound, at: 0)
        return prioritized
    }

    private func bindStickySessionIfNeeded(
        candidate: ProxyCandidate,
        context: PromptCacheContext
    ) async {
        guard let stickySessionKey = context.stickySessionKey,
              stickySessionKey.isEmpty == false,
              context.allowManualAPIKeyStickyBinding || candidate.record.authMode.isManualAPIKey == false
        else {
            return
        }

        await self.stickySessionBindings.bind(
            sessionKey: stickySessionKey,
            accountKey: candidate.record.accountKey,
            ttlSeconds: PromptCacheSupport.stickySessionTTLSeconds
        )
    }

    private func chatCompletionsReasoningSessionKey(from context: PromptCacheContext) -> String? {
        context.geminiCLIStickySessionKey
            ?? context.sourcePromptCacheKey
            ?? context.sessionIdentifier
            ?? context.upstreamPromptCacheKey
    }

    private struct PreparedChatCompletionsRequest {
        var body: [String: Any]
        var metadata: [String: String]
    }

    private func prepareChatCompletionsRequestForReasoningHistory(
        _ request: [String: Any],
        candidate: ProxyCandidate,
        promptCacheContext: PromptCacheContext,
        forceToolHistoryProtection: Bool = false
    ) -> [String: Any] {
        self.preparedChatCompletionsRequestForReasoningHistory(
            request,
            candidate: candidate,
            promptCacheContext: promptCacheContext,
            forceToolHistoryProtection: forceToolHistoryProtection
        ).body
    }

    private func preparedChatCompletionsRequestForReasoningHistory(
        _ request: [String: Any],
        candidate: ProxyCandidate,
        promptCacheContext: PromptCacheContext,
        forceToolHistoryProtection: Bool = false
    ) -> PreparedChatCompletionsRequest {
        let baseURL = candidate.auth.upstreamBaseURL
            ?? candidate.record.upstreamBaseURL
            ?? candidate.auth.providerPreset.defaultBaseURL
        let preparedResult = ChatCompletionsCompatibility.prepareRequestWithReport(
            request,
            configuredProfile: candidate.auth.chatCompatibilityProfile,
            baseURL: baseURL,
            providerPreset: candidate.auth.providerPreset,
            reasoningCache: self.chatCompletionsReasoningCache,
            accountKey: candidate.record.accountKey,
            sessionKey: self.chatCompletionsReasoningSessionKey(from: promptCacheContext),
            now: Helpers.now()
        )
        var prepared = preparedResult.request
        var metadata = preparedResult.report.metadata
        let effectiveProfile = ChatCompletionsCompatibility.resolvedProfile(
            configured: candidate.auth.chatCompatibilityProfile,
            baseURL: baseURL,
            providerPreset: candidate.auth.providerPreset,
            model: (prepared["model"] as? String) ?? (request["model"] as? String)
        )
        guard effectiveProfile == .generic,
              forceToolHistoryProtection || self.requiresChatCompletionsThinkingToolHistoryProtection(
                prepared,
                auth: candidate.auth
              )
        else {
            return PreparedChatCompletionsRequest(body: prepared, metadata: metadata)
        }
        prepared = ChatCompletionsReasoningCache.removingToolCallHistoryMissingReasoningContent(from: prepared)
        metadata["chat_tool_history_protection"] = "removed_missing_reasoning"
        metadata.merge(self.chatCompletionsFinalRequestMetadata(prepared)) { _, new in new }
        return PreparedChatCompletionsRequest(body: prepared, metadata: metadata)
    }

    private func chatCompletionsFinalRequestMetadata(_ request: [String: Any]) -> [String: String] {
        let messages = request["messages"] as? [[String: Any]] ?? []
        let assistantToolCallCount = messages.reduce(0) { count, message in
            let role = ((message["role"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard role == "assistant" else { return count }
            return count + ((message["tool_calls"] as? [[String: Any]]) ?? []).count
        }
        let reasoningContentCount = messages.reduce(0) { count, message in
            guard let text = message["reasoning_content"] as? String,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return count
            }
            return count + 1
        }
        return [
            "assistant_tool_call_count": "\(assistantToolCallCount)",
            "reasoning_content_count": "\(reasoningContentCount)",
            "final_messages_count": "\(messages.count)",
            "final_messages_prefix_sha256": DiagnosticRequestBodySupport.normalizedPrefixSHA256(from: request),
        ]
    }

    private func requiresChatCompletionsThinkingToolHistoryProtection(
        _ request: [String: Any],
        auth: ExtractedAuth
    ) -> Bool {
        guard self.usesOpenAIChatCompletionsAdapter(auth) else {
            return false
        }
        if request["reasoning_effort"] != nil || request["thinking"] != nil {
            return true
        }
        let model = ((request["model"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return self.isDeepSeekThinkingModel(model)
    }

    private func isDeepSeekThinkingModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("deepseek-reasoner")
            || lower.contains("deepseek-r1")
            || lower.contains("deepseek_reasoner")
            || (lower.contains("deepseek") && lower.contains("reasoner"))
    }

    private func requestByApplyingOCRIfNeeded(
        _ request: [String: Any],
        candidate: ProxyCandidate,
        config: AppConfig,
        endpoint: String,
        requestedModel: String
    ) async -> [String: Any] {
        guard candidate.record.supportsVision == false else {
            return request
        }
        return await self.ocrImageProcessor.requestByApplyingOCRIfNeeded(
            request,
            config: config,
            logContext: self.ocrRecognitionLogContext(
                candidate: candidate,
                endpoint: endpoint,
                requestedModel: requestedModel,
                request: request
            )
        )
    }

    private func anthropicRequestByApplyingOCRIfNeeded(
        _ request: [String: Any],
        candidate: ProxyCandidate,
        config: AppConfig,
        endpoint: String,
        requestedModel: String
    ) async -> [String: Any] {
        guard candidate.record.supportsVision == false else {
            return request
        }
        return await self.ocrImageProcessor.anthropicRequestByApplyingOCRIfNeeded(
            request,
            config: config,
            logContext: self.ocrRecognitionLogContext(
                candidate: candidate,
                endpoint: endpoint,
                requestedModel: requestedModel,
                request: request
            )
        )
    }

    private func geminiNativeRequestByApplyingOCRIfNeeded(
        _ request: [String: Any],
        candidate: ProxyCandidate,
        config: AppConfig
    ) async -> [String: Any] {
        guard candidate.record.supportsVision == false else {
            return request
        }
        return await self.ocrImageProcessor.geminiRequestByApplyingOCRIfNeeded(
            request,
            config: config,
            logContext: self.ocrRecognitionLogContext(
                candidate: candidate,
                endpoint: "/v1beta/models/gemini:generateContent",
                requestedModel: (request["model"] as? String) ?? "",
                request: request
            )
        )
    }

    private func ocrRecognitionLogContext(
        candidate: ProxyCandidate,
        endpoint: String,
        requestedModel: String,
        request: [String: Any]
    ) -> OCRRecognitionLogContext {
        let requestModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadModel = (request["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return OCRRecognitionLogContext(
            endpoint: endpoint,
            accountKey: candidate.record.accountKey,
            accountLabel: candidate.record.label,
            requestedModel: requestModel.isEmpty ? payloadModel : requestModel
        )
    }

    private func captureDiagnosticRequestBodyIfNeeded(
        config: AppConfig,
        endpoint: String,
        upstreamURL: String,
        candidate: ProxyCandidate,
        requestedModel: String,
        actualModel: String?,
        body: Data,
        bodyObject: [String: Any],
        metadata: [String: String] = [:]
    ) -> Int64? {
        let captureConfig = config.diagnosticRequestBodyCapture
        guard captureConfig.enabled else {
            return nil
        }
        do {
            let entry = try self.store.insertDiagnosticRequestBody(
                DiagnosticRequestBodyCaptureInput(
                    endpoint: endpoint,
                    upstreamURL: upstreamURL,
                    accountKey: candidate.record.accountKey,
                    accountLabel: candidate.record.label,
                    model: requestedModel,
                    actualModel: actualModel,
                    body: body,
                    bodyObject: bodyObject,
                    metadata: metadata,
                    config: captureConfig
                )
            )
            return entry.id
        } catch {
            print("[diagnostic-request-body] capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func recordTrace(
        _ trace: ProxyRequestTrace,
        diagnosticRequestBodyID: Int64? = nil
    ) throws -> Int64 {
        let requestLogID = try self.store.recordTrace(
            trace.applyingProjectRoute(Self.currentCodexProjectRouteTraceContext)
        )
        if let diagnosticRequestBodyID {
            try? self.store.linkDiagnosticRequestBody(id: diagnosticRequestBodyID, requestLogID: requestLogID)
        }
        self.publishRequestLoggedEvent(requestLogID: requestLogID)
        return requestLogID
    }

    private func publishRequestLoggedEvent(requestLogID: Int64) {
        Task {
            await self.adminEventHub.publishRequestLogged(requestLogID: requestLogID)
        }
    }

    private func syntheticResponseInputData(from input: Any?) -> Data? {
        guard let input else { return nil }
        return try? JSONSerialization.data(withJSONObject: input)
    }

    private func preparedGeminiNativeRequestPayload(
        rawRequest: [String: Any],
        candidate: ProxyCandidate,
        context: PromptCacheContext,
        config: AppConfig
    ) async -> [String: Any] {
        let request = await self.geminiNativeRequestByApplyingOCRIfNeeded(
            rawRequest,
            candidate: candidate,
            config: config
        )
        guard await self.shouldApplyGeminiNativeThoughtSignatureCompatibility(
            rawRequest: request,
            selectedAccountKey: candidate.record.accountKey,
            context: context
        ) else {
            return request
        }

        return GeminiTranscoder.replacingThoughtSignaturesWithCompatibilitySignature(
            in: request
        )
    }

    private func preparedAnthropicRequestPayload(
        rawPayload: [String: Any],
        upstreamModel: String,
        stream: Bool,
        candidate: ProxyCandidate
    ) -> [String: Any] {
        let payload = PromptCacheSupport.applyRawAnthropicRequest(
            rawPayload,
            upstreamModel: upstreamModel,
            stream: stream
        )
        guard self.shouldSanitizeAnthropicThinkingHistory(for: candidate.auth) else {
            return payload
        }

        let baseURL = candidate.auth.upstreamBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? candidate.auth.upstreamBaseURL!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : candidate.auth.providerPreset.defaultBaseURL
        return AnthropicAPIKeyUpstream.sanitizedRequestForUnsupportedThinkingContentBlocks(
            payload,
            baseURL: baseURL
        )
    }

    private func shouldSanitizeAnthropicThinkingHistory(for auth: ExtractedAuth) -> Bool {
        guard auth.authMode == .anthropicAPIKey else {
            return false
        }

        let baseURL = auth.upstreamBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? auth.upstreamBaseURL!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : auth.providerPreset.defaultBaseURL
        return AnthropicAPIKeyUpstream.supportsThinkingContentBlocks(baseURL: baseURL) == false
    }

    private func shouldApplyGeminiNativeThoughtSignatureCompatibility(
        rawRequest: [String: Any],
        selectedAccountKey: String,
        context: PromptCacheContext
    ) async -> Bool {
        guard context.isGeminiCLISession,
              GeminiTranscoder.containsThoughtSignature(in: rawRequest)
        else {
            return false
        }

        if let stickySessionKey = context.stickySessionKey,
           stickySessionKey.isEmpty == false,
           let boundAccountKey = await self.stickySessionBindings.accountKey(for: stickySessionKey)
        {
            return boundAccountKey != selectedAccountKey
        }

        return true
    }

    private func classifyFailure(status: Int, text: String) -> ProxyRequestTrace.FailureCategory {
        if UsageLimitReachedSignal.parse(from: text) != nil {
            return .quota
        }
        if status == 401 || HTTPErrorClassifier.containsAuthSignal(text) {
            return .auth
        }
        if status == 429 || HTTPErrorClassifier.containsRateLimitSignal(text) {
            return .rateLimit
        }
        if status == 402 || HTTPErrorClassifier.containsQuotaSignal(text) {
            return .quota
        }
        return .upstream
    }

    private func ensureGeminiPublicRouteCLISession(_ context: PromptCacheContext) throws {
        guard context.isGeminiCLISession else {
            throw ProxyError.message(self.geminiPublicRouteCLIOnlyMessage())
        }
    }

    private func geminiPublicRouteCLIOnlyMessage() -> String {
        "Unsupported Gemini public route: official Gemini CLI sessions only. Import a `Google / Gemini Login` account first, and do not call `/v1beta/models/*` POST routes from non-CLI clients."
    }

    private func geminiPublicRouteRequiresGoogleGeminiLoginMessage() -> String {
        "Unsupported Gemini account configuration: Gemini public routes require an enabled `Google / Gemini Login` account. Manual API key, OpenAI-compatible, Anthropic-compatible, and Google Gemini Compatible accounts are not used here."
    }

    private func adminGeminiProxyTestEndpointOnlyMessage() -> String {
        "Admin proxy test only supports the Gemini endpoint when the selected account comes from `Google / Gemini Login`."
    }

    private func adminGeminiProxyTestRequiresGoogleGeminiLoginMessage() -> String {
        "Admin proxy test for Gemini only supports accounts imported from `Google / Gemini Login`."
    }

    private func adminProxyTestHeaders(
        selectedAccountKey: String?,
        anthropicVersion: String?,
        anthropicBeta: String?
    ) -> [String: String] {
        var headers = [
            ProxyHeaderName.proxyTestConsole: "1",
        ]
        if let selectedAccountKey {
            headers[ProxyHeaderName.testAccountKey] = selectedAccountKey
        }
        if let anthropicVersion = self.trimmed(anthropicVersion) {
            headers["anthropic-version"] = anthropicVersion
        }
        if let anthropicBeta = self.trimmed(anthropicBeta) {
            headers["anthropic-beta"] = anthropicBeta
        }
        return headers
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func noAvailableAccountsMessage(
        for dataSource: ProxyDataSource,
        allowedAccountKeys: [String] = []
    ) -> String {
        let isRestricted = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(allowedAccountKeys).isEmpty == false
        switch dataSource {
        case .all:
            return isRestricted
                ? "当前 API Key 已限制可用账号范围，但限制范围内没有任何可用的上游账号。"
                : "当前 API Key 绑定的是全部数据源，但没有任何可用的上游账号。"
        case .openAI:
            return isRestricted
                ? "当前 API Key 已限制可用账号范围，但限制范围内没有可用的 OpenAI 账号。"
                : "当前 API Key 绑定的是 OpenAI 数据源，但没有可用的 OpenAI 账号。"
        case .anthropic:
            return isRestricted
                ? "当前 API Key 已限制可用账号范围，但限制范围内没有可用的 Anthropic 账号。"
                : "当前 API Key 绑定的是 Anthropic 数据源，但没有可用的 Anthropic 账号。"
        case .gemini:
            return isRestricted
                ? "当前 API Key 已限制可用账号范围，但限制范围内没有可用的 Gemini 账号。"
                : "当前 API Key 绑定的是 Gemini 数据源，但没有可用的 Gemini 账号。"
        }
    }

    private func disallowedSelectedAccountMessage() -> String {
        "指定的测试账号不在当前 API Key 允许使用的账号范围内。"
    }

    private func manualAPIKeyConfigurationError(for record: AccountRecord) -> String? {
        guard record.authMode.isManualAPIKey else {
            return nil
        }
        if let extracted = try? AuthService.extractAuth(from: record.authJSON, secretStore: self.secretStore) {
            return OpenAICompatibleUpstream.storedConfigurationError(
                baseURL: extracted.upstreamBaseURL ?? record.upstreamBaseURL ?? extracted.providerPreset.defaultBaseURL,
                providerPreset: extracted.providerPreset,
                apiKey: extracted.accessToken
            )
        }

        let metadata = AuthService.extractAuthMetadata(from: record.authJSON)
        let providerPreset = metadata.authMode.isManualAPIKey ? metadata.providerPreset : record.providerPreset
        let baseURL = metadata.upstreamBaseURL ?? record.upstreamBaseURL ?? providerPreset.defaultBaseURL
        return OpenAICompatibleUpstream.storedConfigurationError(
            baseURL: baseURL,
            providerPreset: providerPreset,
            apiKey: nil
        )
    }

    private func publicFacingCandidateFailureMessage(
        candidate: ProxyCandidate,
        rawText: String
    ) -> String {
        let summary = summarizedUpstreamError(rawText)
        let message: String
        if candidate.record.authMode == .anthropicSubscriptionOAuth,
           AnthropicAuthService.isInferenceScopePermissionError(rawText)
        {
            message = AnthropicAuthService.reauthorizationRequiredMessage
        } else if candidate.record.authMode.isManualAPIKey {
            let chatHumanized = self.usesOpenAIChatCompletionsAdapter(candidate.auth)
                || self.usesPresetChatCompletionsAdapter(candidate.auth)
                ? ChatCompletionsCompatibility.humanizedUpstreamErrorMessage(summary)
                : summary
            let humanized = OpenAICompatibleUpstream.humanizedUpstreamErrorMessage(
                chatHumanized,
                providerPreset: candidate.auth.providerPreset,
                apiKey: candidate.auth.accessToken
            )
            message = humanized == chatHumanized ? chatHumanized : humanized
        } else {
            message = summary
        }
        return "\(candidate.record.label): \(message)"
    }

    private func upstreamRequest(
        for auth: ExtractedAuth,
        config: AppConfig,
        accept: String = "text/event-stream"
    ) -> (url: String, headers: [String: String]) {
        switch auth.authMode {
        case .chatGPT:
            var headers = [
                "Authorization": "Bearer \(auth.accessToken)",
                "Content-Type": "application/json",
                "Accept": accept,
                "User-Agent": RuntimeInfo.daemonServerToken,
            ]
            headers["ChatGPT-Account-Id"] = auth.accountID
            return (
                config.chatGPTBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/backend-api/codex/responses",
                headers
            )
        case .openAIAPIKey:
            let headers = OpenAICompatibleUpstream.requestHeaders(
                apiKey: auth.accessToken,
                accept: accept,
                providerPreset: auth.providerPreset
            )
            if self.usesOpenAIChatCompletionsAdapter(auth) {
                return (self.openAIChatCompletionsURL(config: config, auth: auth), headers)
            }
            return (self.openAIResponsesURL(config: config, auth: auth), headers)
        case .geminiOAuth:
            return GeminiAuthService.apiRequest(auth: auth, method: "loadCodeAssist", accept: accept)
        case .anthropicAPIKey, .anthropicSubscriptionOAuth:
            return self.anthropicUpstreamRequest(
                for: auth,
                path: "/v1/messages",
                stream: accept.contains("event-stream")
            )
        }
    }

    private func anthropicUpstreamRequest(
        for auth: ExtractedAuth,
        path: String,
        stream: Bool,
        anthropicVersion: String = AnthropicTranscoder.defaultAnthropicVersion,
        anthropicBeta: String? = nil
    ) -> (url: String, headers: [String: String]) {
        let baseURL = auth.upstreamBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? auth.upstreamBaseURL!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : auth.providerPreset.defaultBaseURL
        let accept = stream ? "text/event-stream" : "application/json"
        let headers: [String: String]
        switch auth.authMode {
        case .anthropicAPIKey:
            headers = AnthropicAPIKeyUpstream.requestHeaders(
                apiKey: auth.accessToken,
                accept: accept,
                anthropicVersion: anthropicVersion,
                anthropicBeta: anthropicBeta
            )
        case .anthropicSubscriptionOAuth:
            var oauthHeaders = [
                "Authorization": "Bearer \(auth.accessToken)",
                "Content-Type": "application/json",
                "Accept": accept,
                "anthropic-version": anthropicVersion,
                "User-Agent": RuntimeInfo.daemonServerToken,
            ]
            oauthHeaders["anthropic-beta"] = anthropicBeta ?? AnthropicAuthService.defaultOAuthBetaHeader
            headers = oauthHeaders
        case .chatGPT, .openAIAPIKey, .geminiOAuth:
            headers = [:]
        }
        return ("\(baseURL)\(path)", headers)
    }

    private func resolveOpenAIToAnthropicModel(requestedModel: String) -> String {
        let trimmed = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AnthropicUpstreamBridge.defaultOpenAIToAnthropicModel
        }
        if trimmed.lowercased().hasPrefix("claude-") {
            return trimmed
        }
        let lower = trimmed.lowercased()
        if lower.contains("opus") || lower.contains("max") {
            return "claude-opus-4-6"
        }
        if lower.contains("mini") || lower.contains("haiku") {
            return "claude-3-5-haiku-latest"
        }
        return AnthropicUpstreamBridge.defaultOpenAIToAnthropicModel
    }

    private func normalizedAnthropicMessage(_ message: [String: Any]) -> [String: Any] {
        var normalized = message
        if let usage = ProxyTranscoder.normalizedAnthropicUsageObject(message["usage"]) {
            normalized["usage"] = usage
        }
        return normalized
    }

    private func loggedActualModel(from requestBody: [String: Any]) -> String? {
        let trimmed = (requestBody["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedAnthropicEvent(_ event: SSEEvent) -> SSEEvent {
        guard let json = ProxyTranscoder.jsonObject(from: event) else {
            return event
        }

        var normalized = json
        if var message = normalized["message"] as? [String: Any],
           let usage = ProxyTranscoder.normalizedAnthropicUsageObject(message["usage"])
        {
            message["usage"] = usage
            normalized["message"] = message
        }
        if let usage = ProxyTranscoder.normalizedAnthropicUsageObject(normalized["usage"]) {
            normalized["usage"] = usage
        }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized),
              let payload = String(data: data, encoding: .utf8)
        else {
            return event
        }
        return SSEEvent(event: event.event, data: payload)
    }

    private func anthropicUsage(from message: [String: Any]) -> UpstreamUsage {
        ProxyTranscoder.usageFromAnthropicUsage(message["usage"])
    }

    private func anthropicToSyntheticResponseStream(
        upstreamBody: AsyncThrowingStream<Data, Error>,
        requestedModel: String
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = SSEIncrementalDecoder()
                var state = AnthropicSyntheticStreamState()
                do {
                    for try await chunk in upstreamBody {
                        for event in decoder.append(chunk) {
                            if let errorMessage = self.anthropicStreamErrorMessage(from: event) {
                                throw ProxyError.message(errorMessage)
                            }
                            for syntheticChunk in AnthropicUpstreamBridge.responseSSEChunks(
                                from: event,
                                state: &state,
                                requestedModel: requestedModel
                            ) {
                                continuation.yield(Data(syntheticChunk.utf8))
                            }
                        }
                    }
                    for event in decoder.finish() {
                        if let errorMessage = self.anthropicStreamErrorMessage(from: event) {
                            throw ProxyError.message(errorMessage)
                        }
                        for syntheticChunk in AnthropicUpstreamBridge.responseSSEChunks(
                            from: event,
                            state: &state,
                            requestedModel: requestedModel
                        ) {
                            continuation.yield(Data(syntheticChunk.utf8))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func openAIChatToSyntheticResponseStream(
        upstreamBody: AsyncThrowingStream<Data, Error>,
        requestedModel: String,
        inputData: Data? = nil,
        reasoningCacheAccountKey: String? = nil,
        reasoningCacheSessionKey: String? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = SSEIncrementalDecoder()
                var state = OpenAIChatSyntheticStreamState()
                let input = inputData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                func recordReasoningIfNeeded() {
                    guard let accountKey = reasoningCacheAccountKey else { return }
                    let completed = ProxyTranscoder.completedResponse(
                        fromChatCompletionState: state,
                        requestedModel: requestedModel,
                        input: input
                    )
                    self.chatCompletionsReasoningCache.record(
                        completedResponse: completed,
                        accountKey: accountKey,
                        sessionKey: reasoningCacheSessionKey
                    )
                }
                do {
                    for try await chunk in upstreamBody {
                        for event in decoder.append(chunk) {
                            for syntheticChunk in try ProxyTranscoder.responseSSEChunks(
                                fromChatCompletionEvent: event,
                                state: &state,
                                requestedModel: requestedModel,
                                input: input
                            ) {
                                continuation.yield(Data(syntheticChunk.utf8))
                            }
                            if state.isCompleted {
                                recordReasoningIfNeeded()
                                continuation.finish()
                                return
                            }
                        }
                    }
                    for event in decoder.finish() {
                        for syntheticChunk in try ProxyTranscoder.responseSSEChunks(
                            fromChatCompletionEvent: event,
                            state: &state,
                            requestedModel: requestedModel,
                            input: input
                        ) {
                            continuation.yield(Data(syntheticChunk.utf8))
                        }
                        if state.isCompleted {
                            recordReasoningIfNeeded()
                            continuation.finish()
                            return
                        }
                    }
                    for syntheticChunk in ProxyTranscoder.finalizeResponseSSEChunks(
                        fromChatCompletionState: state,
                        requestedModel: requestedModel,
                        input: input
                    ) {
                        continuation.yield(Data(syntheticChunk.utf8))
                    }
                    recordReasoningIfNeeded()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func makeAnthropicPassthroughStreamingResponse(
        upstreamBody: AsyncThrowingStream<Data, Error>,
        endpoint: String,
        upstreamURL: String?,
        apiKeyHash: String,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        requestedModel: String,
        actualModel: String?,
        candidate: ProxyCandidate,
        startMS: Int64,
        reasoningEffort: String? = nil,
        anthropicVersion: String,
        anthropicBeta: String?
    ) -> ProxyHTTPResponse {
        let headers = self.anthropicResponseHeaders(
            version: anthropicVersion,
            beta: anthropicBeta,
            contentType: "text/event-stream; charset=utf-8"
        )
        let accountKey = candidate.record.accountKey
        let accountLabel = candidate.record.label
        let terminalTrace = StreamTerminalTraceCoordinator()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var decoder = SSEIncrementalDecoder()
                var state = AnthropicSyntheticStreamState()

                func recordSuccess(_ usage: UpstreamUsage) async {
                    guard await terminalTrace.begin(.success) else {
                        return
                    }
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: apiKeyHash,
                            accountKey: accountKey,
                            accountLabel: accountLabel,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            reasoningEffort: reasoningEffort,
                            success: true,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            usage: usage,
                            apiKeyValue: apiKeyValue
                        )
                    )
                    try? self.noteCandidateAttemptSuccess(candidate)
                }

                func recordFailure(_ message: String) async {
                    guard await terminalTrace.begin(.failure) else {
                        return
                    }
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: apiKeyHash,
                            accountKey: accountKey,
                            accountLabel: accountLabel,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            reasoningEffort: reasoningEffort,
                            success: false,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            failureCategory: .upstream,
                            lastError: Helpers.truncate(message),
                            apiKeyValue: apiKeyValue
                        )
                    )
                    await self.setLastError(
                        self.publicFacingCandidateFailureMessage(
                            candidate: candidate,
                            rawText: message
                        )
                    )
                    try? self.noteCandidateAttemptFailure(candidate)
                }

                do {
                    for try await chunk in upstreamBody {
                        for event in decoder.append(chunk) {
                            if let errorMessage = self.anthropicStreamErrorMessage(from: event) {
                                throw ProxyError.message(errorMessage)
                            }
                            let normalizedEvent = self.normalizedAnthropicEvent(event)
                            continuation.yield(Data(self.sseString(from: normalizedEvent).utf8))
                            _ = AnthropicUpstreamBridge.responseSSEChunks(
                                from: normalizedEvent,
                                state: &state,
                                requestedModel: requestedModel
                            )
                        }
                    }
                    for event in decoder.finish() {
                        if let errorMessage = self.anthropicStreamErrorMessage(from: event) {
                            throw ProxyError.message(errorMessage)
                        }
                        let normalizedEvent = self.normalizedAnthropicEvent(event)
                        continuation.yield(Data(self.sseString(from: normalizedEvent).utf8))
                        _ = AnthropicUpstreamBridge.responseSSEChunks(
                            from: normalizedEvent,
                            state: &state,
                            requestedModel: requestedModel
                        )
                    }
                    let completed = AnthropicUpstreamBridge.completedResponse(from: state, requestedModel: requestedModel)
                    let usage = ProxyTranscoder.usageFromCompletedResponse(completed)
                    await recordSuccess(usage)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    await recordFailure(error.localizedDescription)
                    continuation.yield(Data(AnthropicTranscoder.errorSSEChunk(message: error.localizedDescription).utf8))
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    Task {
                        guard await terminalTrace.begin(.cancelled) else {
                            return
                        }
                        _ = try? self.recordTrace(
                            ProxyRequestTrace(
                                endpoint: endpoint,
                                upstreamURL: upstreamURL,
                                apiKeyHash: apiKeyHash,
                                accountKey: accountKey,
                                accountLabel: accountLabel,
                                clientSource: clientSource,
                                model: requestedModel,
                                actualModel: actualModel,
                                reasoningEffort: reasoningEffort,
                                success: false,
                                latencyMS: Helpers.nowMilliseconds() - startMS,
                                failureCategory: .cancelled,
                                lastError: Helpers.truncate(self.cancelledStreamFailureMessage()),
                                apiKeyValue: apiKeyValue
                            )
                        )
                    }
                }
                task.cancel()
            }
        }
        return ProxyHTTPResponse(statusCode: 200, headers: headers, body: .stream(stream))
    }

    private func sseString(from event: SSEEvent) -> String {
        var lines: [String] = []
        if let name = event.event, !name.isEmpty {
            lines.append("event: \(name)")
        }
        let payloadLines = event.data.split(separator: "\n", omittingEmptySubsequences: false)
        if payloadLines.isEmpty {
            lines.append("data:")
        } else {
            for line in payloadLines {
                lines.append("data: \(line)")
            }
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private func anthropicStreamErrorMessage(from event: SSEEvent) -> String? {
        guard let json = ProxyTranscoder.jsonObject(from: event),
              (json["type"] as? String) == "error"
        else {
            return nil
        }
        let error = json["error"] as? [String: Any] ?? [:]
        return (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func int64Value(_ value: Any?) -> Int64? {
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

    private func compatibleCodexRequest(_ request: [String: Any], for auth: ExtractedAuth) -> [String: Any] {
        self.compatibleCodexRequest(request, for: auth, preserveResolvedModel: false)
    }

    private func compatibleCodexRequest(
        _ request: [String: Any],
        for auth: ExtractedAuth,
        preserveResolvedModel: Bool
    ) -> [String: Any] {
        guard auth.authMode == .chatGPT else {
            return request
        }

        var compatible = request
        [
            "max_output_tokens",
            "temperature",
            "top_p",
            "top_k",
            "n",
            "metadata",
        ].forEach { compatible.removeValue(forKey: $0) }

        return compatible
    }

    private struct ProxyRequestModelResolution {
        var resolvedRequestModel: String
        var usesAccountModelRouting: Bool
    }

    private struct ProjectRouteApplication {
        var rule: CodexProjectRouteRule
        var proxyKey: AuthenticatedProxyKeyContext
        var apiKeyValue: String
        var traceContext: CodexProjectRouteTraceContext
    }

    private func projectRouteApplication(
        requestedModel: String,
        client: ProjectRouteClient,
        config: AppConfig,
        authenticatedProxyKey: AuthenticatedProxyKeyContext
    ) throws -> ProjectRouteApplication? {
        guard let rule = config.projectRoute(for: requestedModel, client: client) else {
            return nil
        }
        return try self.projectRouteApplication(
            rule: rule,
            client: client,
            authenticatedProxyKey: authenticatedProxyKey,
            config: config
        )
    }

    private func codexProjectRouteApplication(
        requestedModel: String,
        requestPayload: [String: Any],
        headers: [String: String],
        client: ProjectRouteClient,
        config: AppConfig,
        authenticatedProxyKey: AuthenticatedProxyKeyContext
    ) throws -> ProjectRouteApplication? {
        if let modelRoute = try self.projectRouteApplication(
            requestedModel: requestedModel,
            client: client,
            config: config,
            authenticatedProxyKey: authenticatedProxyKey
        ) {
            return modelRoute
        }
        guard client == .codex,
              let sessionID = PromptCacheSupport.sessionIdentifier(headers: headers, requestPayload: requestPayload),
              let project = self.codexDesktopSessionProjectResolver.project(forSessionID: sessionID),
              let rule = config.codexProjectRoute(forProjectPath: project.cwd)
        else {
            return nil
        }
        return try self.projectRouteApplication(
            rule: rule,
            client: client,
            authenticatedProxyKey: authenticatedProxyKey,
            config: config
        )
    }

    private func projectRouteApplication(
        rule: CodexProjectRouteRule,
        client: ProjectRouteClient,
        authenticatedProxyKey _: AuthenticatedProxyKeyContext,
        config: AppConfig
    ) throws -> ProjectRouteApplication {
        guard let configuredProxyKey = config.enabledProxyAPIKeys.first(where: { $0.id == rule.proxyAPIKeyID }) else {
            throw ProxyError.message("项目路由 `\(rule.label.isEmpty ? rule.routeModel : rule.label)` 绑定的本地 API Key 不存在或已禁用。")
        }
        guard let dataSource = self.projectRouteDataSource(client: client, proxyKey: configuredProxyKey) else {
            throw ProxyError.message("项目路由 `\(rule.label.isEmpty ? rule.routeModel : rule.label)` 绑定的本地 API Key `\(configuredProxyKey.label)` 数据源不支持当前客户端。")
        }

        let proxyKey = AuthenticatedProxyKeyContext(
            apiKeyHash: Helpers.sha256(configuredProxyKey.key),
            proxyKeyID: configuredProxyKey.id,
            dataSource: dataSource,
            allowedAccountKeys: ProxyAPIKeyRecord.normalizedAllowedAccountKeys(configuredProxyKey.allowedAccountKeys)
        )
        return ProjectRouteApplication(
            rule: rule,
            proxyKey: proxyKey,
            apiKeyValue: configuredProxyKey.key,
            traceContext: CodexProjectRouteTraceContext(
                projectRouteID: rule.id,
                projectRouteLabel: rule.label,
                effectiveProxyAPIKeyID: configuredProxyKey.id
            )
        )
    }

    private func visibleCodexProjectRouteModels(
        for _: AuthenticatedProxyKeyContext,
        config: AppConfig
    ) -> [String] {
        self.visibleProjectRouteModels(config: config, client: .codex)
    }

    private func visibleProjectRouteModels(
        config: AppConfig,
        client: ProjectRouteClient
    ) -> [String] {
        config.enabledCodexProjectRoutes.compactMap { rule in
            guard rule.client == client else { return nil }
            guard let configuredProxyKey = config.enabledProxyAPIKeys.first(where: { $0.id == rule.proxyAPIKeyID }) else {
                return nil
            }
            guard self.projectRouteDataSource(client: client, proxyKey: configuredProxyKey) != nil else {
                return nil
            }
            return rule.routeModel
        }
    }

    private func projectRouteDataSource(
        client: ProjectRouteClient,
        proxyKey: ProxyAPIKeyRecord
    ) -> ProxyDataSource? {
        let expected: ProxyDataSource
        switch client {
        case .codex:
            expected = .openAI
        case .claudeCode:
            expected = .anthropic
        }
        if proxyKey.dataSource == .all {
            return expected
        }
        return proxyKey.dataSource == expected ? expected : nil
    }

    private func withCodexProjectRouteTraceContext<T>(
        _ context: CodexProjectRouteTraceContext?,
        operation: () async throws -> T
    ) async throws -> T {
        guard let context else {
            return try await operation()
        }
        return try await Self.$currentCodexProjectRouteTraceContext.withValue(context) {
            try await operation()
        }
    }

    private func resolvedCodexRequest(
        _ request: [String: Any],
        requestedModel: String,
        sourceAnthropicModel: String?,
        record: AccountRecord,
        config: AppConfig,
        auth: ExtractedAuth
    ) -> ([String: Any], ProxyRequestModelResolution) {
        var resolved = request
        let resolution = self.resolveProxyRequestModel(
            requestedModel: requestedModel,
            sourceAnthropicModel: sourceAnthropicModel,
            record: record,
            config: config,
            auth: auth
        )
        if sourceAnthropicModel != nil || resolution.usesAccountModelRouting {
            resolved["model"] = resolution.resolvedRequestModel
        }
        return (resolved, resolution)
    }

    private func resolveProxyRequestModel(
        requestedModel: String,
        sourceAnthropicModel: String?,
        record: AccountRecord,
        config: AppConfig,
        auth: ExtractedAuth
    ) -> ProxyRequestModelResolution {
        let sourceModel = (sourceAnthropicModel ?? requestedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        if let routedTarget = record.modelRouting?.resolvedTargetModel(for: sourceModel) {
            return ProxyRequestModelResolution(
                resolvedRequestModel: routedTarget,
                usesAccountModelRouting: true
            )
        }
        if let defaultTargetModel = record.modelRouting?.defaultTargetModel {
            return ProxyRequestModelResolution(
                resolvedRequestModel: defaultTargetModel,
                usesAccountModelRouting: true
            )
        }
        if let sourceAnthropicModel {
            return ProxyRequestModelResolution(
                resolvedRequestModel: self.resolveAnthropicTargetModel(
                    sourceModel: sourceAnthropicModel,
                    config: config,
                    auth: auth
                ),
                usesAccountModelRouting: false
            )
        }
        let trimmedRequestedModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProxyRequestModelResolution(
            resolvedRequestModel: trimmedRequestedModel.isEmpty ? requestedModel : trimmedRequestedModel,
            usesAccountModelRouting: false
        )
    }

    private func resolveAnthropicTargetModel(
        sourceModel: String,
        config: AppConfig,
        auth: ExtractedAuth
    ) -> String {
        let trimmedSourceModel = sourceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let mappedTarget = config.anthropicModelMappings.first(where: {
            $0.sourceModel == trimmedSourceModel
        })?.targetModel ?? config.anthropicDefaultTargetModel
        let trimmedMappedTarget = mappedTarget.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmedMappedTarget.isEmpty ? AppConfig.defaultAnthropicTargetModel : trimmedMappedTarget
    }

    private func normalizedGeminiSourceModel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return String(trimmed.dropFirst("models/".count))
        }
        return trimmed
    }

    private func geminiSourceModels() -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        let defaults = [
            "gemini-2.0-flash",
            "gemini-2.5-pro",
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite",
            "gemini-3-flash-preview",
            "gemini-3-pro-preview",
            "gemini-3.1-pro-preview",
        ]
        for model in defaults {
            let normalized = self.normalizedGeminiSourceModel(model)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    private func geminiModelObject(for model: String) -> [String: Any] {
        let normalized = self.normalizedGeminiSourceModel(model)
        return [
            "name": "models/\(normalized)",
            "baseModelId": normalized,
            "version": normalized,
            "displayName": normalized,
            "description": "Gemini-compatible model routed by Codex Proxy.",
            "inputTokenLimit": 1_048_576,
            "outputTokenLimit": 65_536,
            "supportedGenerationMethods": [
                "generateContent",
                "streamGenerateContent",
                "countTokens",
            ],
        ]
    }

    private func openAIResponsesURL(config: AppConfig, auth: ExtractedAuth) -> String {
        let baseURL = auth.upstreamBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = (baseURL?.isEmpty == false ? baseURL! : OpenAICompatibleUpstream.defaultBaseURL)
        return (try? OpenAICompatibleUpstream.responsesURL(
            from: resolvedBaseURL,
            providerPreset: auth.providerPreset,
            baseURLMode: auth.baseURLMode
        ))
            ?? (try? OpenAICompatibleUpstream.responsesURL(
                from: auth.providerPreset.defaultBaseURL,
                providerPreset: auth.providerPreset,
                baseURLMode: auth.baseURLMode
            ))
            ?? "\(config.chatGPTBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/responses"
    }

    private func openAIChatCompletionsURL(config: AppConfig, auth: ExtractedAuth) -> String {
        let baseURL = auth.upstreamBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = (baseURL?.isEmpty == false ? baseURL! : OpenAICompatibleUpstream.defaultBaseURL)
        return (try? OpenAICompatibleUpstream.chatCompletionsURL(
            from: resolvedBaseURL,
            providerPreset: auth.providerPreset,
            baseURLMode: auth.baseURLMode
        ))
            ?? (try? OpenAICompatibleUpstream.chatCompletionsURL(
                from: auth.providerPreset.defaultBaseURL,
                providerPreset: auth.providerPreset,
                baseURLMode: auth.baseURLMode
            ))
            ?? "\(config.chatGPTBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/chat/completions"
    }

    private func openAIUpstreamAdapters(for auth: ExtractedAuth) -> [OpenAIUpstreamAdapter] {
        [self.openAIUpstreamAdapter(for: auth)]
    }

    private func openAIUpstreamAdapter(for auth: ExtractedAuth) -> OpenAIUpstreamAdapter {
        if auth.authMode == .openAIAPIKey,
           auth.providerPreset == .genericOpenAICompatible,
           auth.upstreamAdapter == .chatCompletions
        {
            return .chatCompletions
        }
        return self.usesPresetChatCompletionsAdapter(auth) ? .chatCompletions : .responses
    }

    private func openAIUpstreamRequest(
        for auth: ExtractedAuth,
        config: AppConfig,
        accept: String,
        adapter: OpenAIUpstreamAdapter
    ) -> (url: String, headers: [String: String]) {
        let headers = OpenAICompatibleUpstream.requestHeaders(
            apiKey: auth.accessToken,
            accept: accept,
            providerPreset: auth.providerPreset
        )
        let url = switch adapter {
        case .responses:
            self.openAIResponsesURL(config: config, auth: auth)
        case .chatCompletions:
            self.openAIChatCompletionsURL(config: config, auth: auth)
        }
        return (url, headers)
    }

    private func openAIUpstreamRequestBody(
        from compatibleRequest: [String: Any],
        requestedModel: String,
        auth: ExtractedAuth,
        adapter: OpenAIUpstreamAdapter,
        stream: Bool,
        preserveCustomModel: Bool = false,
        useResolvedModelAsFinalUpstreamModel: Bool = false
    ) -> [String: Any] {
        self.openAIUpstreamRequestBodyWithDiagnostics(
            from: compatibleRequest,
            requestedModel: requestedModel,
            auth: auth,
            adapter: adapter,
            stream: stream,
            preserveCustomModel: preserveCustomModel,
            useResolvedModelAsFinalUpstreamModel: useResolvedModelAsFinalUpstreamModel
        ).body
    }

    private func openAIUpstreamRequestBodyWithDiagnostics(
        from compatibleRequest: [String: Any],
        requestedModel: String,
        auth: ExtractedAuth,
        adapter: OpenAIUpstreamAdapter,
        stream: Bool,
        preserveCustomModel: Bool = false,
        useResolvedModelAsFinalUpstreamModel: Bool = false
    ) -> PreparedChatCompletionsRequest {
        let effectiveRequestedModel = (compatibleRequest["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRequestedModel = effectiveRequestedModel?.isEmpty == false
            ? effectiveRequestedModel!
            : requestedModel
        let resolvedUpstreamModel: String
        if useResolvedModelAsFinalUpstreamModel {
            resolvedUpstreamModel = resolvedRequestedModel
        } else if preserveCustomModel,
           auth.authMode == .openAIAPIKey,
           ProxyTranscoder.isSupportedClientModel(resolvedRequestedModel) == false
        {
            resolvedUpstreamModel = resolvedRequestedModel
        } else {
            resolvedUpstreamModel = auth.providerPreset.resolvedUpstreamModel(for: resolvedRequestedModel)
        }
        switch adapter {
        case .responses:
            return PreparedChatCompletionsRequest(
                body: self.compatibleCodexRequest(
                    compatibleRequest,
                    for: auth,
                    preserveResolvedModel: useResolvedModelAsFinalUpstreamModel
                ),
                metadata: [:]
            )
        case .chatCompletions:
            let built = ProxyTranscoder.upstreamChatCompletionsRequestWithDiagnostics(
                from: compatibleRequest,
                upstreamModel: resolvedUpstreamModel,
                stream: stream
            )
            return PreparedChatCompletionsRequest(
                body: built.request,
                metadata: built.diagnostics.metadata
            )
        }
    }

    private func upstreamChatCompletionsRequest(
        from compatibleRequest: [String: Any],
        upstreamModel: String,
        stream: Bool,
        auth: ExtractedAuth
    ) -> [String: Any] {
        self.upstreamChatCompletionsRequestWithDiagnostics(
            from: compatibleRequest,
            upstreamModel: upstreamModel,
            stream: stream,
            auth: auth
        ).body
    }

    private func upstreamChatCompletionsRequestWithDiagnostics(
        from compatibleRequest: [String: Any],
        upstreamModel: String,
        stream: Bool,
        auth: ExtractedAuth
    ) -> PreparedChatCompletionsRequest {
        let built = ProxyTranscoder.upstreamChatCompletionsRequestWithDiagnostics(
            from: compatibleRequest,
            upstreamModel: upstreamModel,
            stream: stream
        )
        return PreparedChatCompletionsRequest(
            body: built.request,
            metadata: built.diagnostics.metadata
        )
    }

    private func applyAccountReasoningEffortMapping(
        to request: [String: Any],
        candidate: ProxyCandidate,
        rawReasoningEffort: String?
    ) -> [String: Any] {
        guard candidate.auth.authMode == .openAIAPIKey,
              self.usesOpenAIChatCompletionsAdapter(candidate.auth),
              let mapped = candidate.record.reasoningEffort.mappedReasoningEffort(for: rawReasoningEffort)
        else {
            return request
        }
        var updated = request
        updated["reasoning_effort"] = mapped
        return updated
    }

    private func usesOpenAIChatCompletionsAdapter(_ auth: ExtractedAuth) -> Bool {
        self.openAIUpstreamAdapter(for: auth) == .chatCompletions
    }

    private func usesPresetChatCompletionsAdapter(_ auth: ExtractedAuth) -> Bool {
        auth.authMode == .openAIAPIKey && auth.providerPreset.usesOpenAIChatCompletionsAPI
    }

    private func handleRecoverableFailure(
        category: ProxyRequestTrace.FailureCategory,
        candidate: ProxyCandidate,
        recordUsage: UsageSnapshot?,
        usageError: String?,
        text: String
    ) async throws -> Bool {
        if category == .quota, let usageLimit = UsageLimitReachedSignal.parse(from: text) {
            let frozenUsage = UsageLimitWindowSupport.usageByApplyingLimit(
                usageLimit,
                to: recordUsage,
                fallbackPlanType: candidate.record.effectivePlanType,
                now: Helpers.now()
            )
            try self.store.updateUsage(
                accountKey: candidate.record.accountKey,
                usage: frozenUsage,
                usageError: usageLimit.normalizedUsageError,
                planType: resolvedAccountPlanType(frozenUsage.planType, fallback: candidate.record.effectivePlanType),
                authJSON: candidate.record.authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: candidate.record.authRefreshBlocked,
                authRefreshError: candidate.record.authRefreshError
            )
            return false
        }

        guard category == .auth, !candidate.record.authRefreshBlocked, candidate.auth.authMode.isManualAPIKey == false else {
            return false
        }
        do {
            let refreshed = try await self.withNetworkConfig(for: candidate.record) {
                try await AuthService.refreshAuth(
                    candidate.record.authJSON,
                    config: $0,
                    secretStore: self.secretStore
                )
            }
            try self.store.updateUsage(
                accountKey: candidate.record.accountKey,
                usage: recordUsage,
                usageError: usageError,
                planType: candidate.record.effectivePlanType,
                authJSON: refreshed,
                usageWindowsVisible: nil,
                authRefreshBlocked: false,
                authRefreshError: nil
            )
            return true
        } catch {
            try self.store.updateUsage(
                accountKey: candidate.record.accountKey,
                usage: recordUsage,
                usageError: usageError,
                planType: candidate.record.effectivePlanType,
                authJSON: candidate.record.authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: true,
                authRefreshError: error.localizedDescription
            )
            await self.setLastError("\(candidate.record.label): \(Helpers.truncate(text))")
            return false
        }
    }

    private func noteCandidateAttemptSuccess(_ candidate: ProxyCandidate) throws {
        guard candidate.record.authMode.isManualAPIKey else { return }
        guard candidate.record.consecutiveFailureCount > 0 || candidate.record.cooldownUntil != nil else { return }
        try self.store.updateAccountFailureState(id: candidate.record.id, consecutiveFailureCount: 0, cooldownUntil: nil)
    }

    private func noteCandidateAttemptFailure(_ candidate: ProxyCandidate) throws {
        guard candidate.record.authMode.isManualAPIKey else { return }
        guard candidate.record.automaticCooldownDisabled == false else { return }
        let nextCount = candidate.record.consecutiveFailureCount + 1
        let cooldownUntil = nextCount >= Self.apiKeyFailureCooldownThreshold
            ? Helpers.now() + Self.apiKeyFailureCooldownSeconds
            : nil
        try self.store.updateAccountFailureState(
            id: candidate.record.id,
            consecutiveFailureCount: nextCount,
            cooldownUntil: cooldownUntil
        )
    }

    private func shouldContinueAfterFailure(
        category: ProxyRequestTrace.FailureCategory,
        candidate: ProxyCandidate
    ) -> Bool {
        if candidate.record.authMode.isManualAPIKey {
            return true
        }
        return category == .quota || category == .rateLimit || category == .auth
    }

    private func collectBody(from stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
        }
        return data
    }

    private func chatCompletionsAPIKeyRequest(
        config: AppConfig,
        url: String,
        headers: [String: String],
        body: Data
    ) async throws -> SimpleHTTPResponse {
        var attempt = 0
        var lastError: Error?
        while attempt <= 2 {
            do {
                let response = try await HTTPClientFactory.request(
                    config: config,
                    url: url,
                    method: .POST,
                    headers: headers,
                    body: body
                )
                guard self.shouldShortRetryChatCompletions(statusCode: response.statusCode),
                      attempt < 2
                else {
                    return response
                }
                try await self.sleepBeforeChatCompletionsRetry(
                    attempt: attempt,
                    headers: response.headers
                )
                attempt += 1
            } catch {
                lastError = error
                guard attempt < 2 else { break }
                try await self.sleepBeforeChatCompletionsRetry(attempt: attempt, headers: [:])
                attempt += 1
            }
        }
        throw lastError ?? ProxyError.message("Chat Completions upstream retry exhausted.")
    }

    private func chatCompletionsAPIKeyStream(
        config: AppConfig,
        url: String,
        headers: [String: String],
        body: Data
    ) async throws -> StreamingHTTPResponse {
        var attempt = 0
        var lastError: Error?
        while attempt <= 2 {
            do {
                let response = try await HTTPClientFactory.stream(
                    config: config,
                    url: url,
                    method: .POST,
                    headers: headers,
                    body: body
                )
                guard self.shouldShortRetryChatCompletions(statusCode: response.statusCode),
                      attempt < 2
                else {
                    return response
                }
                let failureBody = try await self.collectBody(from: response.body)
                try await self.sleepBeforeChatCompletionsRetry(
                    attempt: attempt,
                    headers: response.headers
                )
                attempt += 1
                if attempt > 2 {
                    return StreamingHTTPResponse(
                        statusCode: response.statusCode,
                        headers: response.headers,
                        body: self.singleDataStream(failureBody)
                    )
                }
            } catch {
                lastError = error
                guard attempt < 2 else { break }
                try await self.sleepBeforeChatCompletionsRetry(attempt: attempt, headers: [:])
                attempt += 1
            }
        }
        throw lastError ?? ProxyError.message("Chat Completions upstream stream retry exhausted.")
    }

    private func shouldShortRetryChatCompletions(statusCode: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(statusCode)
    }

    private func sleepBeforeChatCompletionsRetry(
        attempt: Int,
        headers: [String: String]
    ) async throws {
        let retryAfterSeconds = headers["retry-after"]
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let exponential = min(2.0, 0.3 * pow(2.0, Double(max(0, attempt))))
        let seconds = min(2.0, retryAfterSeconds ?? exponential)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func singleDataStream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            if data.isEmpty == false {
                continuation.yield(data)
            }
            continuation.finish()
        }
    }

    private func bodyData(from body: ProxyHTTPResponse.Body) async throws -> Data {
        switch body {
        case .bytes(let data):
            return data
        case .stream(let stream):
            return try await self.collectBody(from: stream)
        }
    }

    private func makeStreamingProxyResponse(
        upstreamBody: AsyncThrowingStream<Data, Error>,
        endpoint: String,
        upstreamURL: String?,
        apiKeyHash: String,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        requestedModel: String,
        actualModel: String?,
        responseMode: ResponseMode,
        geminiRequestContext: GeminiRequestContext?,
        candidate: ProxyCandidate,
        startMS: Int64,
        reasoningEffort: String? = nil,
        diagnosticRequestBodyID: Int64? = nil
    ) -> ProxyHTTPResponse {
        let accountKey = candidate.record.accountKey
        let accountLabel = candidate.record.label
        let terminalTrace = StreamTerminalTraceCoordinator()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let keepaliveState = responseMode == .anthropicMessages ? AnthropicStreamKeepaliveState() : nil
            let streamTask = Task {
                var decoder = SSEIncrementalDecoder()
                var chatStreamState = ChatStreamState()
                var anthropicStreamState = AnthropicStreamState()
                var anthropicMessagesTerminalState = AnthropicMessagesTerminalState()
                var geminiStreamState = GeminiStreamState()
                var responsesTerminalState = ResponsesStreamTerminalState()
                var rawResponsesTerminalState = ResponsesStreamTerminalState()
                var geminiTerminalState = GeminiStreamTerminalState()
                var events: [SSEEvent] = []
                func completedResponseFromEvents() -> [String: Any]? {
                    ProxyTranscoder.extractCompletedResponse(from: events)
                }
                func usageFromCompletedEvents() -> UpstreamUsage {
                    completedResponseFromEvents().map(ProxyTranscoder.usageFromCompletedResponse) ?? UpstreamUsage()
                }

                func yieldLines(_ lines: [String]) async {
                    for line in lines {
                        switch responseMode {
                        case .responses:
                            responsesTerminalState.observe(sseChunk: line)
                        case .geminiGenerateContent:
                            geminiTerminalState.observe(sseChunk: line)
                        case .anthropicMessages:
                            anthropicMessagesTerminalState.observe(sseChunk: line)
                        case .chatCompletions:
                            break
                        }
                        continuation.yield(Data(line.utf8))
                        if let keepaliveState {
                            await keepaliveState.noteDownstreamActivity()
                        }
                    }
                }

                func recordSuccess(
                    usage: UpstreamUsage = usageFromCompletedEvents(),
                    diagnostic: String? = nil
                ) async {
                    guard await terminalTrace.begin(.success) else {
                        return
                    }
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: apiKeyHash,
                            accountKey: accountKey,
                            accountLabel: accountLabel,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            reasoningEffort: reasoningEffort,
                            success: true,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            usage: usage,
                            lastError: diagnostic.map { Helpers.truncate($0) },
                            apiKeyValue: apiKeyValue
                        ),
                        diagnosticRequestBodyID: diagnosticRequestBodyID
                    )
                    try? self.noteCandidateAttemptSuccess(candidate)
                }

                func recordFailure(_ message: String) async {
                    guard await terminalTrace.begin(.failure) else {
                        return
                    }
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: apiKeyHash,
                            accountKey: accountKey,
                            accountLabel: accountLabel,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            reasoningEffort: reasoningEffort,
                            success: false,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            failureCategory: .upstream,
                            lastError: Helpers.truncate(message),
                            apiKeyValue: apiKeyValue
                        ),
                        diagnosticRequestBodyID: diagnosticRequestBodyID
                    )
                    await self.setLastError(
                        self.publicFacingCandidateFailureMessage(
                            candidate: candidate,
                            rawText: message
                        )
                    )
                    try? self.noteCandidateAttemptFailure(candidate)
                }

                func observeRawResponseEvent(_ event: SSEEvent) async {
                    let sawFailedBefore = rawResponsesTerminalState.sawFailed
                    rawResponsesTerminalState.observe(event: event)
                    guard responseMode == .responses else {
                        return
                    }
                    guard rawResponsesTerminalState.sawCompleted == false,
                          rawResponsesTerminalState.sawFailed,
                          sawFailedBefore == false
                    else {
                        return
                    }
                    let message = self.responsesStreamFailureMessage(
                        reportedError: rawResponsesTerminalState.errorMessage,
                        hadFailedEvent: true
                    )
                    await recordFailure(message)
                }

                do {
                    for try await chunk in upstreamBody {
                        for event in decoder.append(chunk) {
                            events.append(event)
                            await observeRawResponseEvent(event)
                            let lines = self.sseLines(
                                for: event,
                                responseMode: responseMode,
                                chatStreamState: &chatStreamState,
                                anthropicStreamState: &anthropicStreamState,
                                geminiStreamState: &geminiStreamState,
                                requestedModel: requestedModel,
                                geminiRequestContext: geminiRequestContext
                            )
                            await yieldLines(lines)
                        }
                    }

                    for event in decoder.finish() {
                        events.append(event)
                        await observeRawResponseEvent(event)
                        let lines = self.sseLines(
                            for: event,
                            responseMode: responseMode,
                            chatStreamState: &chatStreamState,
                            anthropicStreamState: &anthropicStreamState,
                            geminiStreamState: &geminiStreamState,
                            requestedModel: requestedModel,
                            geminiRequestContext: geminiRequestContext
                        )
                        await yieldLines(lines)
                    }

                    switch responseMode {
                    case .responses:
                        if responsesTerminalState.sawCompleted {
                            await recordSuccess()
                        } else {
                            let message = self.responsesStreamFailureMessage(
                                reportedError: rawResponsesTerminalState.errorMessage ?? responsesTerminalState.errorMessage,
                                hadFailedEvent: rawResponsesTerminalState.sawFailed || responsesTerminalState.sawFailed
                            )
                            await recordFailure(message)
                            if responsesTerminalState.sawFailed == false {
                                let failureLines = self.responsesFailureChunks(
                                    state: &responsesTerminalState,
                                    requestedModel: requestedModel,
                                    message: message
                                )
                                await yieldLines(failureLines)
                            }
                        }
                        await keepaliveState?.finish()
                        continuation.finish()
                    case .geminiGenerateContent:
                        if geminiTerminalState.sawFinishReason {
                            await recordSuccess()
                        } else {
                            let upstreamError = geminiTerminalState.upstreamError
                            let message = self.geminiStreamFailureMessage(
                                reportedError: upstreamError?.summary ?? geminiTerminalState.errorMessage,
                                hadErrorChunk: geminiTerminalState.sawError
                            )
                            await recordFailure(message)
                            if geminiTerminalState.sawError == false {
                                let failureChunk = upstreamError.map { self.geminiStreamErrorChunk(error: $0) }
                                    ?? self.geminiStreamErrorChunk(message: message)
                                await yieldLines([failureChunk])
                            }
                        }
                        await keepaliveState?.finish()
                        continuation.finish()
                    case .chatCompletions, .anthropicMessages:
                        let completedResponse = completedResponseFromEvents()
                        let usage = completedResponse.map(ProxyTranscoder.usageFromCompletedResponse) ?? UpstreamUsage()
                        let diagnostic = responseMode == .anthropicMessages
                            ? self.anthropicMessagesSuccessDiagnostic(
                                completedResponse: completedResponse,
                                terminalState: anthropicMessagesTerminalState,
                                clientSource: clientSource
                            )
                            : nil
                        if rawResponsesTerminalState.sawCompleted == false && rawResponsesTerminalState.sawFailed {
                            let message = self.responsesStreamFailureMessage(
                                reportedError: rawResponsesTerminalState.errorMessage,
                                hadFailedEvent: true
                            )
                            await recordFailure(message)
                        } else {
                            await recordSuccess(usage: usage, diagnostic: diagnostic)
                        }
                        await keepaliveState?.finish()
                        continuation.finish()
                    }
                } catch is CancellationError {
                    await keepaliveState?.finish()
                    continuation.finish()
                } catch {
                    switch responseMode {
                    case .responses:
                        if responsesTerminalState.sawCompleted {
                            await recordSuccess()
                        } else {
                            let message = self.responsesStreamFailureMessage(
                                reportedError: rawResponsesTerminalState.errorMessage
                                    ?? responsesTerminalState.errorMessage
                                    ?? error.localizedDescription,
                                hadFailedEvent: rawResponsesTerminalState.sawFailed || responsesTerminalState.sawFailed
                            )
                            await recordFailure(message)
                            if responsesTerminalState.sawFailed == false {
                                let failureLines = self.responsesFailureChunks(
                                    state: &responsesTerminalState,
                                    requestedModel: requestedModel,
                                    message: message
                                )
                                await yieldLines(failureLines)
                            }
                        }
                        await keepaliveState?.finish()
                        continuation.finish()
                    case .geminiGenerateContent:
                        if geminiTerminalState.sawFinishReason {
                            await recordSuccess()
                        } else {
                            let upstreamError = geminiTerminalState.upstreamError ?? (error as? GeminiUpstreamError)
                            let message = self.geminiStreamFailureMessage(
                                reportedError: upstreamError?.summary ?? geminiTerminalState.errorMessage ?? error.localizedDescription,
                                hadErrorChunk: geminiTerminalState.sawError
                            )
                            await recordFailure(message)
                            if geminiTerminalState.sawError == false {
                                let failureChunk = upstreamError.map { self.geminiStreamErrorChunk(error: $0) }
                                    ?? self.geminiStreamErrorChunk(message: message)
                                await yieldLines([failureChunk])
                            }
                        }
                        await keepaliveState?.finish()
                        continuation.finish()
                    case .anthropicMessages:
                        let message = self.responsesStreamFailureMessage(
                            reportedError: rawResponsesTerminalState.errorMessage ?? error.localizedDescription,
                            hadFailedEvent: rawResponsesTerminalState.sawFailed
                        )
                        await recordFailure(message)
                        await keepaliveState?.finish()
                        continuation.yield(Data(AnthropicTranscoder.errorSSEChunk(message: error.localizedDescription).utf8))
                        continuation.finish()
                    case .chatCompletions:
                        let message = self.responsesStreamFailureMessage(
                            reportedError: rawResponsesTerminalState.errorMessage ?? error.localizedDescription,
                            hadFailedEvent: rawResponsesTerminalState.sawFailed
                        )
                        await recordFailure(message)
                        await keepaliveState?.finish()
                        continuation.finish(throwing: error)
                    }
                }
            }
            let heartbeatTask: Task<Void, Never>? = if let keepaliveState {
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else {
                            break
                        }
                        if await keepaliveState.shouldEmitPing(intervalMS: 2_000) {
                            continuation.yield(Data(AnthropicTranscoder.pingSSEChunk().utf8))
                        }
                    }
                }
            } else {
                nil
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    Task {
                        guard await terminalTrace.begin(.cancelled) else {
                            return
                        }
                        _ = try? self.recordTrace(
                            ProxyRequestTrace(
                                endpoint: endpoint,
                                upstreamURL: upstreamURL,
                                apiKeyHash: apiKeyHash,
                                accountKey: accountKey,
                                accountLabel: accountLabel,
                                clientSource: clientSource,
                                model: requestedModel,
                                actualModel: actualModel,
                                reasoningEffort: reasoningEffort,
                                success: false,
                                latencyMS: Helpers.nowMilliseconds() - startMS,
                                failureCategory: .cancelled,
                                lastError: Helpers.truncate(self.cancelledStreamFailureMessage()),
                                apiKeyValue: apiKeyValue
                            )
                        )
                    }
                }
                streamTask.cancel()
                heartbeatTask?.cancel()
                if let keepaliveState {
                    Task {
                        await keepaliveState.finish()
                    }
                }
            }
        }
        return ProxyHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache"],
            body: .stream(stream)
        )
    }

    private func makeGeminiPassthroughStreamingResponse(
        upstreamBody: AsyncThrowingStream<Data, Error>,
        statusCode: Int,
        headers: [String: String],
        endpoint: String,
        upstreamURL: String?,
        apiKeyHash: String,
        apiKeyValue: String,
        clientSource: RequestLogClientSource,
        requestedModel: String,
        actualModel: String,
        candidate: ProxyCandidate,
        startMS: Int64,
        promptCacheContext: PromptCacheContext
    ) -> ProxyHTTPResponse {
        let accountKey = candidate.record.accountKey
        let accountLabel = candidate.record.label
        let contentType = headers["content-type"] ?? "text/event-stream; charset=utf-8"
        let terminalTrace = StreamTerminalTraceCoordinator()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var decoder = SSEIncrementalDecoder()
                var terminalState = GeminiStreamTerminalState()
                var usage = UpstreamUsage()

                func emit(_ payload: [String: Any]) async {
                    let chunk = self.geminiSSEData(payload)
                    continuation.yield(Data(chunk.utf8))
                    let sawErrorBefore = terminalState.sawError
                    terminalState.observe(sseChunk: chunk)
                    if let updatedUsage = self.geminiUsageIfPresent(from: payload)
                    {
                        usage = updatedUsage
                    }
                    guard terminalState.sawFinishReason == false,
                          terminalState.sawError,
                          sawErrorBefore == false
                    else {
                        return
                    }
                    let message = self.geminiStreamFailureMessage(
                        reportedError: terminalState.upstreamError?.summary ?? terminalState.errorMessage,
                        hadErrorChunk: true
                    )
                    await recordFailure(message)
                }

                func recordSuccess() async {
                    guard await terminalTrace.begin(.success) else {
                        return
                    }
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: apiKeyHash,
                            accountKey: accountKey,
                            accountLabel: accountLabel,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: true,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            usage: usage,
                            apiKeyValue: apiKeyValue
                        )
                    )
                    try? self.noteCandidateAttemptSuccess(candidate)
                    await self.bindStickySessionIfNeeded(candidate: candidate, context: promptCacheContext)
                }

                func recordFailure(_ message: String) async {
                    guard await terminalTrace.begin(.failure) else {
                        return
                    }
                    _ = try? self.recordTrace(
                        ProxyRequestTrace(
                            endpoint: endpoint,
                            upstreamURL: upstreamURL,
                            apiKeyHash: apiKeyHash,
                            accountKey: accountKey,
                            accountLabel: accountLabel,
                            clientSource: clientSource,
                            model: requestedModel,
                            actualModel: actualModel,
                            success: false,
                            latencyMS: Helpers.nowMilliseconds() - startMS,
                            failureCategory: .upstream,
                            lastError: Helpers.truncate(message),
                            apiKeyValue: apiKeyValue
                        )
                    )
                    await self.setLastError(
                        self.publicFacingCandidateFailureMessage(
                            candidate: candidate,
                            rawText: message
                        )
                    )
                    try? self.noteCandidateAttemptFailure(candidate)
                }

                do {
                    for try await chunk in upstreamBody {
                        for event in decoder.append(chunk) {
                            for payload in self.geminiForwardedSSEPayloads(from: event) {
                                await emit(payload)
                            }
                        }
                    }
                    for event in decoder.finish() {
                        for payload in self.geminiForwardedSSEPayloads(from: event) {
                            await emit(payload)
                        }
                    }

                    if terminalState.sawFinishReason {
                        await recordSuccess()
                    } else {
                        let upstreamError = terminalState.upstreamError
                        let message = self.geminiStreamFailureMessage(
                            reportedError: upstreamError?.summary ?? terminalState.errorMessage,
                            hadErrorChunk: terminalState.sawError
                        )
                        await recordFailure(message)
                        if terminalState.sawError == false {
                            let failureChunk = upstreamError.map { self.geminiStreamErrorChunk(error: $0) }
                                ?? self.geminiStreamErrorChunk(message: message)
                            continuation.yield(Data(failureChunk.utf8))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if terminalState.sawFinishReason {
                        await recordSuccess()
                    } else {
                        let upstreamError = terminalState.upstreamError ?? (error as? GeminiUpstreamError)
                        let message = self.geminiStreamFailureMessage(
                            reportedError: upstreamError?.summary ?? terminalState.errorMessage ?? error.localizedDescription,
                            hadErrorChunk: terminalState.sawError
                        )
                        await recordFailure(message)
                        if terminalState.sawError == false {
                            let failureChunk = upstreamError.map { self.geminiStreamErrorChunk(error: $0) }
                                ?? self.geminiStreamErrorChunk(message: message)
                            continuation.yield(Data(failureChunk.utf8))
                        }
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    Task {
                        guard await terminalTrace.begin(.cancelled) else {
                            return
                        }
                        _ = try? self.recordTrace(
                            ProxyRequestTrace(
                                endpoint: endpoint,
                                upstreamURL: upstreamURL,
                                apiKeyHash: apiKeyHash,
                                accountKey: accountKey,
                                accountLabel: accountLabel,
                                clientSource: clientSource,
                                model: requestedModel,
                                actualModel: actualModel,
                                success: false,
                                latencyMS: Helpers.nowMilliseconds() - startMS,
                                failureCategory: .cancelled,
                                lastError: Helpers.truncate(self.cancelledStreamFailureMessage()),
                                apiKeyValue: apiKeyValue
                            )
                        )
                    }
                }
                task.cancel()
            }
        }
        return ProxyHTTPResponse(
            statusCode: statusCode,
            headers: [
                "content-type": contentType,
                "cache-control": headers["cache-control"] ?? "no-cache",
            ],
            body: .stream(stream)
        )
    }

    private func geminiUsage(from object: [String: Any]) -> UpstreamUsage {
        self.geminiUsageIfPresent(from: object) ?? UpstreamUsage()
    }

    private func geminiUsageIfPresent(from object: [String: Any]) -> UpstreamUsage? {
        if let response = object["response"] as? [String: Any] {
            return self.geminiUsageIfPresent(from: response)
        }
        if let metadata = object["usageMetadata"] as? [String: Any]
            ?? object["usage_metadata"] as? [String: Any]
        {
            let inputTokens = self.int64Value(metadata["promptTokenCount"] ?? metadata["prompt_token_count"]) ?? 0
            let outputTokens = self.int64Value(metadata["candidatesTokenCount"] ?? metadata["candidates_token_count"]) ?? 0
            let totalTokens = self.int64Value(metadata["totalTokenCount"] ?? metadata["total_token_count"])
                ?? (inputTokens + outputTokens)
            let cacheHitTokens = self.int64Value(metadata["cachedContentTokenCount"] ?? metadata["cached_content_token_count"])
            return UpstreamUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens,
                cacheHitTokens: cacheHitTokens
            )
        }
        if let totalTokens = self.int64Value(object["totalTokens"] ?? object["total_tokens"]) {
            return UpstreamUsage(
                inputTokens: totalTokens,
                outputTokens: 0,
                totalTokens: totalTokens,
                cacheHitTokens: self.int64Value(object["cachedContentTokenCount"] ?? object["cached_content_token_count"])
            )
        }
        return nil
    }

    private func geminiForwardedSSEPayloads(from event: SSEEvent) -> [[String: Any]] {
        guard let object = ProxyTranscoder.jsonObject(from: event) else {
            return []
        }
        if let response = object["response"] as? [String: Any] {
            return response.isEmpty ? [] : [response]
        }
        return [object]
    }

    private func geminiSSEData(_ payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    private func openAICompatibleMissingUsageDiagnostic(adapter: OpenAIUpstreamAdapter) -> String {
        "OpenAI-compatible upstream \(adapter.diagnosticLabel) response completed without recognizable usage fields; request tokens were recorded as 0."
    }

    private func isProxyTestConsoleRequest(headers: [String: String]) -> Bool {
        let marker = headers[ProxyHeaderName.proxyTestConsole]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return marker.isEmpty == false
    }

    private func anthropicMessagesPrematureEndDiagnostic(clientSource: RequestLogClientSource) -> String {
        let clientLabel = clientSource == .claudeCode ? "Claude Code" : "The Anthropic-compatible client"
        return "Upstream stream ended before `response.completed` produced a terminal Anthropic `message_stop`; request tokens were recorded as 0 and \(clientLabel) may appear to stop early."
    }

    private func anthropicMessagesMissingUsageDiagnostic() -> String {
        "OpenAI-compatible upstream completed the Claude-compatible stream without recognizable usage fields; request tokens were recorded as 0."
    }

    private func anthropicMessagesSuccessDiagnostic(
        completedResponse: [String: Any]?,
        terminalState: AnthropicMessagesTerminalState,
        clientSource: RequestLogClientSource
    ) -> String? {
        guard terminalState.sawMessageStop else {
            return self.anthropicMessagesPrematureEndDiagnostic(clientSource: clientSource)
        }
        guard let completedResponse else {
            return self.anthropicMessagesPrematureEndDiagnostic(clientSource: clientSource)
        }
        guard ProxyTranscoder.hasRecognizableUsage(in: completedResponse) == false else {
            return nil
        }
        return self.anthropicMessagesMissingUsageDiagnostic()
    }

    private func responsesFailureChunks(
        state: inout ResponsesStreamTerminalState,
        requestedModel: String,
        message: String
    ) -> [String] {
        let identity = state.ensureSyntheticIdentity()
        var chunks: [String] = []
        if state.sawCreated == false {
            chunks.append(
                ProxyTranscoder.responseCreatedSSEChunk(
                    responseID: identity.responseID,
                    createdAt: identity.createdAt,
                    requestedModel: requestedModel
                )
            )
        }
        chunks.append(
            ProxyTranscoder.responseFailedSSEChunk(
                responseID: identity.responseID,
                createdAt: identity.createdAt,
                requestedModel: requestedModel,
                message: message
            )
        )
        return chunks
    }

    private func responsesStreamFailureMessage(
        reportedError: String?,
        hadFailedEvent: Bool
    ) -> String {
        let base = hadFailedEvent
            ? "Upstream stream returned response.failed."
            : "Upstream stream terminated before response.completed was received."
        return self.normalizedStreamFailureMessage(
            base: base,
            reportedError: reportedError,
            endReason: self.streamEndReason(
                reportedError: reportedError,
                protocolFailed: hadFailedEvent
            )
        )
    }

    private func geminiStreamFailureMessage(
        reportedError: String?,
        hadErrorChunk: Bool
    ) -> String {
        let endReason = self.streamEndReason(
            reportedError: reportedError,
            protocolFailed: hadErrorChunk
        )
        if let rawCause = self.normalizedStreamRawCause(reportedError),
           rawCause.localizedCaseInsensitiveContains("Gemini upstream error")
        {
            return "\(rawCause). Stream end reason: \(endReason.rawValue)."
        }

        let base = hadErrorChunk
            ? "Upstream Gemini stream returned an error chunk before a final finishReason was received."
            : "Upstream Gemini stream terminated before a final finishReason was received."
        return self.normalizedStreamFailureMessage(
            base: base,
            reportedError: reportedError,
            endReason: endReason
        )
    }

    private func normalizedStreamFailureMessage(
        base: String,
        reportedError: String?,
        endReason: StreamEndReason
    ) -> String {
        var message = "\(base) Stream end reason: \(endReason.rawValue)."
        guard let rawCause = self.normalizedStreamRawCause(reportedError) else {
            return message
        }
        guard rawCause.caseInsensitiveCompare(base) != .orderedSame else {
            return message
        }
        message += " Raw upstream error: \(rawCause)"
        return message
    }

    private func streamEndReason(
        reportedError: String?,
        protocolFailed: Bool
    ) -> StreamEndReason {
        if protocolFailed {
            return .protocolFailed
        }

        let trimmed = reportedError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else {
            return .prematureEOF
        }

        let lower = trimmed.lowercased()
        if lower.contains("cancel") {
            return .clientCancelled
        }
        if lower.contains("broken pipe") || lower.contains("writer") {
            return .writerError
        }
        if lower.contains("premature eof") || lower.contains("httpparsererror") {
            return .prematureEOF
        }
        return .scannerError
    }

    private func normalizedStreamRawCause(_ reportedError: String?) -> String? {
        let trimmed = reportedError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }

        let lower = trimmed.lowercased()
        if lower == "terminated" {
            return "terminated"
        }
        if lower.contains("premature eof") || lower.contains("httpparsererror") {
            return "premature EOF"
        }
        if lower.contains("connection reset by peer") {
            return "connection reset by peer"
        }
        return Helpers.truncate(trimmed)
    }

    private func cancelledStreamFailureMessage() -> String {
        "Downstream client cancelled the streaming request. Stream end reason: \(StreamEndReason.clientCancelled.rawValue)."
    }

    private func geminiStreamErrorChunk(error: GeminiUpstreamError) -> String {
        let data = error.responseData
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    private func geminiStreamErrorChunk(message: String) -> String {
        let lower = message.lowercased()
        let metadata: (status: Int, statusText: String)
        if HTTPErrorClassifier.containsAuthSignal(message) || lower.contains("missing proxy api key") {
            metadata = (401, "UNAUTHENTICATED")
        } else if HTTPErrorClassifier.containsRateLimitSignal(message) {
            metadata = (429, "RESOURCE_EXHAUSTED")
        } else if HTTPErrorClassifier.containsQuotaSignal(message) || lower.contains("unsupported_country_region_territory") {
            metadata = (403, "PERMISSION_DENIED")
        } else if lower.contains("unsupported gemini")
            || lower.contains("missing `")
            || lower.contains("$.")
            || lower.contains("gemini request")
            || lower.contains("candidatecount")
        {
            metadata = (400, "INVALID_ARGUMENT")
        } else {
            metadata = (500, "INTERNAL")
        }

        return GeminiTranscoder.errorSSEChunk(
            status: metadata.status,
            message: message,
            statusText: metadata.statusText
        )
    }

    private func sseLines(
        for event: SSEEvent,
        responseMode: ResponseMode,
        chatStreamState: inout ChatStreamState,
        anthropicStreamState: inout AnthropicStreamState,
        geminiStreamState: inout GeminiStreamState,
        requestedModel: String,
        geminiRequestContext: GeminiRequestContext?
    ) -> [String] {
        switch responseMode {
        case .chatCompletions:
            return ProxyTranscoder.chatCompletionSSEChunks(from: event, streamState: &chatStreamState, requestedModel: requestedModel)
        case .responses:
            return ProxyTranscoder.responsesSSEChunks(from: event)
        case .anthropicMessages:
            if anthropicStreamState.messageID.isEmpty {
                anthropicStreamState.messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            }
            return AnthropicTranscoder.messagesSSEChunks(
                from: event,
                streamState: &anthropicStreamState,
                requestedModel: requestedModel
            )
        case .geminiGenerateContent:
            return GeminiTranscoder.streamGenerateContentSSEChunks(
                from: event,
                state: &geminiStreamState,
                requestedModel: requestedModel,
                context: geminiRequestContext ?? .default(sourceModel: requestedModel)
            )
        }
    }

    private func setActive(_ candidate: ProxyCandidate) async {
        await self.runtimeState.setActive(accountKey: candidate.record.accountKey, accountID: candidate.record.accountID, label: candidate.record.label)
    }

    private func setLastError(_ error: String?) async {
        await self.runtimeState.setLastError(error)
    }

    private func logOAuthEvent(_ message: String) {
        print("[oauth] \(message)")
    }

    private func configWithDefaultProxyAPIKeys(_ config: AppConfig) throws -> AppConfig {
        guard config.proxyAPIKeys.isEmpty else {
            return config
        }

        let trimmedLegacyProxyKey = config.proxyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let seedKey = trimmedLegacyProxyKey.isEmpty
            ? try self.secretStore.proxyAPIKey()
            : config.proxyAPIKey
        var copy = config
        copy.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                label: AppConfig.defaultProxyAPIKeyLabel,
                key: seedKey,
                dataSource: trimmedLegacyProxyKey.isEmpty ? .all : .openAI,
                enabled: true
            ),
        ]
        copy.primaryProxyAPIKeyID = copy.proxyAPIKeys.first?.id
        copy.proxyAPIKey = seedKey
        return copy
    }

    private func configWithManagedProxySummary(_ config: AppConfig) throws -> AppConfig {
        var copy = config
        let subscriptionConfigured = try self.secretStore.mihomoSubscriptionURL() != nil
        copy.managedProxySummary = ManagedProxyConfigSummary(
            subscriptionConfigured: subscriptionConfigured,
            selectedNodeName: copy.managedProxySummary.selectedNodeName,
            providerName: copy.managedProxySummary.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ManagedProxyConfigSummary.defaultProviderName
                : copy.managedProxySummary.providerName,
            autoUpdateIntervalHours: max(1, copy.managedProxySummary.autoUpdateIntervalHours),
            healthcheckURL: ManagedProxyConfigSummary.sanitizedHealthcheckURL(copy.managedProxySummary.healthcheckURL)
        )
        return copy
    }

    @discardableResult
    private func ensureAnthropicAccessProxyKeyIfNeeded() throws -> Bool {
        let accounts = try self.store.listAccountRecords()
        guard accounts.contains(where: { $0.enabled && $0.providerFamily == .anthropic }) else {
            return false
        }

        let config = try self.configWithDefaultProxyAPIKeys(try self.store.loadConfig()).normalizedModelRoutingConfig()
        let matchingSources: Set<ProxyDataSource> = [.anthropic, .all]
        let hasEnabledMatchingKey = config.proxyAPIKeys.contains { record in
            record.enabled && matchingSources.contains(record.dataSource)
        }
        guard hasEnabledMatchingKey == false else {
            return false
        }

        // If the user already has Anthropic-capable keys but disabled them, preserve that intent.
        let hasConfiguredMatchingKey = config.proxyAPIKeys.contains { record in
            matchingSources.contains(record.dataSource)
        }
        guard hasConfiguredMatchingKey == false else {
            return false
        }

        var updated = config
        updated.proxyAPIKeys.append(
            ProxyAPIKeyRecord(
                label: AppConfig.defaultAnthropicAccessProxyAPIKeyLabel,
                key: self.generatedUniqueProxyAPIKey(existingKeys: Set(updated.proxyAPIKeys.map(\.key))),
                dataSource: .anthropic,
                enabled: true
            )
        )
        try self.store.saveConfig(updated.normalizedModelRoutingConfig())
        return true
    }

    private func generatedUniqueProxyAPIKey(existingKeys: Set<String>) -> String {
        var candidate = AppConfig.generatedProxyAPIKey()
        while existingKeys.contains(candidate) {
            candidate = AppConfig.generatedProxyAPIKey()
        }
        return candidate
    }

    private func loadConfigForNetworkRequests() async throws -> AppConfig {
        try await self.withNetworkConfig { $0 }
    }

    private func withNetworkConfig<T: Sendable>(
        for accountRecord: AccountRecord? = nil,
        operation: @escaping (AppConfig) async throws -> T
    ) async throws -> T {
        do {
            let config = try await self.loadConfig()
            if let accountRecord,
               let preferredNodeName = AccountSummary.normalizedManagedProxyNodeName(accountRecord.managedProxyNodeName)
            {
                guard let managedProxyRuntime else {
                    throw ProxyError.message(
                        self.accountManagedProxyNodeResolutionFailureMessage(
                            label: accountRecord.label,
                            nodeName: preferredNodeName,
                            detail: "订阅代理不可用：请先启动本地服务。"
                        )
                    )
                }

                let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
                var requestConfig = config
                do {
                    requestConfig.outboundProxy = try await managedProxyRuntime.effectiveProxySettingsForAccountNode(
                        name: preferredNodeName,
                        config: requestConfig,
                        subscriptionURL: subscriptionURL
                    )
                } catch let error as ManagedProxyAccountNodeResolutionError {
                    switch error {
                    case .nodeUnavailable(let nodeName):
                        throw ProxyError.message(
                            self.accountManagedProxyNodeUnavailableMessage(
                                label: accountRecord.label,
                                nodeName: nodeName
                            )
                        )
                    case .listenerUnavailable(let nodeName):
                        throw ProxyError.message(
                            self.accountManagedProxyNodeListenerUnavailableMessage(
                                label: accountRecord.label,
                                nodeName: nodeName
                            )
                        )
                    }
                } catch {
                    throw ProxyError.message(
                        self.accountManagedProxyNodeResolutionFailureMessage(
                            label: accountRecord.label,
                            nodeName: preferredNodeName,
                            detail: error.localizedDescription
                        )
                    )
                }
                return try await operation(requestConfig)
            }

            switch config.outboundProxyMode {
            case .disabled:
                var directConfig = config
                directConfig.outboundProxy = .init()
                return try await operation(directConfig)
            case .manual:
                return try await operation(config)
            case .subscription:
                guard let managedProxyRuntime else {
                    throw ProxyError.message("订阅代理不可用：请先启动本地服务。")
                }
                let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
                var requestConfig = config
                requestConfig.outboundProxy = try await managedProxyRuntime.effectiveProxySettings(
                    config: requestConfig,
                    subscriptionURL: subscriptionURL
                )
                return try await operation(requestConfig)
            }
        } catch {
            await self.setLastError(error.localizedDescription)
            throw error
        }
    }

    private func withManagedProxyNodeCoordinator<T: Sendable>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        await self.managedProxyNodeCoordinator.acquire()
        do {
            let result = try await operation()
            await self.managedProxyNodeCoordinator.release()
            return result
        } catch {
            await self.managedProxyNodeCoordinator.release()
            throw error
        }
    }

    private func validateManagedProxyNodeSelection(_ nodeName: String) async throws {
        let snapshot = try await self.managedProxySnapshot()
        guard snapshot.nodes.contains(where: { $0.name == nodeName }) else {
            throw ProxyError.message("未找到要绑定的订阅节点：\(nodeName)")
        }
    }

    private func accountManagedProxyNodeUnavailableMessage(label: String, nodeName: String) -> String {
        "\(label)：自定义的出站节点当前不可用：\(nodeName)"
    }

    private func accountManagedProxyNodeListenerUnavailableMessage(label: String, nodeName: String) -> String {
        "\(label)：自定义的出站节点监听端口不可用：\(nodeName)"
    }

    private func accountManagedProxyNodeResolutionFailureMessage(
        label: String,
        nodeName: String,
        detail: String
    ) -> String {
        "\(label)：自定义的出站节点 \(nodeName) 当前无法生效，\(detail)"
    }

    private func syncManagedProxyRuntime(for config: AppConfig) async throws {
        guard let managedProxyRuntime, self.manageManagedProxyRuntime else {
            return
        }
        let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
        let nodeNames = try self.enabledManagedProxyAccountNodeNames()
        try await self.withManagedProxyNodeCoordinator {
            try await managedProxyRuntime.reconcileAccountNodeListeners(
                nodeNames: nodeNames,
                config: config,
                subscriptionURL: subscriptionURL
            )
        }
    }

    private func reconcileManagedProxyAccountNodeListeners(config: AppConfig? = nil) async throws {
        guard let managedProxyRuntime, self.manageManagedProxyRuntime else {
            return
        }
        let resolvedConfig: AppConfig
        if let config {
            resolvedConfig = config
        } else {
            resolvedConfig = try await self.loadConfig()
        }
        let nodeNames = try self.enabledManagedProxyAccountNodeNames()
        let subscriptionURL = try self.secretStore.mihomoSubscriptionURL()
        try await self.withManagedProxyNodeCoordinator {
            try await managedProxyRuntime.reconcileAccountNodeListeners(
                nodeNames: nodeNames,
                config: resolvedConfig,
                subscriptionURL: subscriptionURL
            )
        }
    }

    private func enabledManagedProxyAccountNodeNames() throws -> [String] {
        let accounts = try self.store.listAccountRecords()
        var seen = Set<String>()
        return accounts.compactMap { record in
            guard record.enabled,
                  let nodeName = AccountSummary.normalizedManagedProxyNodeName(record.managedProxyNodeName),
                  seen.insert(nodeName).inserted else {
                return nil
            }
            return nodeName
        }
        .sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func importBootstrapAccountsIfNeeded(config: AppConfig) async throws {
        let bootstrapURL = Paths.bootstrapAccountsURL(in: self.dataDirectory)
        guard FileManager.default.fileExists(atPath: bootstrapURL.path) else { return }
        let content = try String(contentsOf: bootstrapURL, encoding: .utf8)
        _ = try await self.accountService.importAuthJSONAccounts(items: [.init(source: bootstrapURL.lastPathComponent, content: content)], config: config)
        try self.ensureAnthropicAccessProxyKeyIfNeeded()
        try? FileManager.default.removeItem(at: bootstrapURL)
    }

    private func importBootstrapSettingsIfNeeded() async throws {
        let bootstrapURL = Paths.bootstrapSettingsURL(in: self.dataDirectory)
        guard FileManager.default.fileExists(atPath: bootstrapURL.path) else { return }
        let data = try Data(contentsOf: bootstrapURL)
        let config = try Helpers.readJSON(AppConfig.self, from: data)
        try self.store.saveConfig(config.normalizedModelRoutingConfig())
        try? FileManager.default.removeItem(at: bootstrapURL)
    }

    private func persistConfigSecretMirrors(for config: AppConfig) throws {
        let adminToken = config.adminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !adminToken.isEmpty {
            try self.secretStore.persistMirroredAdminToken(adminToken)
        }

        let primaryProxyKey = (config.primaryProxyAPIKeyRecord?.key ?? config.proxyAPIKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !primaryProxyKey.isEmpty {
            try self.secretStore.persistMirroredProxyAPIKey(primaryProxyKey)
        }
    }

    private enum ResponseMode {
        case chatCompletions
        case responses
        case anthropicMessages
        case geminiGenerateContent
    }

    private struct ProxyCandidate: Sendable {
        var record: AccountRecord
        var auth: ExtractedAuth
    }

    private struct ChatGPTWebImageSessionContext: Sendable {
        var userAgent = OpenAIImagesProxySupport.chatGPTWebDefaultUserAgent
        var deviceID = UUID().uuidString.lowercased()
        var sessionID = UUID().uuidString.lowercased()
        var secChUa = #""Microsoft Edge";v="143", "Chromium";v="143", "Not A(Brand";v="24""#
        var secChUaMobile = "?0"
        var secChUaPlatform = #""Windows""#
        var clientVersion = OpenAIImagesProxySupport.chatGPTWebDefaultClientVersion
        var clientBuildNumber = OpenAIImagesProxySupport.chatGPTWebDefaultClientBuildNumber
        var powResources = ChatGPTWebPOWResources(
            scriptSources: [OpenAIImagesProxySupport.chatGPTWebDefaultPOWScript],
            dataBuild: ""
        )
    }

    private struct ChatGPTWebImageBinary: Sendable {
        var data: Data
        var mimeType: String
        var fileName: String
        var width: Int
        var height: Int
    }

    private struct ChatGPTWebUploadedImageReference: Sendable {
        var fileID: String
        var fileName: String
        var fileSize: Int
        var mimeType: String
        var width: Int
        var height: Int

        var payload: [String: Any] {
            [
                "file_id": self.fileID,
                "file_name": self.fileName,
                "file_size": self.fileSize,
                "mime_type": self.mimeType,
                "width": self.width,
                "height": self.height,
            ]
        }
    }

    private struct ChatGPTWebImageFailure: Error {
        var statusCode: Int
        var bodyText: String
        var upstreamURL: String
        var shouldContinueOverride: Bool?

        init(
            statusCode: Int,
            bodyText: String,
            upstreamURL: String,
            shouldContinueOverride: Bool? = nil
        ) {
            self.statusCode = statusCode
            self.bodyText = bodyText
            self.upstreamURL = upstreamURL
            self.shouldContinueOverride = shouldContinueOverride
        }
    }

    private func refreshedCandidateAuthIfNeeded(_ candidate: ProxyCandidate) async throws -> ProxyCandidate {
        try await self.withNetworkConfig(for: candidate.record) { config in
            var refreshedCandidate = candidate
            try await self.refreshCandidateAuthIfNeeded(&refreshedCandidate, config: config)
            return refreshedCandidate
        }
    }

    private func refreshCandidateAuthIfNeeded(
        _ candidate: inout ProxyCandidate,
        config: AppConfig
    ) async throws {
        guard AuthService.authNeedsRefresh(candidate.record.authJSON, secretStore: self.secretStore) else {
            return
        }
        guard !candidate.record.authRefreshBlocked else {
            return
        }

        let refreshed = try await AuthService.refreshAuth(
            candidate.record.authJSON,
            config: config,
            secretStore: self.secretStore
        )
        candidate.record.authJSON = refreshed
        try self.store.updateUsage(
            accountKey: candidate.record.accountKey,
            usage: candidate.record.usage,
            usageError: candidate.record.usageError,
            planType: candidate.record.effectivePlanType,
            authJSON: refreshed,
            usageWindowsVisible: nil,
            authRefreshBlocked: false,
            authRefreshError: nil
        )
        candidate.auth = try AuthService.extractAuth(from: refreshed, secretStore: self.secretStore)
    }

    private func completedResponse(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["output"] != nil
        {
            return object
        }
        let events = ProxyTranscoder.decodeSSE(data)
        return ProxyTranscoder.extractCompletedResponse(from: events)
    }

    private func anthropicResponseHeaders(
        version: String,
        beta: String?,
        contentType: String
    ) -> [String: String] {
        var headers: [String: String] = [
            "content-type": contentType,
            "anthropic-version": version,
        ]
        if let beta, !beta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["anthropic-beta"] = beta
        }
        return headers
    }

    private static func anthropicBaseURL(from publicBaseURL: String) -> String {
        guard let url = URL(string: publicBaseURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return publicBaseURL.replacingOccurrences(of: "/v1", with: "")
        }

        if components.path.hasPrefix("/v1") {
            components.path = String(components.path.dropFirst(3))
        }
        return components.string ?? publicBaseURL.replacingOccurrences(of: "/v1", with: "")
    }

    private static func geminiBaseURL(from publicBaseURL: String) -> String {
        self.anthropicBaseURL(from: publicBaseURL)
    }
}
