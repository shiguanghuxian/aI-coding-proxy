import Foundation

public final class AccountService: @unchecked Sendable {
    private static let refreshAllUsageConcurrencyLimit = 3

    private let store: SQLiteStore
    private let secretStore: SecretStore

    public init(store: SQLiteStore, secretStore: SecretStore) {
        self.store = store
        self.secretStore = secretStore
    }

    public func currentAuthAccountKey() -> String? {
        guard let auth = AuthService.readCurrentCodexAuthOptional(),
              let extracted = try? AuthService.extractAuth(from: auth, secretStore: self.secretStore)
        else {
            return nil
        }
        return AuthService.accountKey(from: extracted)
    }

    public func listAccounts() async throws -> [AccountSummary] {
        try self.repairStoredManualAccountsIfNeeded()
        return try self.store.listAccountSummaries(currentAccountKey: self.currentAuthAccountKey())
    }

    public func importCurrentAuth(label: String?, config: AppConfig) async throws -> AccountSummary {
        let text = try AuthService.readCurrentCodexAuth()
        let record = try await self.prepareAccount(text: text, sourceLabel: label, config: config, enabled: true)
        _ = try self.store.upsertAccount(record)
        return try self.summary(forAccountKey: record.accountKey)
    }

    public func importAuthJSONAccounts(items: [AuthJsonImportInput], config: AppConfig) async throws -> ImportAccountsResult {
        guard !items.isEmpty else {
            throw ProxyError.message("请至少选择一个 JSON 文件")
        }
        var imported = 0
        var updated = 0
        var failures: [ImportAccountFailure] = []
        for item in items {
            let candidates: [AuthJsonImportInput]
            do {
                candidates = try self.expandAuthImportInput(item)
            } catch {
                failures.append(.init(source: item.source, error: error.localizedDescription))
                continue
            }
            for candidate in candidates {
                do {
                    let record = try await self.prepareAccount(
                        text: candidate.content,
                        sourceLabel: candidate.label ?? item.label,
                        config: config,
                        enabled: candidate.enabled ?? true,
                        managedProxyNodeName: candidate.managedProxyNodeName,
                        modelRouting: candidate.modelRouting,
                        reasoningEffort: candidate.reasoningEffort,
                        automaticCooldownDisabled: candidate.automaticCooldownDisabled ?? false
                    )
                    if try self.store.upsertAccount(record) {
                        updated += 1
                    } else {
                        imported += 1
                    }
                } catch {
                    failures.append(.init(source: candidate.source, error: error.localizedDescription))
                }
            }
        }
        return ImportAccountsResult(
            totalCount: items.count,
            importedCount: imported,
            updatedCount: updated,
            failures: failures
        )
    }

    public func exportAccounts() async throws -> Data {
        try self.store.exportAccountsJSON()
    }

