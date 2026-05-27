#if os(macOS)
import CodexProxyCore
import Foundation

@MainActor
final class AdminAPIClient {
    struct Capabilities: Sendable, Equatable {
        var supportsOAuth = true
        var supportsImportCurrent = true
        var supportsProxyTesting = true
        var supportsWebsiteProbes = true
        var supportsOnboarding = true
        var supportsManagedProxyRemoteLogs = false
        var allowsLocalFallback = true

        static let local = Self()

        static let remoteTunnel = Self(
            supportsOAuth: false,
            supportsImportCurrent: false,
            supportsProxyTesting: true,
            supportsWebsiteProbes: false,
            supportsOnboarding: false,
            supportsManagedProxyRemoteLogs: true,
            allowsLocalFallback: false
        )
    }

    struct RemoteTargetConfiguration {
        var adminBaseURLProvider: @Sendable () async throws -> URL
        var tokenProvider: @Sendable () async throws -> String
        var reconnectHandler: (@Sendable () async throws -> Void)?
        var capabilities: Capabilities

        init(
            adminBaseURLProvider: @escaping @Sendable () async throws -> URL,
            tokenProvider: @escaping @Sendable () async throws -> String,
            reconnectHandler: (@Sendable () async throws -> Void)? = nil,
            capabilities: Capabilities = .remoteTunnel
        ) {
            self.adminBaseURLProvider = adminBaseURLProvider
            self.tokenProvider = tokenProvider
            self.reconnectHandler = reconnectHandler
            self.capabilities = capabilities
        }
    }

    enum Target {
        case local(dataDirectory: URL, capabilities: Capabilities = .local)
        case remote(RemoteTargetConfiguration)

        var capabilities: Capabilities {
            switch self {
            case .local(_, let capabilities):
                return capabilities
            case .remote(let configuration):
                return configuration.capabilities
            }
        }

        var allowsLocalFallback: Bool {
            self.capabilities.allowsLocalFallback
        }
    }

    typealias AccountsHandler = @Sendable () async throws -> [AccountSummary]
    typealias ImportCurrentAuthHandler = @Sendable (String?) async throws -> AccountSummary
    typealias ImportAuthJSONItemsHandler = @Sendable ([AuthJsonImportInput]) async throws -> ImportAccountsResult
    typealias ExportAccountsHandler = @Sendable () async throws -> Data
    typealias PrepareOAuthHandler = @Sendable (AccountProviderFamily) async throws -> PreparedOAuthLogin
    typealias CompleteOAuthCallbackHandler = @Sendable (AccountProviderFamily, String) async throws -> AccountSummary
    typealias RequestLogsHandler = @Sendable (RequestLogQuery) async throws -> RequestLogPage
    typealias RequestLogFiltersHandler = @Sendable (RequestLogQuery) async throws -> RequestLogFilterOptions
    typealias RequestLogsExportHandler = @Sendable (RequestLogQuery) async throws -> Data
    typealias ReasoningCacheSummaryHandler = @Sendable () async throws -> ReasoningCacheSummary
    typealias ClearReasoningCacheHandler = @Sendable (ClearReasoningCacheRequest) async throws -> ClearReasoningCacheResult
    typealias OCRCacheSummaryHandler = @Sendable () async throws -> OCRCacheSummary
    typealias ClearOCRCacheHandler = @Sendable (ClearOCRCacheRequest) async throws -> ClearOCRCacheResult
    typealias OCRRecognitionLogsHandler = @Sendable (OCRRecognitionLogListRequest) async throws -> OCRRecognitionLogListResponse
    typealias OCRRecognitionResultHandler = @Sendable (Int64) async throws -> OCRRecognitionResultLookupResponse
    typealias DiagnosticRequestBodySummaryHandler = @Sendable () async throws -> DiagnosticRequestBodySummary
    typealias DiagnosticRequestBodiesHandler = @Sendable (Int64?) async throws -> [DiagnosticRequestBodyEntry]
    typealias DiagnosticRequestBodyDetailHandler = @Sendable (Int64) async throws -> DiagnosticRequestBodyDetail
    typealias ClearDiagnosticRequestBodiesHandler = @Sendable (ClearDiagnosticRequestBodiesRequest) async throws -> ClearDiagnosticRequestBodiesResult
    typealias GetStatusHandler = @Sendable () async throws -> ProxyStatus
    typealias GetStatsHandler = @Sendable () async throws -> AdminStatsSummary
    typealias GetStatsForAPIKeyHandler = @Sendable (String?) async throws -> AdminStatsSummary
    typealias AdminEventsHandler = @Sendable () async throws -> AsyncThrowingStream<AdminEvent, Error>
    typealias SaveSettingsHandler = @Sendable (AppConfig) async throws -> AppConfig
    typealias GetSettingsHandler = @Sendable () async throws -> AppConfig
    typealias GetManagedProxySnapshotHandler = @Sendable () async throws -> ManagedProxySnapshot
    typealias SaveManagedProxyConfigHandler = @Sendable (ManagedProxyConfigPayload) async throws -> ManagedProxySnapshot
    typealias SaveManagedProxyHealthcheckConfigHandler = @Sendable (ManagedProxyHealthcheckConfigPayload) async throws -> ManagedProxySnapshot
    typealias UpdateManagedProxySubscriptionHandler = @Sendable () async throws -> ManagedProxySnapshot
    typealias SelectManagedProxyNodeHandler = @Sendable (ManagedProxySelectRequest) async throws -> ManagedProxySnapshot
    typealias SwitchManagedProxyCurrentNodeHandler = @Sendable (ManagedProxySwitchCurrentRequest) async throws -> ManagedProxySnapshot
    typealias UpdateManagedProxyPinnedNodeHandler = @Sendable (ManagedProxyPinnedNodeRequest) async throws -> ManagedProxySnapshot
    typealias HealthcheckManagedProxyHandler = @Sendable (ManagedProxyHealthcheckRequest) async throws -> ManagedProxySnapshot
    typealias ProxyAPIKeyUsageHandler = @Sendable (RequestLogQuery) async throws -> ProxyAPIKeyUsageReport
    typealias ManualAPIKeyAccountDetailsHandler = @Sendable (String) async throws -> ManualAPIKeyAccountDetails
    typealias UpdateManualAPIKeyAccountHandler = @Sendable (String, UpdateManualAPIKeyAccountRequest) async throws -> AccountSummary
    typealias RefreshUsageHandler = @Sendable () async throws -> [AccountSummary]
    typealias RefreshAccountUsageHandler = @Sendable (String) async throws -> AccountSummary
    typealias StopAccountCooldownHandler = @Sendable (String) async throws -> AccountSummary
    typealias UpdateAccountCooldownPolicyHandler = @Sendable (String, UpdateAccountCooldownPolicyRequest) async throws -> AccountSummary
    typealias UpdateAccountLabelHandler = @Sendable (String, UpdateAccountLabelRequest) async throws -> AccountSummary
    typealias UpdateAccountManagedProxyNodeHandler = @Sendable (String, UpdateAccountManagedProxyNodeRequest) async throws -> AccountSummary
    typealias ClearAccountManagedProxyNodesHandler = @Sendable () async throws -> ClearAccountManagedProxyNodesResult
    typealias UpdateAccountModelRoutingHandler = @Sendable (String, UpdateAccountModelRoutingRequest) async throws -> AccountSummary
    typealias UpdateAccountReasoningEffortHandler = @Sendable (String, UpdateAccountReasoningEffortRequest) async throws -> AccountSummary
    typealias UpdateAccountOrderHandler = @Sendable (UpdateAccountOrderRequest) async throws -> [AccountSummary]
    typealias BatchRemoveAccountsHandler = @Sendable (BatchDeleteAccountsRequest) async throws -> BatchDeleteAccountsResult
    typealias ProxyTestRunNonStreamHandler = @Sendable (AdminProxyTestRunRequest) async throws -> SimpleHTTPResponse
    typealias ProxyTestRunStreamHandler = @Sendable (AdminProxyTestRunRequest) async throws -> StreamingHTTPResponse
    typealias ManagedProxyLogsHandler = @Sendable () async throws -> String