    public func manualAddAPIKeyAccount(
        _ input: ManualAPIKeyAccountInput,
        config: AppConfig
    ) async throws -> AccountSummary {
        let authJSON: String
        do {
            authJSON = try self.validatedManualAPIKeyAuthJSON(
                baseURL: input.baseURL,
                apiKey: input.apiKey,
                providerPreset: input.providerPreset,
                baseURLMode: input.baseURLMode,
                upstreamAdapter: input.upstreamAdapter
            )
        } catch {
            throw ProxyError.message("手动添加 API Key 账号失败：规范化根地址或密钥时出错，\(error.localizedDescription)")
        }

        let record: AccountRecord
        do {
            record = try await self.prepareAccount(
                text: authJSON,
                sourceLabel: input.label,
                config: config,
                enabled: input.enabled,
                automaticCooldownDisabled: input.automaticCooldownDisabled,
                supportsVision: input.supportsVision
            )
        } catch {
            throw ProxyError.message("手动添加 API Key 账号失败：准备账号数据时出错，\(error.localizedDescription)")
        }

        do {
            _ = try self.store.upsertAccount(record)
        } catch {
            throw ProxyError.message("手动添加 API Key 账号失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forAccountKey: record.accountKey)
        } catch {
            throw ProxyError.message("手动添加 API Key 账号失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    func manualAPIKeyAccountDetails(id: String) throws -> ManualAPIKeyAccountDetails {
        let record: AccountRecord
        do {
            record = try self.store.loadAccountRecord(id: id)
        } catch {
            throw ProxyError.message("读取 API Key 账号详情失败：读取现有账号时出错，\(error.localizedDescription)")
        }

        guard record.authMode.isManualAPIKey else {
            throw ProxyError.message("读取 API Key 账号详情失败：仅支持 API Key 类型账号")
        }

        let extracted: ExtractedAuth
        do {
            extracted = try AuthService.extractAuth(from: record.authJSON, secretStore: self.secretStore)
        } catch {
            throw ProxyError.message("读取 API Key 账号详情失败：解析已保存密钥时出错，\(error.localizedDescription)")
        }

        return ManualAPIKeyAccountDetails(
            label: record.label,
            providerPreset: record.providerPreset,
            baseURL: self.manualAPIKeyEditBaseURL(
                upstreamBaseURL: extracted.upstreamBaseURL ?? record.upstreamBaseURL ?? record.providerPreset.defaultBaseURL,
                providerPreset: record.providerPreset,
                baseURLMode: extracted.baseURLMode
            ),
            baseURLMode: extracted.baseURLMode,
            upstreamAdapter: extracted.upstreamAdapter,
            apiKey: extracted.accessToken,
            enabled: record.enabled,
            automaticCooldownDisabled: record.automaticCooldownDisabled,
            supportsVision: record.supportsVision
        )
    }

    func updateManualAPIKeyAccount(
        id: String,
        input: UpdateManualAPIKeyAccountRequest,
        config: AppConfig
    ) async throws -> AccountSummary {
        let existingRecord: AccountRecord
        do {
            existingRecord = try self.store.loadAccountRecord(id: id)
        } catch {
            throw ProxyError.message("编辑 API Key 账号失败：读取现有账号时出错，\(error.localizedDescription)")
        }

        guard existingRecord.authMode.isManualAPIKey else {
            throw ProxyError.message("编辑 API Key 账号失败：仅支持编辑 API Key 类型账号")
        }

        let authJSON: String
        do {
            authJSON = try self.validatedManualAPIKeyAuthJSON(
                baseURL: input.baseURL,
                apiKey: input.apiKey,
                providerPreset: input.providerPreset,
                baseURLMode: input.baseURLMode,
                upstreamAdapter: input.upstreamAdapter
            )
        } catch {
            throw ProxyError.message("编辑 API Key 账号失败：规范化根地址或密钥时出错，\(error.localizedDescription)")
        }

        let prepared: AccountRecord
        do {
            prepared = try await self.prepareAccount(
                text: authJSON,
                sourceLabel: input.label,
                config: config,
                enabled: input.enabled,
                automaticCooldownDisabled: input.automaticCooldownDisabled,
                supportsVision: input.supportsVision
            )
        } catch {
            throw ProxyError.message("编辑 API Key 账号失败：准备账号数据时出错，\(error.localizedDescription)")
        }

        let identityChanged = existingRecord.accountKey != prepared.accountKey
        let clearsCooldown = identityChanged || input.automaticCooldownDisabled
        let updatedRecord = AccountRecord(
            id: existingRecord.id,
            label: prepared.label,
            principalID: prepared.principalID,
            email: prepared.email,
            accountID: prepared.accountID,
            planType: prepared.planType,
            authMode: prepared.authMode,
            providerPreset: prepared.providerPreset,
            upstreamBaseURL: prepared.upstreamBaseURL,
            managedProxyNodeName: existingRecord.managedProxyNodeName,
            modelRouting: existingRecord.modelRouting,
            reasoningEffort: existingRecord.reasoningEffort,
            supportsVision: prepared.supportsVision,
            authJSON: prepared.authJSON,
            addedAt: existingRecord.addedAt,
            updatedAt: Helpers.now(),
            enabled: prepared.enabled,
            selectionOrder: existingRecord.selectionOrder,
            consecutiveFailureCount: clearsCooldown ? 0 : existingRecord.consecutiveFailureCount,
            cooldownUntil: clearsCooldown ? nil : existingRecord.cooldownUntil,
            automaticCooldownDisabled: input.automaticCooldownDisabled,
            usage: identityChanged ? nil : existingRecord.usage,
            usageWindowsVisible: identityChanged ? true : existingRecord.usageWindowsVisible,
            usageError: identityChanged
                ? nil
                : (input.automaticCooldownDisabled ? Self.usageErrorByClearingCooldownMessage(existingRecord.usageError) : existingRecord.usageError),
            authRefreshBlocked: identityChanged ? false : existingRecord.authRefreshBlocked,
            authRefreshError: identityChanged ? nil : existingRecord.authRefreshError
        )

        do {
            try self.store.updateManualAPIKeyAccount(id: id, record: updatedRecord)
        } catch {
            throw ProxyError.message("编辑 API Key 账号失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forID: id)
        } catch {
            throw ProxyError.message("编辑 API Key 账号失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    func updateAccountLabel(id: String, input: UpdateAccountLabelRequest) async throws -> AccountSummary {
        let existingRecord: AccountRecord
        do {
            existingRecord = try self.store.loadAccountRecord(id: id)
        } catch {
            throw ProxyError.message("更新账号名称失败：读取现有账号时出错，\(error.localizedDescription)")
        }

        guard existingRecord.authMode.isManualAPIKey == false else {
            throw ProxyError.message("更新账号名称失败：仅支持修改 OAuth 类型账号名称")
        }

        let trimmedLabel = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLabel.isEmpty == false else {
            throw ProxyError.message("更新账号名称失败：账号名称不能为空")
        }

        do {
            try self.store.updateAccountLabel(id: id, label: trimmedLabel)
        } catch {
            throw ProxyError.message("更新账号名称失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forID: id)
        } catch {
            throw ProxyError.message("更新账号名称失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    func updateAccountManagedProxyNode(
        id: String,
        input: UpdateAccountManagedProxyNodeRequest
    ) async throws -> AccountSummary {
        let existingRecord: AccountRecord
        do {
            existingRecord = try self.store.loadAccountRecord(id: id)
        } catch {
            throw ProxyError.message("更新账号出站节点失败：读取现有账号时出错，\(error.localizedDescription)")
        }

        do {
            try self.store.updateAccountManagedProxyNode(id: id, managedProxyNodeName: input.managedProxyNodeName)
        } catch {
            throw ProxyError.message("更新账号出站节点失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forID: existingRecord.id)
        } catch {
            throw ProxyError.message("更新账号出站节点失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    func clearAccountManagedProxyNodes() throws -> ClearAccountManagedProxyNodesResult {
        do {
            return .init(clearedCount: try self.store.clearAccountManagedProxyNodes())
        } catch {
            throw ProxyError.message("清空账号出站节点失败：写入本地账号池时出错，\(error.localizedDescription)")
        }
    }

    func updateAccountModelRouting(
        id: String,
        input: UpdateAccountModelRoutingRequest
    ) async throws -> AccountSummary {
        let existingRecord: AccountRecord
        do {
            existingRecord = try self.store.loadAccountRecord(id: id)
        } catch {
            throw ProxyError.message("更新账号模型转换失败：读取现有账号时出错，\(error.localizedDescription)")
        }

        do {
            try self.store.updateAccountModelRouting(id: id, modelRouting: input.modelRouting)
        } catch {
            throw ProxyError.message("更新账号模型转换失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forID: existingRecord.id)
        } catch {
            throw ProxyError.message("更新账号模型转换失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    func updateAccountReasoningEffort(
        id: String,
        input: UpdateAccountReasoningEffortRequest
    ) async throws -> AccountSummary {
        let existingRecord: AccountRecord
        do {
            existingRecord = try self.store.loadAccountRecord(id: id)
        } catch {
            throw ProxyError.message("更新账号思考强度失败：读取现有账号时出错，\(error.localizedDescription)")
        }

        guard existingRecord.authMode == .openAIAPIKey else {
            throw ProxyError.message("更新账号思考强度失败：仅支持 OpenAI API Key 类型账号")
        }
        let extracted = try AuthService.extractAuth(from: existingRecord.authJSON, secretStore: self.secretStore)
        let usesChatCompletions = (
            extracted.authMode == .openAIAPIKey
            && (
                (extracted.providerPreset == .genericOpenAICompatible && extracted.upstreamAdapter == .chatCompletions)
                || extracted.providerPreset.usesOpenAIChatCompletionsAPI
            )
        )
        guard usesChatCompletions else {
            throw ProxyError.message("更新账号思考强度失败：仅支持 Chat Completions 上游适配账号")
        }

        do {
            try self.store.updateAccountReasoningEffort(id: id, reasoningEffort: input.reasoningEffort)
        } catch {
            throw ProxyError.message("更新账号思考强度失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forID: existingRecord.id)
        } catch {
            throw ProxyError.message("更新账号思考强度失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    public func refreshAllUsage(config: AppConfig, forceRefresh: Bool = true) async throws -> [AccountSummary] {
        try self.repairStoredManualAccountsIfNeeded()
        let records = try self.store.listAccountRecords()
        guard records.isEmpty == false else {
            return try await self.listAccounts()
        }

        var nextIndex = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            let initialTaskCount = min(Self.refreshAllUsageConcurrencyLimit, records.count)
            for _ in 0..<initialTaskCount {
                let record = records[nextIndex]
                nextIndex += 1
                group.addTask {
                    let outcome = await self.refreshUsage(for: record, config: config, forceRefresh: forceRefresh)
                    try self.persistRefreshOutcome(record: record, outcome: outcome)
                }
            }

            while try await group.next() != nil {
                guard nextIndex < records.count else { continue }
                let record = records[nextIndex]
                nextIndex += 1
                group.addTask {
                    let outcome = await self.refreshUsage(for: record, config: config, forceRefresh: forceRefresh)
                    try self.persistRefreshOutcome(record: record, outcome: outcome)
                }
            }
        }
        return try await self.listAccounts()
    }

    @discardableResult
    public func repairStoredManualAccountsIfNeeded() throws -> Int {
        let purgedLegacyGemini = try self.purgeLegacyGeminiOAuthAccountsIfNeeded()
        let records = try self.store.listAccountRecords()
        var repairedCount = 0
        for record in records {
            let repaired = try self.repairedStoredManualAccountIfNeeded(record)
            if repaired != record {
                repairedCount += 1
            }
        }
        return purgedLegacyGemini + repairedCount
    }

    public func repairedStoredManualAccountIfNeeded(id: String) throws -> AccountRecord {
        try self.repairedStoredManualAccountIfNeeded(self.store.loadAccountRecord(id: id))
    }

    public func repairedStoredManualAccountIfNeeded(_ record: AccountRecord) throws -> AccountRecord {
        guard let repaired = try self.repairedManualAPIKeyRecord(record) else {
            return record
        }
        try self.store.updateManualAPIKeyAccount(id: record.id, record: repaired)
        return repaired
    }

    func updateUsageWindowsVisible(accountKey: String, visible: Bool) throws {
        try self.store.updateUsageWindowsVisible(accountKey: accountKey, visible: visible)
    }

    private func validatedManualAPIKeyAuthJSON(
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode?,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter?
    ) throws -> String {
        let effectiveBaseURLMode: ManualAPIKeyBaseURLMode? = providerPreset == .genericOpenAICompatible
            ? (baseURLMode ?? .exactAPIPrefix)
            : baseURLMode
        let effectiveUpstreamAdapter: ManualAPIKeyUpstreamAdapter?
        if providerPreset == .genericOpenAICompatible {
            effectiveUpstreamAdapter = upstreamAdapter ?? .responses
        } else {
            effectiveUpstreamAdapter = nil
        }
        let authJSON = try AuthService.normalizeManualAPIKeyInput(
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: providerPreset,
            baseURLMode: effectiveBaseURLMode,
            upstreamAdapter: effectiveUpstreamAdapter
        )
        let extracted = try AuthService.extractAuth(from: authJSON, secretStore: self.secretStore)
        if let error = OpenAICompatibleUpstream.configurationError(
            baseURL: extracted.upstreamBaseURL ?? providerPreset.defaultBaseURL,
            providerPreset: extracted.providerPreset,
            apiKey: extracted.accessToken
        ) {
            throw ProxyError.message(error)
        }
        return authJSON
    }

    private func validateManualAPIKeyConnection(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode?,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter?,
        modelRouting: AccountModelRoutingConfig?
    ) async throws {
        try await OpenAICompatibleUpstream.validateConnection(
            config: config,
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode,
            upstreamAdapter: upstreamAdapter,
            validationProbeModels: self.resolvedManualValidationProbeModels(
                providerPreset: providerPreset,
                modelRouting: modelRouting,
                config: config
            )
        )
    }

    private func resolvedManualValidationProbeModels(
        providerPreset: OpenAICompatibleProviderPreset,
        modelRouting: AccountModelRoutingConfig?,
        config: AppConfig
    ) -> [String] {
        switch providerPreset {
        case .genericOpenAICompatible, .googleGeminiCompatible, .aliyunQwenCodingPlan:
            return self.resolvedOpenAICompatibleValidationProbeModels(
                providerPreset: providerPreset,
                modelRouting: modelRouting
            )
        case .anthropicAPICompatible:
            return self.resolvedAnthropicValidationProbeModels(
                modelRouting: modelRouting,
                config: config
            )
        }
    }

    private func resolvedOpenAICompatibleValidationProbeModels(
        providerPreset: OpenAICompatibleProviderPreset,
        modelRouting: AccountModelRoutingConfig?
    ) -> [String] {
        let sourceModel = Self.defaultOpenAIValidationProbeSourceModel
        var models = self.preferredAccountValidationTargetModels(
            modelRouting: modelRouting,
            canonicalSourceModel: sourceModel
        )
        switch providerPreset {
        case .genericOpenAICompatible:
            self.appendValidationProbeModel(sourceModel, to: &models)
            for candidate in ProxyTranscoder.supportedModels {
                self.appendValidationProbeModel(candidate, to: &models)
            }
        case .googleGeminiCompatible, .aliyunQwenCodingPlan:
            for candidate in providerPreset.defaultValidationModelCandidates {
                self.appendValidationProbeModel(candidate, to: &models)
            }
        case .anthropicAPICompatible:
            break
        }
        return models
    }

    private func resolvedAnthropicValidationProbeModels(
        modelRouting: AccountModelRoutingConfig?,
        config: AppConfig
    ) -> [String] {
        let sourceModel = AnthropicUpstreamBridge.defaultOpenAIToAnthropicModel
        var models = self.preferredAccountValidationTargetModels(
            modelRouting: modelRouting,
            canonicalSourceModel: sourceModel
        )

        let mappedTarget = config.anthropicModelMappings.first(where: {
            $0.sourceModel == sourceModel
        })?.targetModel ?? config.anthropicDefaultTargetModel
        self.appendValidationProbeModel(
            self.resolveOpenAIToAnthropicValidationModel(requestedModel: mappedTarget),
            to: &models
        )
        self.appendValidationProbeModel(sourceModel, to: &models)
        return models
    }

    private func preferredAccountValidationTargetModels(
        modelRouting: AccountModelRoutingConfig?,
        canonicalSourceModel: String
    ) -> [String] {
        guard let modelRouting else { return [] }

        var models: [String] = []
        self.appendValidationProbeModel(
            modelRouting.resolvedTargetModel(for: canonicalSourceModel),
            to: &models
        )
        self.appendValidationProbeModel(modelRouting.defaultTargetModel, to: &models)
        for mapping in modelRouting.mappings {
            self.appendValidationProbeModel(mapping.targetModel, to: &models)
        }
        return models
    }

    private func appendValidationProbeModel(_ candidate: String?, to models: inout [String]) {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else { return }
        guard models.contains(trimmed) == false else { return }
        models.append(trimmed)
    }

    private func resolveOpenAIToAnthropicValidationModel(requestedModel: String) -> String {
        let trimmed = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
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

    private static var defaultOpenAIValidationProbeSourceModel: String {
        ProxyTranscoder.defaultModel
    }

    public func refreshUsage(id: String, config: AppConfig, forceRefresh: Bool = true) async throws -> AccountSummary {
        let record = try self.repairedStoredManualAccountIfNeeded(id: id)
        let outcome = await self.refreshUsage(for: record, config: config, forceRefresh: forceRefresh)
        try self.persistRefreshOutcome(record: record, outcome: outcome)
        return try self.summary(forID: id)
    }

    public func stopAccountCooldown(id: String) async throws -> AccountSummary {
        let record: AccountRecord
        do {
            record = try self.repairedStoredManualAccountIfNeeded(id: id)
        } catch {
            throw ProxyError.message("停止账号冷却失败：读取现有账号时出错，\(error.localizedDescription)")
        }
        guard record.authMode.isManualAPIKey else {
            throw ProxyError.message("停止账号冷却失败：仅支持 API Key 类型账号")
        }

        let usageError = Self.usageErrorByClearingCooldownMessage(record.usageError)
        do {
            try self.store.updateAccountFailureState(
                id: record.id,
                consecutiveFailureCount: 0,
                cooldownUntil: nil,
                usageError: usageError
            )
        } catch {
            throw ProxyError.message("停止账号冷却失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forID: id)
        } catch {
            throw ProxyError.message("停止账号冷却失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    public func updateAccountCooldownPolicy(
        id: String,
        automaticCooldownDisabled: Bool
    ) async throws -> AccountSummary {
        let record: AccountRecord
        do {
            record = try self.repairedStoredManualAccountIfNeeded(id: id)
        } catch {
            throw ProxyError.message("更新账号冷却策略失败：读取现有账号时出错，\(error.localizedDescription)")
        }
        guard record.authMode.isManualAPIKey else {
            throw ProxyError.message("更新账号冷却策略失败：仅支持 API Key 类型账号")
        }

        let usageError = automaticCooldownDisabled
            ? Self.usageErrorByClearingCooldownMessage(record.usageError)
            : record.usageError
        do {
            if automaticCooldownDisabled {
                try self.store.updateAccountFailureState(
                    id: record.id,
                    consecutiveFailureCount: 0,
                    cooldownUntil: nil,
                    usageError: usageError
                )
            }
            try self.store.updateAccountCooldownPolicy(
                id: record.id,
                automaticCooldownDisabled: automaticCooldownDisabled,
                clearExistingCooldown: false
            )
        } catch {
            throw ProxyError.message("更新账号冷却策略失败：写入本地账号池时出错，\(error.localizedDescription)")
        }

        do {
            return try self.summary(forID: id)
        } catch {
            throw ProxyError.message("更新账号冷却策略失败：回读账号摘要时出错，\(error.localizedDescription)")
        }
    }

    private func persistRefreshOutcome(record: AccountRecord, outcome: RefreshOutcome) throws {
        try self.store.updateUsage(
            accountKey: record.accountKey,
            usage: outcome.usage,
            usageError: outcome.usageError,
            planType: outcome.planType,
            authJSON: outcome.authJSON,
            usageWindowsVisible: outcome.usageWindowsVisible,
            authRefreshBlocked: outcome.authRefreshBlocked,
            authRefreshError: outcome.authRefreshError
        )
        try self.clearAPIKeyFailureStateIfNeeded(record: record, outcome: outcome)
    }

    public func setAccountEnabled(id: String, enabled: Bool) async throws -> AccountSummary {
        try self.store.setAccountEnabled(id: id, enabled: enabled)
        let summaries = try self.store.listAccountSummaries(currentAccountKey: self.currentAuthAccountKey())
        guard let summary = summaries.first(where: { $0.id == id }) else {
            throw ProxyError.message("账号状态更新后未找到账号")
        }
        return summary
    }

    public func reorderAccounts(ids: [String]) async throws -> [AccountSummary] {
        try self.store.reorderAccounts(ids: ids)
        return try self.store.listAccountSummaries(currentAccountKey: self.currentAuthAccountKey())
    }

    public func removeAccount(id: String) async throws -> DeleteAccountResult {
        let summaries = try self.store.listAccountSummaries(currentAccountKey: self.currentAuthAccountKey())
        guard let summary = summaries.first(where: { $0.id == id }) else {
            throw ProxyError.message("未找到要删除的账号")
        }
        let record = try self.store.loadAccountRecord(id: id)
        try self.store.deleteAccount(id: id)
        try? self.deleteOAuthSecretIfNeeded(for: record)
        return DeleteAccountResult(id: summary.id, accountKey: summary.accountKey, label: summary.label)
    }

    private func prepareAccount(
        text: String,
        sourceLabel: String?,
        config: AppConfig,
        enabled: Bool,
        managedProxyNodeName: String? = nil,
        modelRouting: AccountModelRoutingConfig? = nil,
        reasoningEffort: AccountReasoningEffortConfig? = nil,
        automaticCooldownDisabled: Bool = false,
        supportsVision: Bool? = nil
    ) async throws -> AccountRecord {
        let importedSupportsVision = Self.extractSupportsVisionOverride(from: text)
        let normalized = try AuthService.normalizeImportedAuthJSON(text)
        let extracted = try AuthService.extractAuth(from: normalized, secretStore: self.secretStore)
        if extracted.authMode.isManualAPIKey,
           let unsupportedGoogleCredential = OpenAICompatibleUpstream.googleGeminiCredentialConfigurationError(
               providerPreset: extracted.providerPreset,
               apiKey: extracted.accessToken
           )
        {
            throw ProxyError.message(unsupportedGoogleCredential)
        }
        if extracted.authMode == .geminiOAuth,
           AuthService.geminiAuthBackend(from: normalized) != GeminiAuthService.googleAIProBackend
        {
            throw ProxyError.message("旧版 Gemini OAuth 已下线，请使用新的 Google / Gemini Login 重新登录。")
        }
        let usage: UsageSnapshot?
        let usageError: String?
        if extracted.authMode == .chatGPT {
            do {
                usage = try await UsageService.fetchUsageSnapshot(accessToken: extracted.accessToken, accountID: extracted.accountID, config: config)
                usageError = nil
            } catch let error as UsageLimitReachedSignal {
                usage = UsageLimitWindowSupport.usageByApplyingLimit(
                    error,
                    to: nil,
                    fallbackPlanType: extracted.planType,
                    now: Helpers.now()
                )
                usageError = error.normalizedUsageError
            } catch {
                usage = nil
                usageError = error.localizedDescription
            }
        } else if extracted.authMode.isManualAPIKey {
            usage = nil
            do {
                let baseURL = extracted.upstreamBaseURL ?? extracted.providerPreset.defaultBaseURL
                if let configurationError = OpenAICompatibleUpstream.storedConfigurationError(
                    baseURL: baseURL,
                    providerPreset: extracted.providerPreset,
                    apiKey: extracted.accessToken
                ) {
                    usageError = configurationError
                } else {
                    try await self.validateManualAPIKeyConnection(
                        config: config,
                        baseURL: baseURL,
                        apiKey: extracted.accessToken,
                        providerPreset: extracted.providerPreset,
                        baseURLMode: extracted.baseURLMode,
                        upstreamAdapter: extracted.upstreamAdapter,
                        modelRouting: modelRouting
                    )
                    usageError = nil
                }
            } catch {
                usageError = error.localizedDescription
            }
        } else {
            usage = nil
            usageError = nil
        }
        return AccountRecord(
            label: self.accountLabel(sourceLabel: sourceLabel, extracted: extracted),
            principalID: extracted.principalID,
            email: extracted.email,
            accountID: extracted.accountID,
            planType: resolvedAccountPlanType(usage?.planType, fallback: extracted.planType),
            providerFamily: extracted.providerFamily,
            authMode: extracted.authMode,
            providerPreset: extracted.providerPreset,
            upstreamBaseURL: extracted.upstreamBaseURL,
            managedProxyNodeName: managedProxyNodeName,
            modelRouting: modelRouting,
            reasoningEffort: reasoningEffort ?? .defaultConfig,
            supportsVision: supportsVision
                ?? importedSupportsVision
                ?? Self.defaultSupportsVision(for: extracted.authMode),
            authJSON: normalized,
            enabled: enabled,
            automaticCooldownDisabled: extracted.authMode.isManualAPIKey ? automaticCooldownDisabled : false,
            usage: usage,
            usageError: usageError
        )
    }

    private static func defaultSupportsVision(for authMode: AccountAuthMode) -> Bool {
        authMode.isManualAPIKey == false
    }

    private static func extractSupportsVisionOverride(from text: String) -> Bool? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return self.boolValue(object["supportsVision"])
            ?? self.boolValue(object["supports_vision"])
            ?? self.boolValue((object["tokens"] as? [String: Any])?["supportsVision"])
            ?? self.boolValue((object["tokens"] as? [String: Any])?["supports_vision"])
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y", "on":
                return true
            case "false", "0", "no", "n", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func refreshUsage(for record: AccountRecord, config: AppConfig, forceRefresh: Bool) async -> RefreshOutcome {
        var authJSON = record.authJSON
        var authRefreshBlocked = record.authRefreshBlocked
        var authRefreshError = record.authRefreshError
        if forceRefresh && !authRefreshBlocked && AuthService.authNeedsRefresh(authJSON, secretStore: self.secretStore, leadTimeSeconds: 600) {
            do {
                authJSON = try await AuthService.refreshAuth(authJSON, config: config, secretStore: self.secretStore)
                authRefreshBlocked = false
                authRefreshError = nil
            } catch {
                authRefreshBlocked = true
                authRefreshError = error.localizedDescription
            }
        }
        do {
            let extracted = try AuthService.extractAuth(from: authJSON, secretStore: self.secretStore)
            if extracted.authMode == .chatGPT {
                do {
                    let usage = try await UsageService.fetchUsageSnapshot(accessToken: extracted.accessToken, accountID: extracted.accountID, config: config)
                    return RefreshOutcome(
                        usage: usage,
                        usageError: nil,
                        planType: resolvedAccountPlanType(usage.planType, fallback: extracted.planType),
                        authJSON: authJSON,
                        usageWindowsVisible: true,
                        authRefreshBlocked: false,
                        authRefreshError: nil
                    )
                } catch let error as UsageLimitReachedSignal {
                    let usage = UsageLimitWindowSupport.usageByApplyingLimit(
                        error,
                        to: record.usage,
                        fallbackPlanType: resolvedAccountPlanType(record.effectivePlanType, fallback: extracted.planType),
                        now: Helpers.now()
                    )
                    return RefreshOutcome(
                        usage: usage,
                        usageError: error.normalizedUsageError,
                        planType: resolvedAccountPlanType(
                            usage.planType,
                            fallback: resolvedAccountPlanType(
                                error.planType,
                                fallback: resolvedAccountPlanType(record.effectivePlanType, fallback: extracted.planType)
                            )
                        ),
                        authJSON: authJSON,
                        usageWindowsVisible: true,
                        authRefreshBlocked: false,
                        authRefreshError: nil
                    )
                }
            }
            if extracted.authMode == .geminiOAuth {
                return await self.refreshGeminiOAuthUsage(
                    for: extracted,
                    authJSON: authJSON,
                    record: record,
                    config: config,
                    authRefreshBlocked: authRefreshBlocked,
                    authRefreshError: authRefreshError
                )
            }
            return await self.refreshAPIKeyUsage(
                for: extracted,
                authJSON: authJSON,
                record: record,
                config: config
            )
        } catch {
            let configurationError = record.authMode.isManualAPIKey
                ? self.manualAPIKeyConfigurationError(for: record)
                : nil
            return RefreshOutcome(
                usage: record.usage,
                usageError: configurationError ?? error.localizedDescription,
                planType: record.effectivePlanType,
                authJSON: authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: authRefreshBlocked,
                authRefreshError: authRefreshError
            )
        }
    }

    private func refreshAPIKeyUsage(
        for extracted: ExtractedAuth,
        authJSON: String,
        record: AccountRecord,
        config: AppConfig
    ) async -> RefreshOutcome {
        guard extracted.authMode.isManualAPIKey else {
            return RefreshOutcome(
                usage: nil,
                usageError: nil,
                planType: resolvedAccountPlanType(extracted.planType, fallback: record.effectivePlanType),
                authJSON: authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: false,
                authRefreshError: nil
            )
        }
        do {
            let baseURL = extracted.upstreamBaseURL ?? record.upstreamBaseURL ?? extracted.providerPreset.defaultBaseURL
            if let configurationError = self.manualAPIKeyConfigurationError(
                baseURL: baseURL,
                providerPreset: extracted.providerPreset,
                apiKey: extracted.accessToken
            ) {
                return RefreshOutcome(
                    usage: nil,
                    usageError: configurationError,
                    planType: resolvedAccountPlanType(extracted.planType, fallback: record.effectivePlanType),
                    authJSON: authJSON,
                    usageWindowsVisible: nil,
                    authRefreshBlocked: false,
                    authRefreshError: nil
                )
            }
            try await self.validateManualAPIKeyConnection(
                config: config,
                baseURL: baseURL,
                apiKey: extracted.accessToken,
                providerPreset: extracted.providerPreset,
                baseURLMode: extracted.baseURLMode,
                upstreamAdapter: extracted.upstreamAdapter,
                modelRouting: record.modelRouting
            )
            return RefreshOutcome(
                usage: nil,
                usageError: nil,
                planType: resolvedAccountPlanType(extracted.planType, fallback: record.effectivePlanType),
                authJSON: authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: false,
                authRefreshError: nil
            )
        } catch {
            return RefreshOutcome(
                usage: nil,
                usageError: error.localizedDescription,
                planType: resolvedAccountPlanType(extracted.planType, fallback: record.effectivePlanType),
                authJSON: authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: false,
                authRefreshError: nil
            )
        }
    }

    private func refreshGeminiOAuthUsage(
        for extracted: ExtractedAuth,
        authJSON: String,
        record: AccountRecord,
        config: AppConfig,
        authRefreshBlocked: Bool,
        authRefreshError: String?
    ) async -> RefreshOutcome {
        do {
            let validatedAuthJSON = try await GeminiAuthService.validateConnection(
                auth: extracted,
                authJSON: authJSON,
                config: config
            )
            let validatedAuth = try AuthService.extractAuth(from: validatedAuthJSON, secretStore: self.secretStore)
            return RefreshOutcome(
                usage: nil,
                usageError: nil,
                planType: resolvedAccountPlanType(validatedAuth.planType, fallback: record.effectivePlanType),
                authJSON: validatedAuthJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: authRefreshBlocked,
                authRefreshError: authRefreshError
            )
        } catch {
            return RefreshOutcome(
                usage: nil,
                usageError: error.localizedDescription,
                planType: resolvedAccountPlanType(extracted.planType, fallback: record.effectivePlanType),
                authJSON: authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: authRefreshBlocked,
                authRefreshError: authRefreshError
            )
        }
    }

    private func expandAuthImportInput(_ item: AuthJsonImportInput) throws -> [AuthJsonImportInput] {
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw ProxyError.message("文件内容为空")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        if let object = json as? [String: Any], let accounts = object["accounts"] as? [[String: Any]] {
            return try accounts.map { account in
                let authJSON: String
                if let raw = account["authJSON"] as? String {
                    authJSON = raw
                } else if let raw = account["auth_json"] as? String {
                    authJSON = raw
                } else {
                    throw ProxyError.message("导入备份缺少 authJSON")
                }
                return AuthJsonImportInput(
                    source: item.source,
                    content: authJSON,
                    label: account["label"] as? String ?? item.label,
                    enabled: self.importEnabledFlag(from: account, fallback: item.enabled),
                    managedProxyNodeName: (account["managedProxyNodeName"] as? String) ?? (account["managed_proxy_node_name"] as? String),
                    modelRouting: try Self.decodeAccountModelRouting(
                        from: account["modelRouting"] ?? account["model_routing"]
                    ),
                    reasoningEffort: try Self.decodeAccountReasoningEffort(
                        from: account["reasoningEffort"] ?? account["reasoning_effort"]
                    ),
                    automaticCooldownDisabled: (account["automaticCooldownDisabled"] as? Bool)
                        ?? (account["automatic_cooldown_disabled"] as? Bool)
                )
            }
        }
        if let array = json as? [[String: Any]] {
            return try array.map { object in
                let authJSONData = try JSONSerialization.data(withJSONObject: object)
                return AuthJsonImportInput(
                    source: item.source,
                    content: String(decoding: authJSONData, as: UTF8.self),
                    label: item.label,
                    enabled: self.importEnabledFlag(from: object, fallback: item.enabled),
                    reasoningEffort: try Self.decodeAccountReasoningEffort(
                        from: object["reasoningEffort"] ?? object["reasoning_effort"]
                    ) ?? item.reasoningEffort,
                    automaticCooldownDisabled: item.automaticCooldownDisabled
                )
            }
        }
        if let object = json as? [String: Any] {
            return [
                AuthJsonImportInput(
                    source: item.source,
                    content: item.content,
                    label: item.label,
                    enabled: self.importEnabledFlag(from: object, fallback: item.enabled),
                    managedProxyNodeName: item.managedProxyNodeName,
                    modelRouting: item.modelRouting,
                    reasoningEffort: try Self.decodeAccountReasoningEffort(
                        from: object["reasoningEffort"] ?? object["reasoning_effort"]
                    ) ?? item.reasoningEffort,
                    automaticCooldownDisabled: item.automaticCooldownDisabled
                ),
            ]
        }
        return [item]
    }

    private func importEnabledFlag(from object: [String: Any], fallback: Bool?) -> Bool? {
        if let fallback {
            return fallback
        }
        if let enabled = object["enabled"] as? Bool {
            return enabled
        }
        if let disabled = object["disabled"] as? Bool {
            return !disabled
        }
        return nil
    }

    private func accountLabel(sourceLabel: String?, extracted: ExtractedAuth) -> String {
        if let sourceLabel, !sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let email = extracted.email, !email.isEmpty {
            return email
        }
        if extracted.authMode.isManualAPIKey {
            let baseURL = extracted.upstreamBaseURL ?? extracted.providerPreset.defaultBaseURL
            return OpenAICompatibleUpstream.defaultAccountLabel(
                baseURL: baseURL,
                apiKey: extracted.accessToken,
                providerPreset: extracted.providerPreset
            )
        }
        if extracted.authMode == .anthropicSubscriptionOAuth {
            return "Claude \(String(extracted.accountID.prefix(6)))"
        }
        if extracted.authMode == .geminiOAuth {
            return "Google / Gemini \(String(extracted.accountID.prefix(6)))"
        }
        return "Codex \(String(extracted.accountID.prefix(6)))"
    }

    private func purgeLegacyGeminiOAuthAccountsIfNeeded() throws -> Int {
        let records = try self.store.listAccountRecords()
        var removed = 0
        for record in records where record.authMode == .geminiOAuth {
            if AuthService.geminiAuthBackend(from: record.authJSON) == GeminiAuthService.googleAIProBackend {
                continue
            }
            try self.store.deleteAccount(id: record.id)
            try? self.deleteOAuthSecretIfNeeded(for: record)
            removed += 1
        }
        return removed
    }

    private func deleteOAuthSecretIfNeeded(for record: AccountRecord) throws {
        guard let payload = try? JSONSerialization.jsonObject(with: Data(record.authJSON.utf8)) as? [String: Any] else {
            return
        }
        if record.authMode == .anthropicSubscriptionOAuth,
           let secretRef = self.firstNonEmpty([
                payload["secret_ref"] as? String,
                payload["secretRef"] as? String,
           ])
        {
            try self.secretStore.deleteAnthropicOAuthSecret(ref: secretRef)
            return
        }
        if record.authMode == .geminiOAuth,
           let secretRef = self.firstNonEmpty([
                payload["secret_ref"] as? String,
                payload["secretRef"] as? String,
           ])
        {
            try self.secretStore.deleteGeminiOAuthSecret(ref: secretRef)
        }
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func summary(forAccountKey accountKey: String) throws -> AccountSummary {
        let summaries = try self.store.listAccountSummaries(currentAccountKey: self.currentAuthAccountKey())
        if let summary = summaries.first(where: { $0.accountKey == accountKey }) {
            return summary
        }
        throw ProxyError.message("账号更新后未找到账号")
    }

    private func summary(forID id: String) throws -> AccountSummary {
        let summaries = try self.store.listAccountSummaries(currentAccountKey: self.currentAuthAccountKey())
        if let summary = summaries.first(where: { $0.id == id }) {
            return summary
        }
        throw ProxyError.message("账号更新后未找到账号")
    }

    private func clearAPIKeyFailureStateIfNeeded(record: AccountRecord, outcome: RefreshOutcome) throws {
        guard record.authMode.isManualAPIKey, outcome.usageError == nil else { return }
        guard record.consecutiveFailureCount > 0 || record.cooldownUntil != nil else { return }
        try self.store.updateAccountFailureState(id: record.id, consecutiveFailureCount: 0, cooldownUntil: nil)
    }

    private static func usageErrorByClearingCooldownMessage(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else {
            return nil
        }
        let lower = trimmed.lowercased()
        let patterns = [
            "cooling down",
            "cooldown",
            "冷却",
        ]
        return patterns.contains(where: { lower.contains($0) }) ? nil : value
    }

    private func repairedManualAPIKeyRecord(_ record: AccountRecord) throws -> AccountRecord? {
        guard record.authMode.isManualAPIKey else {
            return nil
        }
        guard let normalized = try? AuthService.normalizeImportedAuthJSON(record.authJSON),
              let extracted = try? AuthService.extractAuth(from: normalized, secretStore: self.secretStore)
        else {
            return nil
        }

        let normalizedRecord = AccountRecord(
            id: record.id,
            label: record.label,
            principalID: extracted.principalID,
            email: record.email,
            accountID: extracted.accountID,
            planType: record.planType ?? extracted.planType,
            providerFamily: extracted.providerFamily,
            authMode: extracted.authMode,
            providerPreset: extracted.providerPreset,
            upstreamBaseURL: extracted.upstreamBaseURL,
            managedProxyNodeName: record.managedProxyNodeName,
            modelRouting: record.modelRouting,
            reasoningEffort: record.reasoningEffort,
            supportsVision: record.supportsVision,
            authJSON: normalized,
            addedAt: record.addedAt,
            updatedAt: Helpers.now(),
            enabled: record.enabled,
            selectionOrder: record.selectionOrder,
            consecutiveFailureCount: record.consecutiveFailureCount,
            cooldownUntil: record.cooldownUntil,
            automaticCooldownDisabled: record.automaticCooldownDisabled,
            usage: record.usage,
            usageError: record.usageError,
            authRefreshBlocked: record.authRefreshBlocked,
            authRefreshError: record.authRefreshError
        )
        var repaired = normalizedRecord
        if let configurationError = self.manualAPIKeyConfigurationError(
            baseURL: extracted.upstreamBaseURL ?? record.upstreamBaseURL ?? extracted.providerPreset.defaultBaseURL,
            providerPreset: extracted.providerPreset,
            apiKey: extracted.accessToken
        ) {
            repaired.usageError = configurationError
        }

        guard repaired != record else {
            return nil
        }
        repaired.updatedAt = Helpers.now()
        return repaired
    }

    private func manualAPIKeyConfigurationError(
        for record: AccountRecord
    ) -> String? {
        if let extracted = try? AuthService.extractAuth(from: record.authJSON, secretStore: self.secretStore) {
            return self.manualAPIKeyConfigurationError(
                baseURL: extracted.upstreamBaseURL ?? record.upstreamBaseURL ?? extracted.providerPreset.defaultBaseURL,
                providerPreset: extracted.providerPreset,
                apiKey: extracted.accessToken
            )
        }

        let metadata = AuthService.extractAuthMetadata(from: record.authJSON)
        let providerPreset = metadata.authMode.isManualAPIKey ? metadata.providerPreset : record.providerPreset
        return self.manualAPIKeyConfigurationError(
            baseURL: metadata.upstreamBaseURL ?? record.upstreamBaseURL ?? providerPreset.defaultBaseURL,
            providerPreset: providerPreset,
            apiKey: nil
        )
    }

    private func manualAPIKeyConfigurationError(
        baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset,
        apiKey: String?
    ) -> String? {
        OpenAICompatibleUpstream.storedConfigurationError(
            baseURL: baseURL,
            providerPreset: providerPreset,
            apiKey: apiKey
        )
    }

    private static func decodeAccountModelRouting(from value: Any?) throws -> AccountModelRoutingConfig? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value)
        return AccountSummary.normalizedModelRouting(try Helpers.readJSON(AccountModelRoutingConfig.self, from: data))
    }

    private static func decodeAccountReasoningEffort(from value: Any?) throws -> AccountReasoningEffortConfig? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try Helpers.readJSON(AccountReasoningEffortConfig.self, from: data)
    }

    private func manualAPIKeyEditBaseURL(
        upstreamBaseURL: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode?
    ) -> String {
        guard providerPreset == .genericOpenAICompatible else {
            return upstreamBaseURL
        }
        return (try? OpenAICompatibleUpstream.apiBaseURL(
            from: upstreamBaseURL,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode
        )) ?? upstreamBaseURL
    }
}

private struct RefreshOutcome {
    var usage: UsageSnapshot?
    var usageError: String?
    var planType: String?
    var authJSON: String?
    var usageWindowsVisible: Bool?
    var authRefreshBlocked: Bool
    var authRefreshError: String?
}