    private let dataDirectory: URL
    private let target: Target
    private let session: URLSession
    private let accountsHandler: AccountsHandler?
    private let importCurrentAuthHandler: ImportCurrentAuthHandler?
    private let importAuthJSONItemsHandler: ImportAuthJSONItemsHandler?
    private let exportAccountsHandler: ExportAccountsHandler?
    private let prepareOAuthHandler: PrepareOAuthHandler?
    private let completeOAuthCallbackHandler: CompleteOAuthCallbackHandler?
    private let requestLogsHandler: RequestLogsHandler?
    private let requestLogFiltersHandler: RequestLogFiltersHandler?
    private let requestLogsExportHandler: RequestLogsExportHandler?
    private let reasoningCacheSummaryHandler: ReasoningCacheSummaryHandler?
    private let clearReasoningCacheHandler: ClearReasoningCacheHandler?
    private let ocrCacheSummaryHandler: OCRCacheSummaryHandler?
    private let clearOCRCacheHandler: ClearOCRCacheHandler?
    private let ocrRecognitionLogsHandler: OCRRecognitionLogsHandler?
    private let ocrRecognitionResultHandler: OCRRecognitionResultHandler?
    private let diagnosticRequestBodySummaryHandler: DiagnosticRequestBodySummaryHandler?
    private let diagnosticRequestBodiesHandler: DiagnosticRequestBodiesHandler?
    private let diagnosticRequestBodyDetailHandler: DiagnosticRequestBodyDetailHandler?
    private let clearDiagnosticRequestBodiesHandler: ClearDiagnosticRequestBodiesHandler?
    private let getStatusHandler: GetStatusHandler?
    private let getStatsHandler: GetStatsHandler?
    private let getStatsForAPIKeyHandler: GetStatsForAPIKeyHandler?
    private let adminEventsHandler: AdminEventsHandler?
    private let saveSettingsHandler: SaveSettingsHandler?
    private let getSettingsHandler: GetSettingsHandler?
    private let getManagedProxySnapshotHandler: GetManagedProxySnapshotHandler?
    private let saveManagedProxyConfigHandler: SaveManagedProxyConfigHandler?
    private let saveManagedProxyHealthcheckConfigHandler: SaveManagedProxyHealthcheckConfigHandler?
    private let updateManagedProxySubscriptionHandler: UpdateManagedProxySubscriptionHandler?
    private let selectManagedProxyNodeHandler: SelectManagedProxyNodeHandler?
    private let switchManagedProxyCurrentNodeHandler: SwitchManagedProxyCurrentNodeHandler?
    private let updateManagedProxyPinnedNodeHandler: UpdateManagedProxyPinnedNodeHandler?
    private let healthcheckManagedProxyHandler: HealthcheckManagedProxyHandler?
    private let proxyAPIKeyUsageHandler: ProxyAPIKeyUsageHandler?
    private let manualAPIKeyAccountDetailsHandler: ManualAPIKeyAccountDetailsHandler?
    private let updateManualAPIKeyAccountHandler: UpdateManualAPIKeyAccountHandler?
    private let refreshUsageHandler: RefreshUsageHandler?
    private let refreshAccountUsageHandler: RefreshAccountUsageHandler?
    private let stopAccountCooldownHandler: StopAccountCooldownHandler?
    private let updateAccountCooldownPolicyHandler: UpdateAccountCooldownPolicyHandler?
    private let updateAccountLabelHandler: UpdateAccountLabelHandler?
    private let updateAccountManagedProxyNodeHandler: UpdateAccountManagedProxyNodeHandler?
    private let clearAccountManagedProxyNodesHandler: ClearAccountManagedProxyNodesHandler?
    private let updateAccountModelRoutingHandler: UpdateAccountModelRoutingHandler?
    private let updateAccountReasoningEffortHandler: UpdateAccountReasoningEffortHandler?
    private let updateAccountOrderHandler: UpdateAccountOrderHandler?
    private let batchRemoveAccountsHandler: BatchRemoveAccountsHandler?
    private let proxyTestRunNonStreamHandler: ProxyTestRunNonStreamHandler?
    private let proxyTestRunStreamHandler: ProxyTestRunStreamHandler?
    private let managedProxyLogsHandler: ManagedProxyLogsHandler?
    private var controllerCache: DaemonController?
    private var didBootstrap = false

    var capabilities: Capabilities {
        self.target.capabilities
    }

    init(
        dataDirectory: URL = Paths.defaultDataDirectory(),
        target: Target? = nil,
        session: URLSession? = nil,
        accountsHandler: AccountsHandler? = nil,
        importCurrentAuthHandler: ImportCurrentAuthHandler? = nil,
        importAuthJSONItemsHandler: ImportAuthJSONItemsHandler? = nil,
        exportAccountsHandler: ExportAccountsHandler? = nil,
        prepareOAuthHandler: PrepareOAuthHandler? = nil,
        completeOAuthCallbackHandler: CompleteOAuthCallbackHandler? = nil,
        requestLogsHandler: RequestLogsHandler? = nil,
        requestLogFiltersHandler: RequestLogFiltersHandler? = nil,
        requestLogsExportHandler: RequestLogsExportHandler? = nil,
        reasoningCacheSummaryHandler: ReasoningCacheSummaryHandler? = nil,
        clearReasoningCacheHandler: ClearReasoningCacheHandler? = nil,
        ocrCacheSummaryHandler: OCRCacheSummaryHandler? = nil,
        clearOCRCacheHandler: ClearOCRCacheHandler? = nil,
        ocrRecognitionLogsHandler: OCRRecognitionLogsHandler? = nil,
        ocrRecognitionResultHandler: OCRRecognitionResultHandler? = nil,
        diagnosticRequestBodySummaryHandler: DiagnosticRequestBodySummaryHandler? = nil,
        diagnosticRequestBodiesHandler: DiagnosticRequestBodiesHandler? = nil,
        diagnosticRequestBodyDetailHandler: DiagnosticRequestBodyDetailHandler? = nil,
        clearDiagnosticRequestBodiesHandler: ClearDiagnosticRequestBodiesHandler? = nil,
        getStatusHandler: GetStatusHandler? = nil,
        getStatsHandler: GetStatsHandler? = nil,
        getStatsForAPIKeyHandler: GetStatsForAPIKeyHandler? = nil,
        adminEventsHandler: AdminEventsHandler? = nil,
        saveSettingsHandler: SaveSettingsHandler? = nil,
        getSettingsHandler: GetSettingsHandler? = nil,
        getManagedProxySnapshotHandler: GetManagedProxySnapshotHandler? = nil,
        saveManagedProxyConfigHandler: SaveManagedProxyConfigHandler? = nil,
        saveManagedProxyHealthcheckConfigHandler: SaveManagedProxyHealthcheckConfigHandler? = nil,
        updateManagedProxySubscriptionHandler: UpdateManagedProxySubscriptionHandler? = nil,
        selectManagedProxyNodeHandler: SelectManagedProxyNodeHandler? = nil,
        switchManagedProxyCurrentNodeHandler: SwitchManagedProxyCurrentNodeHandler? = nil,
        updateManagedProxyPinnedNodeHandler: UpdateManagedProxyPinnedNodeHandler? = nil,
        healthcheckManagedProxyHandler: HealthcheckManagedProxyHandler? = nil,
        proxyAPIKeyUsageHandler: ProxyAPIKeyUsageHandler? = nil,
        manualAPIKeyAccountDetailsHandler: ManualAPIKeyAccountDetailsHandler? = nil,
        updateManualAPIKeyAccountHandler: UpdateManualAPIKeyAccountHandler? = nil,
        refreshUsageHandler: RefreshUsageHandler? = nil,
        refreshAccountUsageHandler: RefreshAccountUsageHandler? = nil,
        stopAccountCooldownHandler: StopAccountCooldownHandler? = nil,
        updateAccountCooldownPolicyHandler: UpdateAccountCooldownPolicyHandler? = nil,
        updateAccountLabelHandler: UpdateAccountLabelHandler? = nil,
        updateAccountManagedProxyNodeHandler: UpdateAccountManagedProxyNodeHandler? = nil,
        clearAccountManagedProxyNodesHandler: ClearAccountManagedProxyNodesHandler? = nil,
        updateAccountModelRoutingHandler: UpdateAccountModelRoutingHandler? = nil,
        updateAccountReasoningEffortHandler: UpdateAccountReasoningEffortHandler? = nil,
        updateAccountOrderHandler: UpdateAccountOrderHandler? = nil,
        batchRemoveAccountsHandler: BatchRemoveAccountsHandler? = nil,
        proxyTestRunNonStreamHandler: ProxyTestRunNonStreamHandler? = nil,
        proxyTestRunStreamHandler: ProxyTestRunStreamHandler? = nil,
        managedProxyLogsHandler: ManagedProxyLogsHandler? = nil
    ) {
        self.dataDirectory = dataDirectory
        self.target = target ?? .local(dataDirectory: dataDirectory)
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.accountsHandler = accountsHandler
        self.importCurrentAuthHandler = importCurrentAuthHandler
        self.importAuthJSONItemsHandler = importAuthJSONItemsHandler
        self.exportAccountsHandler = exportAccountsHandler
        self.prepareOAuthHandler = prepareOAuthHandler
        self.completeOAuthCallbackHandler = completeOAuthCallbackHandler
        self.requestLogsHandler = requestLogsHandler
        self.requestLogFiltersHandler = requestLogFiltersHandler
        self.requestLogsExportHandler = requestLogsExportHandler
        self.reasoningCacheSummaryHandler = reasoningCacheSummaryHandler
        self.clearReasoningCacheHandler = clearReasoningCacheHandler
        self.ocrCacheSummaryHandler = ocrCacheSummaryHandler
        self.clearOCRCacheHandler = clearOCRCacheHandler
        self.ocrRecognitionLogsHandler = ocrRecognitionLogsHandler
        self.ocrRecognitionResultHandler = ocrRecognitionResultHandler
        self.diagnosticRequestBodySummaryHandler = diagnosticRequestBodySummaryHandler
        self.diagnosticRequestBodiesHandler = diagnosticRequestBodiesHandler
        self.diagnosticRequestBodyDetailHandler = diagnosticRequestBodyDetailHandler
        self.clearDiagnosticRequestBodiesHandler = clearDiagnosticRequestBodiesHandler
        self.getStatusHandler = getStatusHandler
        self.getStatsHandler = getStatsHandler
        self.getStatsForAPIKeyHandler = getStatsForAPIKeyHandler
        self.adminEventsHandler = adminEventsHandler
        self.saveSettingsHandler = saveSettingsHandler
        self.getSettingsHandler = getSettingsHandler
        self.getManagedProxySnapshotHandler = getManagedProxySnapshotHandler
        self.saveManagedProxyConfigHandler = saveManagedProxyConfigHandler
        self.saveManagedProxyHealthcheckConfigHandler = saveManagedProxyHealthcheckConfigHandler
        self.updateManagedProxySubscriptionHandler = updateManagedProxySubscriptionHandler
        self.selectManagedProxyNodeHandler = selectManagedProxyNodeHandler
        self.switchManagedProxyCurrentNodeHandler = switchManagedProxyCurrentNodeHandler
        self.updateManagedProxyPinnedNodeHandler = updateManagedProxyPinnedNodeHandler
        self.healthcheckManagedProxyHandler = healthcheckManagedProxyHandler
        self.proxyAPIKeyUsageHandler = proxyAPIKeyUsageHandler
        self.manualAPIKeyAccountDetailsHandler = manualAPIKeyAccountDetailsHandler
        self.updateManualAPIKeyAccountHandler = updateManualAPIKeyAccountHandler
        self.refreshUsageHandler = refreshUsageHandler
        self.refreshAccountUsageHandler = refreshAccountUsageHandler
        self.stopAccountCooldownHandler = stopAccountCooldownHandler
        self.updateAccountCooldownPolicyHandler = updateAccountCooldownPolicyHandler
        self.updateAccountLabelHandler = updateAccountLabelHandler
        self.updateAccountManagedProxyNodeHandler = updateAccountManagedProxyNodeHandler
        self.clearAccountManagedProxyNodesHandler = clearAccountManagedProxyNodesHandler
        self.updateAccountModelRoutingHandler = updateAccountModelRoutingHandler
        self.updateAccountReasoningEffortHandler = updateAccountReasoningEffortHandler
        self.updateAccountOrderHandler = updateAccountOrderHandler
        self.batchRemoveAccountsHandler = batchRemoveAccountsHandler
        self.proxyTestRunNonStreamHandler = proxyTestRunNonStreamHandler
        self.proxyTestRunStreamHandler = proxyTestRunStreamHandler
        self.managedProxyLogsHandler = managedProxyLogsHandler
    }

    func getStatus() async throws -> ProxyStatus {
        if let getStatusHandler {
            return try await getStatusHandler()
        }
        if let status: ProxyStatus = try await self.httpRequest("/status", method: "GET") {
            return status
        }

        let config = try await Self.loadConfig(dataDirectory: self.dataDirectory)
        return ProxyStatus(
            running: false,
            publicBaseURL: "http://\(config.publicHost):\(config.publicPort)/v1",
            anthropicBaseURL: "http://\(config.publicHost):\(config.publicPort)",
            geminiBaseURL: "http://\(config.publicHost):\(config.publicPort)",
            adminBaseURL: "http://127.0.0.1:\(config.adminPort)/admin",
            apiKey: config.primaryProxyAPIKeyRecord?.key ?? config.proxyAPIKey,
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: RuntimeInfo.displayVersion,
            proxyTestAdminTransportMode: .full
        )
    }

    func getAccounts() async throws -> [AccountSummary] {
        if let accountsHandler {
            return try await accountsHandler()
        }
        if let accounts: [AccountSummary] = try await self.httpRequest("/accounts", method: "GET") {
            return accounts
        }
        return try await self.controller().listAccounts()
    }

    func importCurrentAuth(label: String? = nil) async throws -> AccountSummary {
        guard self.capabilities.supportsImportCurrent else {
            throw ProxyError.message("Import Current is unavailable for this admin target.")
        }
        if let importCurrentAuthHandler {
            return try await importCurrentAuthHandler(label)
        }
        struct Payload: Codable { var label: String? }
        if let result: AccountSummary = try await self.httpRequest("/accounts/import-current", method: "POST", body: Payload(label: label)) {
            return result
        }
        return try await self.controller().importCurrentAuth(label: label)
    }

    func importAuthJSONItems(_ items: [AuthJsonImportInput]) async throws -> ImportAccountsResult {
        if let importAuthJSONItemsHandler {
            return try await importAuthJSONItemsHandler(items)
        }
        if let result: ImportAccountsResult = try await self.httpRequest("/accounts/import", method: "POST", body: items) {
            return result
        }
        return try await self.controller().importAuthJSONAccounts(items)
    }

    func manualAddAPIKeyAccount(_ input: ManualAPIKeyAccountInput) async throws -> AccountSummary {
        if let result: AccountSummary = try await self.httpRequest("/accounts/manual-api-key", method: "POST", body: input) {
            return result
        }
        return try await self.controller().manualAddAPIKeyAccount(input)
    }

    func manualAPIKeyAccountDetails(id: String) async throws -> ManualAPIKeyAccountDetails {
        if let manualAPIKeyAccountDetailsHandler {
            return try await manualAPIKeyAccountDetailsHandler(id)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: ManualAPIKeyAccountDetails = try await self.httpRequest(
            "/accounts/\(encodedID)/manual-api-key",
            method: "GET"
        ) {
            return result
        }
        return try await self.controller().manualAPIKeyAccountDetails(id: id)
    }

    func updateManualAPIKeyAccount(id: String, input: UpdateManualAPIKeyAccountRequest) async throws -> AccountSummary {
        if let updateManualAPIKeyAccountHandler {
            return try await updateManualAPIKeyAccountHandler(id, input)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest(
            "/accounts/\(encodedID)/manual-api-key",
            method: "PUT",
            body: input
        ) {
            return result
        }
        return try await self.controller().updateManualAPIKeyAccount(id: id, input: input)
    }

    func updateAccountLabel(id: String, input: UpdateAccountLabelRequest) async throws -> AccountSummary {
        if let updateAccountLabelHandler {
            return try await updateAccountLabelHandler(id, input)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest(
            "/accounts/\(encodedID)/label",
            method: "PATCH",
            body: input
        ) {
            return result
        }
        return try await self.controller().updateAccountLabel(id: id, input: input)
    }

    func updateAccountManagedProxyNode(id: String, input: UpdateAccountManagedProxyNodeRequest) async throws -> AccountSummary {
        if let updateAccountManagedProxyNodeHandler {
            return try await updateAccountManagedProxyNodeHandler(id, input)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest(
            "/accounts/\(encodedID)/managed-proxy-node",
            method: "PATCH",
            body: input
        ) {
            return result
        }
        return try await self.controller().updateAccountManagedProxyNode(id: id, input: input)
    }

    func clearAccountManagedProxyNodes() async throws -> ClearAccountManagedProxyNodesResult {
        if let clearAccountManagedProxyNodesHandler {
            return try await clearAccountManagedProxyNodesHandler()
        }
        if let result: ClearAccountManagedProxyNodesResult = try await self.httpRequest(
            "/accounts/managed-proxy-node/clear",
            method: "POST"
        ) {
            return result
        }
        return try await self.controller().clearAccountManagedProxyNodes()
    }

    func updateAccountModelRouting(id: String, input: UpdateAccountModelRoutingRequest) async throws -> AccountSummary {
        if let updateAccountModelRoutingHandler {
            return try await updateAccountModelRoutingHandler(id, input)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest(
            "/accounts/\(encodedID)/model-routing",
            method: "PATCH",
            body: input
        ) {
            return result
        }
        return try await self.controller().updateAccountModelRouting(id: id, input: input)
    }

    func updateAccountReasoningEffort(id: String, input: UpdateAccountReasoningEffortRequest) async throws -> AccountSummary {
        if let updateAccountReasoningEffortHandler {
            return try await updateAccountReasoningEffortHandler(id, input)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest(
            "/accounts/\(encodedID)/reasoning-effort",
            method: "PATCH",
            body: input
        ) {
            return result
        }
        return try await self.controller().updateAccountReasoningEffort(id: id, input: input)
    }

    func exportAccounts() async throws -> Data {
        if let exportAccountsHandler {
            return try await exportAccountsHandler()
        }
        if let data = try await self.httpRequestData("/accounts/export", method: "GET") {
            return data
        }
        return try await self.controller().exportAccounts()
    }

    func refreshUsage() async throws -> [AccountSummary] {
        if let refreshUsageHandler {
            return try await refreshUsageHandler()
        }
        if let result: [AccountSummary] = try await self.httpRequest("/usage/refresh", method: "POST") {
            return result
        }
        return try await self.controller().refreshAllUsage()
    }

    func refreshAccountUsage(id: String) async throws -> AccountSummary {
        if let refreshAccountUsageHandler {
            return try await refreshAccountUsageHandler(id)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest("/accounts/\(encodedID)/usage/refresh", method: "POST") {
            return result
        }
        return try await self.controller().refreshAccountUsage(id: id)
    }

    func stopAccountCooldown(id: String) async throws -> AccountSummary {
        if let stopAccountCooldownHandler {
            return try await stopAccountCooldownHandler(id)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest("/accounts/\(encodedID)/cooldown/stop", method: "POST") {
            return result
        }
        return try await self.controller().stopAccountCooldown(id: id)
    }

    func updateAccountCooldownPolicy(id: String, input: UpdateAccountCooldownPolicyRequest) async throws -> AccountSummary {
        if let updateAccountCooldownPolicyHandler {
            return try await updateAccountCooldownPolicyHandler(id, input)
        }
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest(
            "/accounts/\(encodedID)/cooldown/policy",
            method: "PATCH",
            body: input
        ) {
            return result
        }
        return try await self.controller().updateAccountCooldownPolicy(id: id, input: input)
    }

    func setAccountEnabled(id: String, enabled: Bool) async throws -> AccountSummary {
        let payload = UpdateAccountEnabledRequest(enabled: enabled)
        let encodedID = Self.encodePathComponent(id)
        if let result: AccountSummary = try await self.httpRequest("/accounts/\(encodedID)/enabled", method: "PATCH", body: payload) {
            return result
        }
        return try await self.controller().setAccountEnabled(id: id, enabled: enabled)
    }

    func updateAccountOrder(_ payload: UpdateAccountOrderRequest) async throws -> [AccountSummary] {
        if let updateAccountOrderHandler {
            return try await updateAccountOrderHandler(payload)
        }
        if let result: [AccountSummary] = try await self.httpRequest("/accounts/order", method: "PUT", body: payload) {
            return result
        }
        return try await self.controller().reorderAccounts(ids: payload.orderedAccountIDs)
    }

    func removeAccount(id: String) async throws -> DeleteAccountResult {
        let encodedID = Self.encodePathComponent(id)
        if let result: DeleteAccountResult = try await self.httpRequest("/accounts/\(encodedID)", method: "DELETE") {
            return result
        }
        return try await self.controller().removeAccount(id: id)
    }

    func removeAccounts(_ payload: BatchDeleteAccountsRequest) async throws -> BatchDeleteAccountsResult {
        if let batchRemoveAccountsHandler {
            return try await batchRemoveAccountsHandler(payload)
        }
        if let result: BatchDeleteAccountsResult = try await self.httpRequest(
            "/accounts/batch/remove",
            method: "POST",
            body: payload
        ) {
            return result
        }
        return try await self.controller().removeAccounts(payload)
    }

    func getSettings() async throws -> AppConfig {
        if let getSettingsHandler {
            return try await getSettingsHandler()
        }
        if let config: AppConfig = try await self.httpRequest("/settings", method: "GET") {
            return config
        }
        return try await self.controller().loadConfig()
    }

    func saveSettings(_ config: AppConfig) async throws -> AppConfig {
        if let saveSettingsHandler {
            return try await saveSettingsHandler(config)
        }
        if let saved: AppConfig = try await self.httpRequest("/settings", method: "PUT", body: config) {
            return saved
        }
        return try await self.controller().saveConfig(config)
    }

    func getManagedProxySnapshot() async throws -> ManagedProxySnapshot {
        if let getManagedProxySnapshotHandler {
            return try await getManagedProxySnapshotHandler()
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest("/proxy/subscription", method: "GET") {
            return snapshot
        }
        return try await self.controller().managedProxySnapshot()
    }

    func saveManagedProxyConfig(_ payload: ManagedProxyConfigPayload) async throws -> ManagedProxySnapshot {
        if let saveManagedProxyConfigHandler {
            return try await saveManagedProxyConfigHandler(payload)
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest("/proxy/subscription", method: "PUT", body: payload) {
            return snapshot
        }
        return try await self.controller().saveManagedProxyConfig(payload)
    }

    func saveManagedProxyHealthcheckConfig(
        _ payload: ManagedProxyHealthcheckConfigPayload
    ) async throws -> ManagedProxySnapshot {
        if let saveManagedProxyHealthcheckConfigHandler {
            return try await saveManagedProxyHealthcheckConfigHandler(payload)
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest(
            "/proxy/subscription/healthcheck-url",
            method: "PUT",
            body: payload
        ) {
            return snapshot
        }
        return try await self.controller().saveManagedProxyHealthcheckConfig(payload)
    }

    func updateManagedProxySubscription() async throws -> ManagedProxySnapshot {
        if let updateManagedProxySubscriptionHandler {
            return try await updateManagedProxySubscriptionHandler()
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest("/proxy/subscription/update", method: "POST") {
            return snapshot
        }
        return try await self.controller().updateManagedProxySubscription()
    }

    func selectManagedProxyNode(_ request: ManagedProxySelectRequest) async throws -> ManagedProxySnapshot {
        if let selectManagedProxyNodeHandler {
            return try await selectManagedProxyNodeHandler(request)
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest("/proxy/subscription/select", method: "POST", body: request) {
            return snapshot
        }
        return try await self.controller().selectManagedProxyNode(name: request.name)
    }

    func switchManagedProxyCurrentNode(_ request: ManagedProxySwitchCurrentRequest) async throws -> ManagedProxySnapshot {
        if let switchManagedProxyCurrentNodeHandler {
            return try await switchManagedProxyCurrentNodeHandler(request)
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest(
            "/proxy/subscription/current-node",
            method: "POST",
            body: request
        ) {
            return snapshot
        }
        return try await self.controller().switchManagedProxyCurrentNode(name: request.name)
    }

    func updateManagedProxyPinnedNode(_ request: ManagedProxyPinnedNodeRequest) async throws -> ManagedProxySnapshot {
        if let updateManagedProxyPinnedNodeHandler {
            return try await updateManagedProxyPinnedNodeHandler(request)
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest(
            "/proxy/subscription/pinned-node",
            method: "PATCH",
            body: request
        ) {
            return snapshot
        }
        return try await self.controller().updateManagedProxyPinnedNode(name: request.name)
    }

    func healthcheckManagedProxy(_ request: ManagedProxyHealthcheckRequest) async throws -> ManagedProxySnapshot {
        if let healthcheckManagedProxyHandler {
            return try await healthcheckManagedProxyHandler(request)
        }
        if let snapshot: ManagedProxySnapshot = try await self.httpRequest("/proxy/subscription/healthcheck", method: "POST", body: request) {
            return snapshot
        }
        return try await self.controller().healthcheckManagedProxy(nodeName: request.nodeName)
    }

    func getManagedProxyLogs() async throws -> String {
        guard let managedProxyLogsHandler else {
            throw ProxyError.message("Managed proxy logs are unavailable for this admin target.")
        }
        return try await managedProxyLogsHandler()
    }

    func rotateProxyAPIKey() async throws -> ProxyStatus {
        if let status: ProxyStatus = try await self.httpRequest("/proxy/key/rotate", method: "POST") {
            return status
        }
        return try await self.controller().rotateProxyAPIKey()
    }

    func prepareOAuth(providerFamily: AccountProviderFamily = .openAI) async throws -> PreparedOAuthLogin {
        guard self.capabilities.supportsOAuth else {
            throw ProxyError.message("OAuth management is unavailable for this admin target.")
        }
        if let prepareOAuthHandler {
            return try await prepareOAuthHandler(providerFamily)
        }

        let path = Self.oauthPath(providerFamily: providerFamily, action: "prepare")
        do {
            if let prepared: PreparedOAuthLogin = try await self.httpRequest(path, method: "POST"),
               prepared.authURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return prepared
            }
        } catch {
        }
        let prepared = try await self.controller().prepareOAuthLogin(providerFamily: providerFamily)
        guard prepared.authURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ProxyError.message("生成 OAuth 授权链接失败")
        }
        return prepared
    }

    func completeOAuthCallback(
        _ callbackURL: String,
        providerFamily: AccountProviderFamily = .openAI
    ) async throws -> AccountSummary {
        guard self.capabilities.supportsOAuth else {
            throw ProxyError.message("OAuth management is unavailable for this admin target.")
        }
        struct Payload: Codable {
            var callbackURL: String
        }

        if let completeOAuthCallbackHandler {
            return try await completeOAuthCallbackHandler(providerFamily, callbackURL)
        }

        let path = Self.oauthPath(providerFamily: providerFamily, action: "complete")
        do {
            if let account: AccountSummary = try await self.httpRequest(
                path,
                method: "POST",
                body: Payload(callbackURL: callbackURL)
            ) {
                return account
            }
        } catch {
        }

        return try await self.controller().completeOAuthCallback(providerFamily: providerFamily, url: callbackURL)
    }

    func getStats(apiKey: String? = nil) async throws -> AdminStatsSummary {
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let getStatsForAPIKeyHandler {
            return try await getStatsForAPIKeyHandler(trimmedAPIKey.isEmpty ? nil : trimmedAPIKey)
        }
        if trimmedAPIKey.isEmpty, let getStatsHandler {
            return try await getStatsHandler()
        }
        let queryItems = trimmedAPIKey.isEmpty
            ? []
            : [URLQueryItem(name: "api_key", value: trimmedAPIKey)]
        if let stats: AdminStatsSummary = try await self.httpRequest(
            "/stats/summary",
            method: "GET",
            queryItems: queryItems
        ) {
            return stats
        }
        return try await self.controller().statsSummary(apiKey: trimmedAPIKey.isEmpty ? nil : trimmedAPIKey)
    }

    func streamAdminEvents() async throws -> AsyncThrowingStream<AdminEvent, Error> {
        if let adminEventsHandler {
            return try await adminEventsHandler()
        }
        if let stream = try await self.httpAdminEventStream() {
            return stream
        }
        throw ProxyError.message("Admin event stream is unavailable.")
    }

    func getReasoningCacheSummary() async throws -> ReasoningCacheSummary {
        if let reasoningCacheSummaryHandler {
            return try await reasoningCacheSummaryHandler()
        }
        if let summary: ReasoningCacheSummary = try await self.httpRequest("/reasoning-cache/summary", method: "GET") {
            return summary
        }
        return try await self.controller().reasoningCacheSummary()
    }

    func clearReasoningCache(_ request: ClearReasoningCacheRequest) async throws -> ClearReasoningCacheResult {
        if let clearReasoningCacheHandler {
            return try await clearReasoningCacheHandler(request)
        }
        if let result: ClearReasoningCacheResult = try await self.httpRequest(
            "/reasoning-cache/clear",
            method: "POST",
            body: request
        ) {
            return result
        }
        return try await self.controller().clearReasoningCache(request)
    }

    func getOCRCacheSummary() async throws -> OCRCacheSummary {
        if let ocrCacheSummaryHandler {
            return try await ocrCacheSummaryHandler()
        }
        if let summary: OCRCacheSummary = try await self.httpRequest("/ocr-cache/summary", method: "GET") {
            return summary
        }
        return try await self.controller().ocrCacheSummary()
    }

    func clearOCRCache(_ request: ClearOCRCacheRequest) async throws -> ClearOCRCacheResult {
        if let clearOCRCacheHandler {
            return try await clearOCRCacheHandler(request)
        }
        if let result: ClearOCRCacheResult = try await self.httpRequest(
            "/ocr-cache/clear",
            method: "POST",
            body: request
        ) {
            return result
        }
        return try await self.controller().clearOCRCache(request)
    }

    func getOCRRecognitionLogs(_ request: OCRRecognitionLogListRequest) async throws -> OCRRecognitionLogListResponse {
        if let ocrRecognitionLogsHandler {
            return try await ocrRecognitionLogsHandler(request)
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(request.limit)"),
            URLQueryItem(name: "offset", value: "\(request.offset)"),
        ]
        if let status = request.status {
            queryItems.append(URLQueryItem(name: "status", value: status.rawValue))
        }
        if let page: OCRRecognitionLogListResponse = try await self.httpRequest(
            "/ocr-recognition-logs",
            method: "GET",
            queryItems: queryItems
        ) {
            return page
        }
        return try await self.controller().ocrRecognitionLogs(request: request)
    }

    func getOCRRecognitionResult(logID: Int64) async throws -> OCRRecognitionResultLookupResponse {
        if let ocrRecognitionResultHandler {
            return try await ocrRecognitionResultHandler(logID)
        }
        if let result: OCRRecognitionResultLookupResponse = try await self.httpRequest(
            "/ocr-recognition-logs/\(logID)/result",
            method: "GET"
        ) {
            return result
        }
        return try await self.controller().ocrRecognitionResult(logID: logID)
    }

    func getDiagnosticRequestBodySummary() async throws -> DiagnosticRequestBodySummary {
        if let diagnosticRequestBodySummaryHandler {
            return try await diagnosticRequestBodySummaryHandler()
        }
        if let summary: DiagnosticRequestBodySummary = try await self.httpRequest(
            "/diagnostic-request-bodies/summary",
            method: "GET"
        ) {
            return summary
        }
        return try await self.controller().diagnosticRequestBodySummary()
    }

    func getDiagnosticRequestBodies(requestLogID: Int64? = nil) async throws -> [DiagnosticRequestBodyEntry] {
        if let diagnosticRequestBodiesHandler {
            return try await diagnosticRequestBodiesHandler(requestLogID)
        }
        let queryItems = requestLogID.map { [URLQueryItem(name: "requestLogID", value: String($0))] } ?? []
        if let entries: [DiagnosticRequestBodyEntry] = try await self.httpRequest(
            "/diagnostic-request-bodies",
            method: "GET",
            queryItems: queryItems
        ) {
            return entries
        }
        return try await self.controller().diagnosticRequestBodies(requestLogID: requestLogID)
    }

    func getDiagnosticRequestBodyDetail(id: Int64) async throws -> DiagnosticRequestBodyDetail {
        if let diagnosticRequestBodyDetailHandler {
            return try await diagnosticRequestBodyDetailHandler(id)
        }
        if let detail: DiagnosticRequestBodyDetail = try await self.httpRequest(
            "/diagnostic-request-bodies/\(id)",
            method: "GET"
        ) {
            return detail
        }
        return try await self.controller().diagnosticRequestBodyDetail(id: id)
    }

    func clearDiagnosticRequestBodies(_ request: ClearDiagnosticRequestBodiesRequest) async throws -> ClearDiagnosticRequestBodiesResult {
        if let clearDiagnosticRequestBodiesHandler {
            return try await clearDiagnosticRequestBodiesHandler(request)
        }
        if let result: ClearDiagnosticRequestBodiesResult = try await self.httpRequest(
            "/diagnostic-request-bodies/clear",
            method: "POST",
            body: request
        ) {
            return result
        }
        return try await self.controller().clearDiagnosticRequestBodies(request)
    }

    func getProxyAPIKeyUsage(query: RequestLogQuery) async throws -> ProxyAPIKeyUsageReport {
        if let proxyAPIKeyUsageHandler {
            return try await proxyAPIKeyUsageHandler(query)
        }
        if let report: ProxyAPIKeyUsageReport = try await self.httpRequest(
            "/stats/api-key-usage",
            method: "GET",
            queryItems: query.timeRangeOnly().normalized().queryItems
        ) {
            return report
        }
        return try await self.controller().proxyAPIKeyUsage(query: query)
    }

    func getProxyTestModels(selectedAccountKey: String? = nil) async throws -> ProxyTestModelCatalog {
        guard self.capabilities.supportsProxyTesting else {
            throw ProxyError.message("Proxy testing is unavailable for this admin target.")
        }
        let trimmedSelectedAccountKey = selectedAccountKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let queryItems = trimmedSelectedAccountKey.isEmpty
            ? []
            : [URLQueryItem(name: "selected_account_key", value: trimmedSelectedAccountKey)]
        if let catalog: ProxyTestModelCatalog = try await self.httpRequest(
            "/proxy-test/models",
            method: "GET",
            queryItems: queryItems
        ) {
            return catalog
        }
        let controller = try await self.controller()
        return try await controller.proxyTestModelsCatalog(selectedAccountKey: trimmedSelectedAccountKey)
    }

    func runProxyTestNonStream(_ payload: AdminProxyTestRunRequest) async throws -> SimpleHTTPResponse {
        guard self.capabilities.supportsProxyTesting else {
            throw ProxyError.message("Proxy testing is unavailable for this admin target.")
        }
        if let proxyTestRunNonStreamHandler {
            return try await proxyTestRunNonStreamHandler(payload)
        }
        if let response = try await self.httpProxyTestRun(payload) {
            return response
        }
        let proxy = try await self.controller().adminProxyTestRun(payload)
        return try await Self.collectSimpleHTTPResponse(from: proxy)
    }

    func runProxyTestStream(_ payload: AdminProxyTestRunRequest) async throws -> StreamingHTTPResponse {
        guard self.capabilities.supportsProxyTesting else {
            throw ProxyError.message("Proxy testing is unavailable for this admin target.")
        }
        if let proxyTestRunStreamHandler {
            return try await proxyTestRunStreamHandler(payload)
        }
        if let response = try await self.httpProxyTestRunStream(payload) {
            return response
        }
        let proxy = try await self.controller().adminProxyTestRun(payload)
        return Self.streamingHTTPResponse(from: proxy)
    }

    func getRequestLogs(query: RequestLogQuery) async throws -> RequestLogPage {
        if let requestLogsHandler {
            return try await requestLogsHandler(query)
        }
        if let page: RequestLogPage = try await self.httpRequest(
            "/stats/requests",
            method: "GET",
            queryItems: query.normalized().queryItems
        ) {
            return page
        }
        return try await self.controller().requestLogs(query: query)
    }

    func getRequestLogFilters(query: RequestLogQuery) async throws -> RequestLogFilterOptions {
        if let requestLogFiltersHandler {
            return try await requestLogFiltersHandler(query)
        }
        if let options: RequestLogFilterOptions = try await self.httpRequest(
            "/stats/request-filters",
            method: "GET",
            queryItems: query.timeRangeOnly().normalized().queryItems
        ) {
            return options
        }
        return try await self.controller().requestLogFilters(query: query)
    }

    func exportRequestLogs(query: RequestLogQuery) async throws -> Data {
        if let requestLogsExportHandler {
            return try await requestLogsExportHandler(query)
        }
        if let data = try await self.httpRequestData(
            "/stats/requests/export",
            method: "GET",
            queryItems: query.normalized().queryItems
        ) {
            return data
        }
        return try await self.controller().exportRequestLogs(query: query)
    }

    private struct AdminRequestContext {
        let baseURL: URL
        let token: String
        let reconnectHandler: (@Sendable () async throws -> Void)?
        let allowsLocalFallback: Bool
        let isRemoteTarget: Bool
    }

    private func controller() async throws -> DaemonController {
        guard self.target.allowsLocalFallback else {
            throw ProxyError.message("This admin target does not support local controller fallback.")
        }
        if let controller = self.controllerCache {
            if !self.didBootstrap {
                try await controller.bootstrap()
                self.didBootstrap = true
            }
            return controller
        }

        let dataDirectory = self.dataDirectory
        let controller = try DaemonController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false,
            publicBaseURLProvider: {
                let config = try await Self.loadConfig(dataDirectory: dataDirectory)
                return "http://\(config.publicHost):\(config.publicPort)/v1"
            },
            adminBaseURLProvider: {
                let config = try await Self.loadConfig(dataDirectory: dataDirectory)
                return "http://127.0.0.1:\(config.adminPort)/admin"
            }
        )
        try await controller.bootstrap()
        self.controllerCache = controller
        self.didBootstrap = true
        return controller
    }

    private func httpRequest<T: Decodable>(
        _ path: String,
        method: String,
        body: Encodable? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> T? {
        guard let data = try await self.httpRequestData(path, method: method, body: body, queryItems: queryItems) else {
            return nil
        }
        do {
            return try Helpers.readJSON(T.self, from: data)
        } catch {
            if let detail = DecodingDiagnostics.describe(
                error,
                endpoint: "/admin\(path)",
                method: method,
                targetType: T.self,
                responseBody: data
            ) {
                throw ProxyError.message(detail)
            }
            throw error
        }
    }

    private func httpRequestData(
        _ path: String,
        method: String,
        body: Encodable? = nil,
        queryItems: [URLQueryItem] = [],
        allowReconnectRetry: Bool = true
    ) async throws -> Data? {
        let context = try await self.adminRequestContext()
        var components = URLComponents(url: Self.makeAdminURL(baseURL: context.baseURL, path: path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                if context.allowsLocalFallback {
                    return nil
                }
                throw ProxyError.message("Admin endpoint returned an invalid response.")
            }
            if httpResponse.statusCode == 401,
               allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpRequestData(
                    path,
                    method: method,
                    body: body,
                    queryItems: queryItems,
                    allowReconnectRetry: false
                )
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ProxyError.message(Self.httpErrorMessage(from: data, statusCode: httpResponse.statusCode))
            }
            return data
        } catch let error as URLError {
            guard Self.isRecoverableConnectionError(error) else {
                throw error
            }
            if allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpRequestData(
                    path,
                    method: method,
                    body: body,
                    queryItems: queryItems,
                    allowReconnectRetry: false
                )
            }
            if context.allowsLocalFallback {
                return nil
            }
            throw ProxyError.message(
                Self.adminConnectionMessage(
                    baseURL: context.baseURL,
                    detail: error.localizedDescription,
                    isRemoteTarget: context.isRemoteTarget
                )
            )
        }
    }

    private func httpProxyTestRun(
        _ payload: AdminProxyTestRunRequest,
        allowReconnectRetry: Bool = true
    ) async throws -> SimpleHTTPResponse? {
        let context = try await self.adminRequestContext()
        let request = try await self.adminRequest(path: "/proxy-test/run", method: "POST", body: payload)
        do {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                if context.allowsLocalFallback {
                    return nil
                }
                throw ProxyError.message("Admin proxy test returned an invalid response.")
            }
            if httpResponse.statusCode == 401,
               allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpProxyTestRun(payload, allowReconnectRetry: false)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if (httpResponse.statusCode == 404 || httpResponse.statusCode == 405) && context.allowsLocalFallback {
                    return nil
                }
                throw ProxyPublicRequestFailure(
                    statusCode: httpResponse.statusCode,
                    message: Self.httpErrorMessage(from: data, statusCode: httpResponse.statusCode),
                    rawBody: String(decoding: data, as: UTF8.self)
                )
            }
            return SimpleHTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: Self.responseHeaders(from: httpResponse),
                body: data
            )
        } catch let error as URLError {
            guard Self.isRecoverableConnectionError(error) else {
                throw error
            }
            if allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpProxyTestRun(payload, allowReconnectRetry: false)
            }
            if context.allowsLocalFallback {
                return nil
            }
            throw ProxyError.message(
                Self.adminConnectionMessage(
                    baseURL: context.baseURL,
                    detail: error.localizedDescription,
                    isRemoteTarget: context.isRemoteTarget
                )
            )
        }
    }

    private func httpProxyTestRunStream(
        _ payload: AdminProxyTestRunRequest,
        allowReconnectRetry: Bool = true
    ) async throws -> StreamingHTTPResponse? {
        let context = try await self.adminRequestContext()
        let request = try await self.adminRequest(path: "/proxy-test/run", method: "POST", body: payload)
        do {
            let (bytes, response) = try await self.session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                if context.allowsLocalFallback {
                    return nil
                }
                throw ProxyError.message("Admin proxy test returned an invalid streaming response.")
            }
            if httpResponse.statusCode == 401,
               allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpProxyTestRunStream(payload, allowReconnectRetry: false)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                }
                if (httpResponse.statusCode == 404 || httpResponse.statusCode == 405) && context.allowsLocalFallback {
                    return nil
                }
                throw ProxyPublicRequestFailure(
                    statusCode: httpResponse.statusCode,
                    message: Self.httpErrorMessage(from: data, statusCode: httpResponse.statusCode),
                    rawBody: String(decoding: data, as: UTF8.self)
                )
            }

            let stream = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    var iterator = bytes.makeAsyncIterator()
                    var buffer = Data()
                    buffer.reserveCapacity(2_048)

                    do {
                        while let byte = try await iterator.next() {
                            try Task.checkCancellation()
                            buffer.append(byte)
                            if buffer.count >= 2_048 {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty {
                            continuation.yield(buffer)
                        }
                        continuation.finish()
                    } catch {
                        if error is CancellationError {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }

            return StreamingHTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: Self.responseHeaders(from: httpResponse),
                body: stream
            )
        } catch let error as URLError {
            guard Self.isRecoverableConnectionError(error) else {
                throw error
            }
            if allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpProxyTestRunStream(payload, allowReconnectRetry: false)
            }
            if context.allowsLocalFallback {
                return nil
            }
            throw ProxyError.message(
                Self.adminConnectionMessage(
                    baseURL: context.baseURL,
                    detail: error.localizedDescription,
                    isRemoteTarget: context.isRemoteTarget
                )
            )
        }
    }

    private func httpAdminEventStream(
        allowReconnectRetry: Bool = true
    ) async throws -> AsyncThrowingStream<AdminEvent, Error>? {
        let context = try await self.adminRequestContext()
        let url = Self.makeAdminURL(baseURL: context.baseURL, path: "/events")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1_800
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await self.session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                if context.allowsLocalFallback {
                    return nil
                }
                throw ProxyError.message("Admin event stream returned an invalid response.")
            }
            if httpResponse.statusCode == 401,
               allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpAdminEventStream(allowReconnectRetry: false)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                }
                if (httpResponse.statusCode == 404 || httpResponse.statusCode == 405) && context.allowsLocalFallback {
                    return nil
                }
                throw ProxyError.message(Self.httpErrorMessage(from: data, statusCode: httpResponse.statusCode))
            }

            return AsyncThrowingStream<AdminEvent, Error> { continuation in
                let task = Task {
                    var decoder = SSEIncrementalDecoder()
                    var buffer = Data()
                    buffer.reserveCapacity(2_048)

                    func consume(_ data: Data) {
                        for event in decoder.append(data) {
                            guard let adminEvent = Self.adminEvent(from: event) else {
                                continue
                            }
                            continuation.yield(adminEvent)
                        }
                    }

                    do {
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            buffer.append(byte)
                            if buffer.count >= 2_048 {
                                consume(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if buffer.isEmpty == false {
                            consume(buffer)
                        }
                        for event in decoder.finish() {
                            if let adminEvent = Self.adminEvent(from: event) {
                                continuation.yield(adminEvent)
                            }
                        }
                        continuation.finish()
                    } catch {
                        if error is CancellationError {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        } catch let error as URLError {
            guard Self.isRecoverableConnectionError(error) else {
                throw error
            }
            if allowReconnectRetry,
               let reconnectHandler = context.reconnectHandler
            {
                try await reconnectHandler()
                return try await self.httpAdminEventStream(allowReconnectRetry: false)
            }
            if context.allowsLocalFallback {
                return nil
            }
            throw ProxyError.message(
                Self.adminConnectionMessage(
                    baseURL: context.baseURL,
                    detail: error.localizedDescription,
                    isRemoteTarget: context.isRemoteTarget
                )
            )
        }
    }

    private func adminRequest(path: String, method: String, body: Encodable? = nil) async throws -> URLRequest {
        let context = try await self.adminRequestContext()
        let url = Self.makeAdminURL(baseURL: context.baseURL, path: path)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 1_800
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { partialResult, entry in
            guard let key = entry.key as? String else { return }
            partialResult[key.lowercased()] = "\(entry.value)"
        }
    }

    nonisolated private static func adminEvent(from event: SSEEvent) -> AdminEvent? {
        guard event.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return try? Helpers.readJSON(AdminEvent.self, from: Data(event.data.utf8))
    }

    private static func collectSimpleHTTPResponse(from proxy: ProxyHTTPResponse) async throws -> SimpleHTTPResponse {
        let body: Data
        switch proxy.body {
        case .bytes(let data):
            body = data
        case .stream(let stream):
            var collected = Data()
            for try await chunk in stream {
                collected.append(chunk)
            }
            body = collected
        }
        return SimpleHTTPResponse(statusCode: proxy.statusCode, headers: proxy.headers, body: body)
    }

    private static func streamingHTTPResponse(from proxy: ProxyHTTPResponse) -> StreamingHTTPResponse {
        let body: AsyncThrowingStream<Data, Error>
        switch proxy.body {
        case .bytes(let data):
            body = AsyncThrowingStream { continuation in
                if !data.isEmpty {
                    continuation.yield(data)
                }
                continuation.finish()
            }
        case .stream(let stream):
            body = stream
        }
        return StreamingHTTPResponse(statusCode: proxy.statusCode, headers: proxy.headers, body: body)
    }

    private func adminRequestContext() async throws -> AdminRequestContext {
        switch self.target {
        case .local(_, _):
            let config = try await Self.loadConfig(dataDirectory: self.dataDirectory)
            return AdminRequestContext(
                baseURL: URL(string: "http://127.0.0.1:\(config.adminPort)/admin")!,
                token: try self.localAdminToken(),
                reconnectHandler: nil,
                allowsLocalFallback: true,
                isRemoteTarget: false
            )
        case .remote(let configuration):
            return AdminRequestContext(
                baseURL: try await configuration.adminBaseURLProvider(),
                token: try await configuration.tokenProvider(),
                reconnectHandler: configuration.reconnectHandler,
                allowsLocalFallback: false,
                isRemoteTarget: true
            )
        }
    }

    private func localAdminToken() throws -> String {
        try SecretStore(dataDirectory: self.dataDirectory).adminToken()
    }

    private static func loadConfig(dataDirectory: URL) async throws -> AppConfig {
        let databasePath = Paths.databaseURL(in: dataDirectory).path
        if FileManager.default.fileExists(atPath: databasePath) == false {
            return AppConfig()
        }
        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let store = try SQLiteStore(dataDirectory: dataDirectory, secretStore: secretStore)
        return try store.loadConfig()
    }

    private static func httpErrorMessage(from data: Data, statusCode: Int) -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        return "HTTP \(statusCode)"
    }

    private static func makeAdminURL(baseURL: URL, path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(normalizedPath)
    }

    private static func isRecoverableConnectionError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost, .resourceUnavailable, .notConnectedToInternet, .badServerResponse:
            return true
        default:
            return false
        }
    }

    private static func adminConnectionMessage(baseURL: URL, detail: String, isRemoteTarget: Bool) -> String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = trimmedDetail.isEmpty
            ? "Unable to reach admin endpoint at \(baseURL.absoluteString)."
            : "Unable to reach admin endpoint at \(baseURL.absoluteString): \(trimmedDetail)"
        if isRemoteTarget {
            message += " The remote proxy service may be listening on a different admin port than the saved host config, or the remote admin listener may not be running."
        }
        return message
    }

    private static func oauthPath(providerFamily: AccountProviderFamily, action: String) -> String {
        switch providerFamily {
        case .openAI:
            return "/oauth/openai/\(action)"
        case .anthropic:
            return "/oauth/anthropic/\(action)"
        case .gemini:
            return "/oauth/gemini/\(action)"
        }
    }

    private static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private struct AnyEncodable: Encodable {
    private let encodeBlock: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeBlock = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try self.encodeBlock(encoder)
    }
}
#endif
