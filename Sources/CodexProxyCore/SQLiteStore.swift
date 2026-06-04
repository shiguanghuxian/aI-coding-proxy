import Foundation
import CSQLite3

public struct ProxyAPIKeyUsageAggregateRow: Sendable {
    public var apiKeyHash: String
    public var apiKey: String
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
        requestCount: Int64,
        failureCount: Int64,
        authFailureCount: Int64,
        rateLimitCount: Int64,
        quotaFailureCount: Int64,
        averageLatencyMS: Int64,
        totalInputTokens: Int64,
        totalOutputTokens: Int64,
        totalTokens: Int64,
        lastUsedAt: Int64?
    ) {
        self.apiKeyHash = apiKeyHash
        self.apiKey = apiKey
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
}

public final class SQLiteStore: @unchecked Sendable {
    private let db: OpaquePointer?
    private let dataDirectory: URL
    private let secretStore: SecretStore
    private let databaseLock = NSRecursiveLock()

    public init(dataDirectory: URL, secretStore: SecretStore) throws {
        self.dataDirectory = dataDirectory
        self.secretStore = secretStore
        try Helpers.ensureDirectory(dataDirectory)

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            Paths.databaseURL(in: dataDirectory).path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            throw ProxyError.message(Self.lastSQLiteError(for: handle))
        }
        self.db = handle
        try Self.migrate(on: handle)
    }

    deinit {
        self.databaseLock.lock()
        defer { self.databaseLock.unlock() }
        sqlite3_close(self.db)
    }

    public func loadConfig() throws -> AppConfig {
        if let json = try self.readSetting(key: "app_config"), let data = json.data(using: .utf8) {
            return try Helpers.readJSON(AppConfig.self, from: data)
        }
        let config = AppConfig()
        try self.saveConfig(config)
        return config
    }

    public func saveConfig(_ config: AppConfig) throws {
        let data = try Helpers.encodeJSON(config, pretty: true)
        try self.writeSetting(key: "app_config", value: String(decoding: data, as: UTF8.self))
    }

    private func migrateProxyAPIKeyAllowedAccountKeyIfNeeded(
        from oldAccountKey: String,
        to newAccountKey: String
    ) throws {
        let oldAccountKey = oldAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAccountKey = newAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldAccountKey.isEmpty == false, newAccountKey.isEmpty == false, oldAccountKey != newAccountKey else {
            return
        }
        guard let json = try self.readSetting(key: "app_config"), let data = json.data(using: .utf8) else {
            return
        }

        var config = try Helpers.readJSON(AppConfig.self, from: data)
        var didChange = false
        config.proxyAPIKeys = config.proxyAPIKeys.map { record in
            var copy = record
            let migratedKeys = copy.allowedAccountKeys.map { accountKey in
                accountKey == oldAccountKey ? newAccountKey : accountKey
            }
            let normalizedKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(migratedKeys)
            if normalizedKeys != copy.allowedAccountKeys {
                copy.allowedAccountKeys = normalizedKeys
                didChange = true
            }
            return copy
        }

        if didChange {
            try self.saveConfig(config)
        }
    }

    public func upsertAccount(_ record: AccountRecord) throws -> Bool {
        let key = try self.secretStore.masterKey()
        let encrypted = try CryptoBox.seal(Data(record.authJSON.utf8), using: key)
        let existing = try self.lookupExistingAccountMetadata(accountKey: record.accountKey)
        let usageData = try record.usage.map { try Helpers.encodeJSON($0) }
        let modelRoutingJSON = try record.modelRouting.map {
            String(decoding: try Helpers.encodeJSON($0), as: UTF8.self)
        }
        let reasoningEffortJSON = String(decoding: try Helpers.encodeJSON(record.reasoningEffort), as: UTF8.self)
        let selectionOrder: Int64
        let nextSelectionOrder = try self.nextAccountSelectionOrder()
        if let existingSelectionOrder = existing?.selectionOrder {
            selectionOrder = existingSelectionOrder
        } else if record.selectionOrder >= nextSelectionOrder {
            selectionOrder = record.selectionOrder
        } else {
            selectionOrder = nextSelectionOrder
        }
        let consecutiveFailureCount = existing?.consecutiveFailureCount ?? record.consecutiveFailureCount
        let cooldownUntil = existing?.cooldownUntil ?? record.cooldownUntil
        let automaticCooldownDisabled = existing?.automaticCooldownDisabled ?? record.automaticCooldownDisabled
        let usageWindowsVisible = existing?.usageWindowsVisible ?? record.usageWindowsVisible
        let managedProxyNodeName = existing?.managedProxyNodeName ?? record.managedProxyNodeName
        let modelRouting = existing?.modelRouting ?? modelRoutingJSON
        let reasoningEffort = existing?.reasoningEffort ?? reasoningEffortJSON
        let supportsVision = existing?.supportsVision ?? record.supportsVision

        let sql = """
        INSERT OR REPLACE INTO accounts (
            id, label, principal_id, email, account_id, plan_type, auth_blob, added_at, updated_at,
            enabled, selection_order, consecutive_failure_count, cooldown_until, usage_json, usage_error,
            auth_refresh_blocked, auth_refresh_error, auth_mode, provider_preset, upstream_base_url, usage_windows_visible,
            managed_proxy_node_name, model_routing_json, reasoning_effort_json, automatic_cooldown_disabled, supports_vision
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try self.execute(sql, bindings: [
            .text(existing?.id ?? record.id),
            .text(record.label),
            .text(record.principalID),
            .text(record.email),
            .text(record.accountID),
            .text(record.planType),
            .blob(encrypted),
            .int(existing?.addedAt ?? record.addedAt),
            .int(record.updatedAt),
            .int((existing?.enabled ?? record.enabled) ? 1 : 0),
            .int(selectionOrder),
            .int(consecutiveFailureCount),
            .int(cooldownUntil),
            .blob(usageData),
            .text(record.usageError),
            .int(record.authRefreshBlocked ? 1 : 0),
            .text(record.authRefreshError),
            .text(record.authMode.rawValue),
            .text(record.providerPreset.rawValue),
            .text(record.upstreamBaseURL),
            .int(usageWindowsVisible ? 1 : 0),
            .text(managedProxyNodeName),
            .text(modelRouting),
            .text(reasoningEffort),
            .int(automaticCooldownDisabled ? 1 : 0),
            .int(supportsVision ? 1 : 0),
        ])
        return existing != nil
    }

    public func deleteAccount(id: String) throws {
        try self.withDatabaseTransaction {
            let deletedRow = try self.querySingle(
                "SELECT selection_order FROM accounts WHERE id = ?;",
                bindings: [.text(id)]
            )
            try self.execute("DELETE FROM accounts WHERE id = ?;", bindings: [.text(id)])
            guard sqlite3_changes(self.db) > 0 else {
                throw ProxyError.message("未找到要删除的账号")
            }
            if deletedRow != nil {
                try self.compactAccountSelectionOrder()
            }
        }
    }

    public func updateAccountLabel(accountKey: String, label: String) throws {
        try self.execute(
            "UPDATE accounts SET label = ?, updated_at = ? WHERE principal_id || '|' || account_id = ?;",
            bindings: [.text(label), .int(Helpers.now()), .text(accountKey)]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func updateAccountLabel(id: String, label: String) throws {
        try self.execute(
            "UPDATE accounts SET label = ?, updated_at = ? WHERE id = ?;",
            bindings: [.text(label), .int(Helpers.now()), .text(id)]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func updateAccountManagedProxyNode(id: String, managedProxyNodeName: String?) throws {
        try self.execute(
            "UPDATE accounts SET managed_proxy_node_name = ?, updated_at = ? WHERE id = ?;",
            bindings: [.text(AccountSummary.normalizedManagedProxyNodeName(managedProxyNodeName)), .int(Helpers.now()), .text(id)]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func clearAccountManagedProxyNodes() throws -> Int {
        try self.execute(
            """
            UPDATE accounts
            SET managed_proxy_node_name = NULL, updated_at = ?
            WHERE managed_proxy_node_name IS NOT NULL
              AND TRIM(managed_proxy_node_name) != '';
            """,
            bindings: [.int(Helpers.now())]
        )
        return Int(sqlite3_changes(self.db))
    }

    public func updateAccountModelRouting(id: String, modelRouting: AccountModelRoutingConfig?) throws {
        let modelRoutingJSON = try modelRouting.map {
            String(decoding: try Helpers.encodeJSON($0), as: UTF8.self)
        }
        try self.execute(
            "UPDATE accounts SET model_routing_json = ?, updated_at = ? WHERE id = ?;",
            bindings: [.text(modelRoutingJSON), .int(Helpers.now()), .text(id)]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func updateAccountReasoningEffort(id: String, reasoningEffort: AccountReasoningEffortConfig) throws {
        let reasoningEffortJSON = String(decoding: try Helpers.encodeJSON(reasoningEffort), as: UTF8.self)
        try self.execute(
            "UPDATE accounts SET reasoning_effort_json = ?, updated_at = ? WHERE id = ?;",
            bindings: [.text(reasoningEffortJSON), .int(Helpers.now()), .text(id)]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func setAccountEnabled(id: String, enabled: Bool) throws {
        try self.execute(
            "UPDATE accounts SET enabled = ?, updated_at = ? WHERE id = ?;",
            bindings: [.int(enabled ? 1 : 0), .int(Helpers.now()), .text(id)]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func updateManualAPIKeyAccount(id: String, record: AccountRecord) throws {
        try self.withDatabaseTransaction {
            guard let existingRow = try self.querySingle(
                "SELECT principal_id, account_id FROM accounts WHERE id = ?;",
                bindings: [.text(id)]
            ) else {
                throw ProxyError.message("未找到要更新的账号")
            }
            let previousAccountKey = "\(existingRow.text("principal_id"))|\(existingRow.text("account_id"))"

            if let existing = try self.lookupExistingAccountMetadata(accountKey: record.accountKey),
               existing.id != id
            {
                throw ProxyError.message("已存在相同的 API Key 账号")
            }

            let key = try self.secretStore.masterKey()
            let encrypted = try CryptoBox.seal(Data(record.authJSON.utf8), using: key)
            let usageData = try record.usage.map { try Helpers.encodeJSON($0) }
            let modelRoutingJSON = try record.modelRouting.map {
                String(decoding: try Helpers.encodeJSON($0), as: UTF8.self)
            }
            let reasoningEffortJSON = String(decoding: try Helpers.encodeJSON(record.reasoningEffort), as: UTF8.self)

            try self.execute(
                """
                UPDATE accounts
                SET label = ?, principal_id = ?, email = ?, account_id = ?, plan_type = ?, auth_blob = ?, updated_at = ?,
                    enabled = ?, selection_order = ?, consecutive_failure_count = ?, cooldown_until = ?, usage_json = ?,
                    usage_error = ?, auth_refresh_blocked = ?, auth_refresh_error = ?, auth_mode = ?, provider_preset = ?,
                    upstream_base_url = ?, usage_windows_visible = ?, managed_proxy_node_name = ?, model_routing_json = ?,
                    reasoning_effort_json = ?, automatic_cooldown_disabled = ?, supports_vision = ?
                WHERE id = ?;
                """,
                bindings: [
                    .text(record.label),
                    .text(record.principalID),
                    .text(record.email),
                    .text(record.accountID),
                    .text(record.planType),
                    .blob(encrypted),
                    .int(record.updatedAt),
                    .int(record.enabled ? 1 : 0),
                    .int(record.selectionOrder),
                    .int(record.consecutiveFailureCount),
                    .int(record.cooldownUntil),
                    .blob(usageData),
                    .text(record.usageError),
                    .int(record.authRefreshBlocked ? 1 : 0),
                    .text(record.authRefreshError),
                    .text(record.authMode.rawValue),
                    .text(record.providerPreset.rawValue),
                    .text(record.upstreamBaseURL),
                    .int(record.usageWindowsVisible ? 1 : 0),
                    .text(record.managedProxyNodeName),
                    .text(modelRoutingJSON),
                    .text(reasoningEffortJSON),
                    .int(record.automaticCooldownDisabled ? 1 : 0),
                    .int(record.supportsVision ? 1 : 0),
                    .text(id),
                ]
            )
            guard sqlite3_changes(self.db) > 0 else {
                throw ProxyError.message("未找到要更新的账号")
            }

            try self.migrateProxyAPIKeyAllowedAccountKeyIfNeeded(
                from: previousAccountKey,
                to: record.accountKey
            )
        }
    }

    public func updateAccountFailureState(
        id: String,
        consecutiveFailureCount: Int64,
        cooldownUntil: Int64?
    ) throws {
        try self.execute(
            """
            UPDATE accounts
            SET consecutive_failure_count = ?, cooldown_until = ?
            WHERE id = ?;
            """,
            bindings: [
                .int(consecutiveFailureCount),
                .int(cooldownUntil),
                .text(id),
            ]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func updateAccountFailureState(
        id: String,
        consecutiveFailureCount: Int64,
        cooldownUntil: Int64?,
        usageError: String?
    ) throws {
        try self.execute(
            """
            UPDATE accounts
            SET consecutive_failure_count = ?, cooldown_until = ?, usage_error = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: [
                .int(consecutiveFailureCount),
                .int(cooldownUntil),
                .text(usageError),
                .int(Helpers.now()),
                .text(id),
            ]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func updateAccountCooldownPolicy(
        id: String,
        automaticCooldownDisabled: Bool,
        clearExistingCooldown: Bool
    ) throws {
        let sql: String
        let bindings: [Binding]
        if clearExistingCooldown {
            sql = """
            UPDATE accounts
            SET automatic_cooldown_disabled = ?, consecutive_failure_count = ?, cooldown_until = ?, usage_error = ?, updated_at = ?
            WHERE id = ?;
            """
            bindings = [
                .int(automaticCooldownDisabled ? 1 : 0),
                .int(0),
                .int(nil),
                .text(nil),
                .int(Helpers.now()),
                .text(id),
            ]
        } else {
            sql = """
            UPDATE accounts
            SET automatic_cooldown_disabled = ?, updated_at = ?
            WHERE id = ?;
            """
            bindings = [
                .int(automaticCooldownDisabled ? 1 : 0),
                .int(Helpers.now()),
                .text(id),
            ]
        }
        try self.execute(sql, bindings: bindings)
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func reorderAccounts(ids: [String]) throws {
        let trimmedIDs = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmedIDs.allSatisfy({ !$0.isEmpty }) else {
            throw ProxyError.message("账号顺序列表不能为空或包含空 ID")
        }
        guard Set(trimmedIDs).count == trimmedIDs.count else {
            throw ProxyError.message("账号顺序列表包含重复 ID")
        }

        let storedIDs = try self.query("SELECT id FROM accounts ORDER BY selection_order ASC, id ASC;").map { $0.text("id") }
        guard trimmedIDs.count == storedIDs.count else {
            throw ProxyError.message("账号顺序列表必须包含全部账号")
        }
        guard Set(trimmedIDs) == Set(storedIDs) else {
            throw ProxyError.message("账号顺序列表包含未知账号或缺少账号")
        }

        try self.withDatabaseTransaction {
            for (index, id) in trimmedIDs.enumerated() {
                try self.execute(
                    "UPDATE accounts SET selection_order = ? WHERE id = ?;",
                    bindings: [.int(Int64(index)), .text(id)]
                )
            }
        }
    }

    public func listAccountRecords() throws -> [AccountRecord] {
        let rows = try self.query(
            """
            SELECT id, label, principal_id, email, account_id, plan_type, auth_blob, added_at, updated_at,
                   enabled, selection_order, consecutive_failure_count, cooldown_until, usage_json, usage_error,
                   auth_refresh_blocked, auth_refresh_error, auth_mode, provider_preset, upstream_base_url,
                   managed_proxy_node_name, model_routing_json, reasoning_effort_json,
                   usage_windows_visible, automatic_cooldown_disabled, supports_vision
            FROM accounts
            ORDER BY selection_order ASC, label COLLATE NOCASE ASC, id ASC;
            """
        )
        let key = try self.secretStore.masterKey()
        return try rows.map { row in
            let authBlob = row.blob("auth_blob")
            let plaintext = try CryptoBox.open(authBlob, using: key)
            let usage: UsageSnapshot?
            if let usageBlob = row.optionalBlob("usage_json"), !usageBlob.isEmpty {
                usage = try Helpers.readJSON(UsageSnapshot.self, from: usageBlob)
            } else {
                usage = nil
            }
            let authJSON = String(decoding: plaintext, as: UTF8.self)
            let metadata = self.accountMetadata(
                authJSON: authJSON,
                fallbackAuthMode: row.optionalText("auth_mode"),
                fallbackProviderPreset: row.optionalText("provider_preset"),
                fallbackUpstreamBaseURL: row.optionalText("upstream_base_url")
            )
            let modelRouting = try self.accountModelRouting(from: row.optionalText("model_routing_json"))
            let reasoningEffort = try self.accountReasoningEffort(from: row.optionalText("reasoning_effort_json"))
            return AccountRecord(
                id: row.text("id"),
                label: row.text("label"),
                principalID: row.text("principal_id"),
                email: row.optionalText("email"),
                accountID: row.text("account_id"),
                planType: resolvedAccountPlanType(usage?.planType, fallback: row.optionalText("plan_type")),
                providerFamily: metadata.providerFamily,
                authMode: metadata.authMode,
                providerPreset: metadata.providerPreset,
                upstreamBaseURL: metadata.upstreamBaseURL,
                managedProxyNodeName: row.optionalText("managed_proxy_node_name"),
                modelRouting: modelRouting,
                reasoningEffort: reasoningEffort,
                supportsVision: row.int("supports_vision") == 1,
                authJSON: authJSON,
                addedAt: row.int("added_at"),
                updatedAt: row.int("updated_at"),
                enabled: row.int("enabled") == 1,
                selectionOrder: row.int("selection_order"),
                consecutiveFailureCount: row.int("consecutive_failure_count"),
                cooldownUntil: row.optionalInt("cooldown_until"),
                automaticCooldownDisabled: row.int("automatic_cooldown_disabled") == 1,
                usage: usage,
                usageWindowsVisible: row.int("usage_windows_visible") == 1,
                usageError: row.optionalText("usage_error"),
                authRefreshBlocked: row.int("auth_refresh_blocked") == 1,
                authRefreshError: row.optionalText("auth_refresh_error")
            )
        }
    }

    public func listAccountSummaries(
        currentAccountKey: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [AccountSummary] {
        let rows = try self.query(
            """
            SELECT id, label, principal_id, email, account_id, plan_type, added_at, updated_at,
                   enabled, selection_order, consecutive_failure_count, cooldown_until, usage_json, usage_error,
                   auth_refresh_blocked, auth_refresh_error, auth_blob, auth_mode, provider_preset, upstream_base_url,
                   managed_proxy_node_name, model_routing_json, reasoning_effort_json,
                   usage_windows_visible, automatic_cooldown_disabled, supports_vision
            FROM accounts
            ORDER BY selection_order ASC, label COLLATE NOCASE ASC, id ASC;
            """
        )
        let todayTokenUsageByAccountKey = try self.loadTodayTokenUsageByAccountKey(now: now, calendar: calendar)
        let key = try self.secretStore.masterKey()
        return try rows.map { row in
            let usage: UsageSnapshot?
            if let usageBlob = row.optionalBlob("usage_json"), !usageBlob.isEmpty {
                usage = try Helpers.readJSON(UsageSnapshot.self, from: usageBlob)
            } else {
                usage = nil
            }
            let authBlob = row.blob("auth_blob")
            let plaintext = try CryptoBox.open(authBlob, using: key)
            let authJSON = String(decoding: plaintext, as: UTF8.self)
            let metadata = self.accountMetadata(
                authJSON: authJSON,
                fallbackAuthMode: row.optionalText("auth_mode"),
                fallbackProviderPreset: row.optionalText("provider_preset"),
                fallbackUpstreamBaseURL: row.optionalText("upstream_base_url")
            )
            let modelRouting = try self.accountModelRouting(from: row.optionalText("model_routing_json"))
            let reasoningEffort = try self.accountReasoningEffort(from: row.optionalText("reasoning_effort_json"))
            let accountKey = "\(row.text("principal_id"))|\(row.text("account_id"))"
            let todayTokenUsage = (
                metadata.authMode.isManualAPIKey
                    || metadata.authMode == .anthropicSubscriptionOAuth
                    || metadata.authMode == .geminiOAuth
            )
                ? (todayTokenUsageByAccountKey[accountKey] ?? AccountTodayTokenUsage())
                : nil
            return AccountSummary(
                id: row.text("id"),
                label: row.text("label"),
                email: row.optionalText("email"),
                accountKey: accountKey,
                accountID: row.text("account_id"),
                planType: resolvedAccountPlanType(usage?.planType, fallback: row.optionalText("plan_type")),
                providerFamily: metadata.providerFamily,
                authMode: metadata.authMode,
                providerPreset: metadata.providerPreset,
                upstreamAdapter: metadata.upstreamAdapter,
                chatCompatibilityProfile: metadata.chatCompatibilityProfile,
                upstreamBaseURL: metadata.upstreamBaseURL,
                managedProxyNodeName: row.optionalText("managed_proxy_node_name"),
                modelRouting: modelRouting,
                reasoningEffort: reasoningEffort,
                supportsVision: row.int("supports_vision") == 1,
                addedAt: row.int("added_at"),
                updatedAt: row.int("updated_at"),
                enabled: row.int("enabled") == 1,
                selectionOrder: row.int("selection_order"),
                consecutiveFailureCount: row.int("consecutive_failure_count"),
                cooldownUntil: row.optionalInt("cooldown_until"),
                automaticCooldownDisabled: row.int("automatic_cooldown_disabled") == 1,
                usage: usage,
                usageWindowsVisible: row.int("usage_windows_visible") == 1,
                todayTokenUsage: todayTokenUsage,
                usageError: row.optionalText("usage_error"),
                authRefreshBlocked: row.int("auth_refresh_blocked") == 1,
                authRefreshError: row.optionalText("auth_refresh_error"),
                isCurrent: accountKey == currentAccountKey
            )
        }
    }

    private func loadTodayTokenUsageByAccountKey(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [String: AccountTodayTokenUsage] {
        let startOfDay = calendar.startOfDay(for: now)
        let rows = try self.query(
            """
            SELECT account_key,
                   COALESCE(SUM(input_tokens), 0) AS total_input_tokens,
                   COALESCE(SUM(output_tokens), 0) AS total_output_tokens
            FROM request_logs
            WHERE created_at >= ? AND created_at <= ?
            GROUP BY account_key;
            """,
            bindings: [
                .int(Int64(startOfDay.timeIntervalSince1970)),
                .int(Int64(now.timeIntervalSince1970)),
            ]
        )

        var usageByAccountKey: [String: AccountTodayTokenUsage] = [:]
        for row in rows {
            usageByAccountKey[row.text("account_key")] = AccountTodayTokenUsage(
                inputTokens: row.int("total_input_tokens"),
                outputTokens: row.int("total_output_tokens")
            )
        }
        return usageByAccountKey
    }

    public func exportAccountsJSON() throws -> Data {
        struct ExportEnvelope: Codable {
            var version: Int
            var exportedAt: Int64
            var accounts: [ExportAccount]
        }
        struct ExportAccount: Codable {
            var id: String
            var label: String
            var principalID: String
            var email: String?
            var accountID: String
            var planType: String?
            var authJSON: String
            var managedProxyNodeName: String?
            var modelRouting: AccountModelRoutingConfig?
            var reasoningEffort: AccountReasoningEffortConfig
            var addedAt: Int64
            var updatedAt: Int64
            var enabled: Bool
            var automaticCooldownDisabled: Bool
            var usage: UsageSnapshot?
            var usageError: String?
            var authRefreshBlocked: Bool
            var authRefreshError: String?
        }

        let payload = try ExportEnvelope(
            version: 1,
            exportedAt: Helpers.now(),
            accounts: self.listAccountRecords().map {
                ExportAccount(
                    id: $0.id,
                    label: $0.label,
                    principalID: $0.principalID,
                    email: $0.email,
                    accountID: $0.accountID,
                    planType: $0.planType,
                    authJSON: $0.authJSON,
                    managedProxyNodeName: $0.managedProxyNodeName,
                    modelRouting: $0.modelRouting,
                    reasoningEffort: $0.reasoningEffort,
                    addedAt: $0.addedAt,
                    updatedAt: $0.updatedAt,
                    enabled: $0.enabled,
                    automaticCooldownDisabled: $0.automaticCooldownDisabled,
                    usage: $0.usage,
                    usageError: $0.usageError,
                    authRefreshBlocked: $0.authRefreshBlocked,
                    authRefreshError: $0.authRefreshError
                )
            }
        )
        return try Helpers.encodeJSON(payload, pretty: true)
    }

    public func updateUsage(
        accountKey: String,
        usage: UsageSnapshot?,
        usageError: String?,
        planType: String?,
        authJSON: String?,
        usageWindowsVisible: Bool?,
        authRefreshBlocked: Bool,
        authRefreshError: String?
    ) throws {
        let key = try self.secretStore.masterKey()
        let authBlob: Data?
        if let authJSON {
            authBlob = try CryptoBox.seal(Data(authJSON.utf8), using: key)
        } else {
            authBlob = nil
        }
        let usageBlob = try usage.map { try Helpers.encodeJSON($0) }
        let sql = """
        UPDATE accounts
        SET plan_type = COALESCE(?, plan_type),
            updated_at = ?,
            usage_json = ?,
            usage_error = ?,
            auth_blob = COALESCE(?, auth_blob),
            auth_mode = COALESCE(?, auth_mode),
            provider_preset = COALESCE(?, provider_preset),
            upstream_base_url = COALESCE(?, upstream_base_url),
            usage_windows_visible = COALESCE(?, usage_windows_visible),
            auth_refresh_blocked = ?,
            auth_refresh_error = ?
        WHERE principal_id || '|' || account_id = ?;
        """
        let authMetadata: (
            providerFamily: AccountProviderFamily,
            authMode: AccountAuthMode,
            providerPreset: OpenAICompatibleProviderPreset,
            upstreamAdapter: ManualAPIKeyUpstreamAdapter?,
            chatCompatibilityProfile: ChatCompletionsCompatibilityProfile,
            upstreamBaseURL: String?
        )?
        if let authJSON {
            authMetadata = self.accountMetadata(
                authJSON: authJSON,
                fallbackAuthMode: nil,
                fallbackProviderPreset: nil,
                fallbackUpstreamBaseURL: nil
            )
        } else {
            authMetadata = nil
        }
        try self.execute(sql, bindings: [
            .text(planType),
            .int(Helpers.now()),
            .blob(usageBlob),
            .text(usageError),
            .blob(authBlob),
            .text(authMetadata?.authMode.rawValue),
            .text(authMetadata?.providerPreset.rawValue),
            .text(authMetadata?.upstreamBaseURL),
            .int(usageWindowsVisible.map { $0 ? 1 : 0 }),
            .int(authRefreshBlocked ? 1 : 0),
            .text(authRefreshError),
            .text(accountKey),
        ])
    }

    public func updateUsageWindowsVisible(accountKey: String, visible: Bool) throws {
        try self.execute(
            """
            UPDATE accounts
            SET usage_windows_visible = ?, updated_at = ?
            WHERE principal_id || '|' || account_id = ?;
            """,
            bindings: [
                .int(visible ? 1 : 0),
                .int(Helpers.now()),
                .text(accountKey),
            ]
        )
        guard sqlite3_changes(self.db) > 0 else {
            throw ProxyError.message("未找到要更新的账号")
        }
    }

    public func loadAccountRecord(id: String) throws -> AccountRecord {
        guard let record = try self.listAccountRecords().first(where: { $0.id == id }) else {
            throw ProxyError.message("未找到账号")
        }
        return record
    }

    @discardableResult
    public func recordTrace(_ trace: ProxyRequestTrace) throws -> Int64 {
        try self.upsertMetric(trace, granularity: "hour", bucketStart: self.traceHourStart(for: trace.timestamp))
        try self.upsertMetric(trace, granularity: "day", bucketStart: self.traceDayStart(for: trace.timestamp))
        return try self.insertRequestLog(trace)
    }

    public func loadStatsSummary(
        limit: Int = 48,
        apiKey: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> AdminStatsSummary {
        let apiKeyHash = Self.statsAPIKeyHash(apiKey)
        let apiKeyWhereSQL = apiKeyHash == nil ? "" : "WHERE api_key_hash = ?"
        let apiKeyBindings = apiKeyHash.map { [Binding.text($0)] } ?? []
        let totalsRow = try self.querySingle(
            """
            SELECT
                COUNT(*) AS total_requests,
                COALESCE(SUM(CASE
                    WHEN success = 0 AND COALESCE(failure_category, '') != 'cancelled' THEN 1
                    ELSE 0
                END), 0) AS total_failures,
                COALESCE(SUM(CASE WHEN failure_category = 'auth' THEN 1 ELSE 0 END), 0) AS total_auth_failures,
                COALESCE(SUM(CASE WHEN failure_category = 'rate_limit' THEN 1 ELSE 0 END), 0) AS total_rate_limits,
                COALESCE(SUM(CASE WHEN failure_category = 'quota' THEN 1 ELSE 0 END), 0) AS total_quota_failures,
                COALESCE(SUM(input_tokens), 0) AS total_input_tokens,
                COALESCE(SUM(output_tokens), 0) AS total_output_tokens,
                COALESCE(SUM(total_tokens), 0) AS total_tokens
            FROM request_logs
            \(apiKeyWhereSQL);
            """,
            bindings: apiKeyBindings
        )
        let bucketWhereSQL = apiKeyHash == nil ? "" : "WHERE api_key_hash = ?"
        var bucketBindings = apiKeyBindings
        bucketBindings.append(.int(Int64(limit)))
        let bucketRows = try self.query(
            """
            SELECT granularity, bucket_start, endpoint, api_key_hash, account_key, account_label, model,
                   success_count, failure_count, auth_failure_count, rate_limit_count, quota_failure_count,
                   total_latency_ms, latency_histogram, total_input_tokens, total_output_tokens, total_tokens, last_error
            FROM request_stats_hourly
            \(bucketWhereSQL)
            ORDER BY bucket_start DESC
            LIMIT ?;
            """,
            bindings: bucketBindings
        )
        let buckets = bucketRows.map { row in
            RequestMetricBucket(
                granularity: row.text("granularity"),
                bucketStart: row.int("bucket_start"),
                endpoint: row.text("endpoint"),
                apiKeyHash: row.text("api_key_hash"),
                accountKey: row.text("account_key"),
                accountLabel: row.text("account_label"),
                model: row.text("model"),
                successCount: Int(row.int("success_count")),
                failureCount: Int(row.int("failure_count")),
                authFailureCount: Int(row.int("auth_failure_count")),
                rateLimitCount: Int(row.int("rate_limit_count")),
                quotaFailureCount: Int(row.int("quota_failure_count")),
                totalLatencyMS: row.int("total_latency_ms"),
                p95LatencyMS: Self.histogramToP95(row.optionalText("latency_histogram")),
                totalInputTokens: row.int("total_input_tokens"),
                totalOutputTokens: row.int("total_output_tokens"),
                totalTokens: row.int("total_tokens"),
                lastError: row.optionalText("last_error")
            )
        }
        let naturalTokenUsage = try self.loadNaturalTokenUsageSummary(
            now: now,
            calendar: calendar,
            apiKeyHash: apiKeyHash
        )

        return AdminStatsSummary(
            totalRequests: totalsRow?.int("total_requests") ?? 0,
            totalFailures: totalsRow?.int("total_failures") ?? 0,
            totalAuthFailures: totalsRow?.int("total_auth_failures") ?? 0,
            totalRateLimits: totalsRow?.int("total_rate_limits") ?? 0,
            totalQuotaFailures: totalsRow?.int("total_quota_failures") ?? 0,
            totalInputTokens: totalsRow?.int("total_input_tokens") ?? 0,
            totalOutputTokens: totalsRow?.int("total_output_tokens") ?? 0,
            totalTokens: totalsRow?.int("total_tokens") ?? 0,
            naturalTokenUsage: naturalTokenUsage,
            latestBuckets: buckets
        )
    }

    private static func statsAPIKeyHash(_ apiKey: String?) -> String? {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : Helpers.sha256(trimmed)
    }

    public func loadRequestLogs(query: RequestLogQuery) throws -> RequestLogPage {
        let normalized = query.normalized()
        let timeOnly = normalized.timeRangeOnly()
        let filterOptions = try self.loadRequestLogFilterOptions(query: timeOnly)
        let (whereSQL, bindings) = self.requestLogConditions(for: normalized)
        let offset = Int64((normalized.page - 1) * normalized.pageSize)

        let totalRow = try self.querySingle(
            "SELECT COUNT(*) AS total_count FROM request_logs\(whereSQL);",
            bindings: bindings
        )
        let entries = try self.loadRequestLogEntries(
            query: normalized,
            bindings: bindings + [.int(Int64(normalized.pageSize)), .int(offset)],
            limitClause: " LIMIT ? OFFSET ?"
        )

        return RequestLogPage(
            entries: entries,
            totalCount: totalRow?.int("total_count") ?? 0,
            page: normalized.page,
            pageSize: normalized.pageSize,
            availableAPIKeys: filterOptions.availableAPIKeys,
            availableModels: filterOptions.availableModels
        )
    }

    public func loadAllRequestLogs(query: RequestLogQuery) throws -> [RequestLogEntry] {
        let normalized = query.normalized()
        let (_, bindings) = self.requestLogConditions(for: normalized)
        return try self.loadRequestLogEntries(query: normalized, bindings: bindings, limitClause: "")
    }

    public func loadRequestLogFilterOptions(query: RequestLogQuery) throws -> RequestLogFilterOptions {
        let normalized = query.timeRangeOnly().normalized()
        let key = try self.secretStore.masterKey()
        let (whereSQL, bindings) = self.requestLogConditions(for: normalized)
        let apiKeyRows = try self.query(
            """
            SELECT api_key_hash, MAX(created_at)
            FROM request_logs\(whereSQL)
            GROUP BY api_key_hash
            ORDER BY 2 DESC, 1 COLLATE NOCASE ASC;
            """,
            bindings: bindings
        )
        let modelRows = try self.query(
            """
            SELECT model, MAX(created_at)
            FROM request_logs\(whereSQL)
            GROUP BY model
            ORDER BY 2 DESC, 1 COLLATE NOCASE ASC;
            """,
            bindings: bindings
        )

        var apiKeys: [String] = []
        var seenHashes = Set<String>()
        for row in apiKeyRows {
            let hash = row.text("api_key_hash").trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenHashes.insert(hash).inserted else { continue }
            guard let cipher = try self.latestCipherForAPIKeyHash(hash, whereSQL: whereSQL, bindings: bindings) else { continue }
            let decrypted = try String(decoding: CryptoBox.open(cipher, using: key), as: UTF8.self)
            guard !decrypted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            apiKeys.append(decrypted)
        }

        let models = modelRows
            .map { $0.text("model").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return RequestLogFilterOptions(
            availableAPIKeys: apiKeys,
            availableModels: Array(models)
        )
    }

    public func loadProxyAPIKeyUsage(query: RequestLogQuery) throws -> [ProxyAPIKeyUsageAggregateRow] {
        let normalized = query.timeRangeOnly().normalized()
        let key = try self.secretStore.masterKey()
        let (whereSQL, bindings) = self.requestLogConditions(for: normalized)
        let rows = try self.query(
            """
            SELECT
                api_key_hash,
                COUNT(*) AS request_count,
                COALESCE(SUM(CASE
                    WHEN success = 0 AND COALESCE(failure_category, '') != 'cancelled' THEN 1
                    ELSE 0
                END), 0) AS failure_count,
                COALESCE(SUM(CASE WHEN failure_category = 'auth' THEN 1 ELSE 0 END), 0) AS auth_failure_count,
                COALESCE(SUM(CASE WHEN failure_category = 'rate_limit' THEN 1 ELSE 0 END), 0) AS rate_limit_count,
                COALESCE(SUM(CASE WHEN failure_category = 'quota' THEN 1 ELSE 0 END), 0) AS quota_failure_count,
                COALESCE(AVG(latency_ms), 0) AS average_latency_ms,
                COALESCE(SUM(input_tokens), 0) AS total_input_tokens,
                COALESCE(SUM(output_tokens), 0) AS total_output_tokens,
                COALESCE(SUM(total_tokens), 0) AS total_tokens,
                MAX(created_at) AS last_used_at
            FROM request_logs\(whereSQL)
            GROUP BY api_key_hash
            ORDER BY total_tokens DESC, request_count DESC, last_used_at DESC;
            """,
            bindings: bindings
        )

        return try rows.map { row in
            let hash = row.text("api_key_hash")
            let cipher = try self.latestCipherForAPIKeyHash(hash, whereSQL: whereSQL, bindings: bindings)
            let decryptedAPIKey: String
            if let cipher, cipher.isEmpty == false {
                decryptedAPIKey = String(decoding: try CryptoBox.open(cipher, using: key), as: UTF8.self)
            } else {
                decryptedAPIKey = ""
            }
            return ProxyAPIKeyUsageAggregateRow(
                apiKeyHash: hash,
                apiKey: decryptedAPIKey,
                requestCount: row.int("request_count"),
                failureCount: row.int("failure_count"),
                authFailureCount: row.int("auth_failure_count"),
                rateLimitCount: row.int("rate_limit_count"),
                quotaFailureCount: row.int("quota_failure_count"),
                averageLatencyMS: row.int("average_latency_ms"),
                totalInputTokens: row.int("total_input_tokens"),
                totalOutputTokens: row.int("total_output_tokens"),
                totalTokens: row.int("total_tokens"),
                lastUsedAt: row.optionalInt("last_used_at")
            )
        }
    }

    public func pruneStats(retentionDays: Int) throws {
        let cutoff = Helpers.now() - Int64(retentionDays * 86_400)
        try self.execute("DELETE FROM request_stats_hourly WHERE bucket_start < ?;", bindings: [.int(cutoff)])
        try self.execute("DELETE FROM request_stats_daily WHERE bucket_start < ?;", bindings: [.int(cutoff)])
        try self.execute("DELETE FROM request_logs WHERE created_at < ?;", bindings: [.int(cutoff)])
    }

    func upsertChatCompletionsReasoningCacheEntry(
        cacheKey: String,
        accountKey: String,
        sessionKey: String,
        entry: ChatCompletionsReasoningCacheEntry,
        capacity: Int
    ) throws {
        let key = try self.secretStore.masterKey()
        let plaintext = try JSONEncoder().encode(entry)
        let cipher = try CryptoBox.seal(plaintext, using: key)
        let storedAt = entry.touchedAt
        try self.execute(
            """
            INSERT INTO chat_completions_reasoning_cache (
                cache_key, account_key, session_key, entry_cipher, expires_at, touched_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(cache_key) DO UPDATE SET
                account_key = excluded.account_key,
                session_key = excluded.session_key,
                entry_cipher = excluded.entry_cipher,
                expires_at = excluded.expires_at,
                touched_at = excluded.touched_at,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(cacheKey),
                .text(accountKey),
                .text(sessionKey),
                .blob(cipher),
                .int(entry.expiresAt),
                .int(entry.touchedAt),
                .int(storedAt),
                .int(storedAt),
            ]
        )
        try self.pruneExpiredChatCompletionsReasoningCache(now: storedAt)
        try self.enforceChatCompletionsReasoningCacheCapacity(capacity)
    }

    func loadChatCompletionsReasoningCacheEntry(
        accountKey: String,
        sessionKey: String,
        now: Int64 = Helpers.now()
    ) throws -> ChatCompletionsReasoningCacheEntry? {
        guard let row = try self.querySingle(
            """
            SELECT cache_key, entry_cipher, expires_at
            FROM chat_completions_reasoning_cache
            WHERE account_key = ? AND session_key = ?
            LIMIT 1;
            """,
            bindings: [.text(accountKey), .text(sessionKey)]
        ) else {
            return nil
        }
        if row.int("expires_at") <= now {
            _ = try self.clearChatCompletionsReasoningCache(
                ClearReasoningCacheRequest(expiredOnly: true),
                now: now
            )
            return nil
        }
        do {
            let key = try self.secretStore.masterKey()
            let plaintext = try CryptoBox.open(row.blob("entry_cipher"), using: key)
            return try JSONDecoder().decode(ChatCompletionsReasoningCacheEntry.self, from: plaintext)
        } catch {
            _ = try self.clearChatCompletionsReasoningCache(cacheKey: row.text("cache_key"))
            throw error
        }
    }

    func chatCompletionsReasoningCacheSummary(now: Int64 = Helpers.now()) throws -> ReasoningCacheSummary {
        let rows = try self.query(
            """
            SELECT c.account_key AS account_key,
                   COALESCE(NULLIF(a.label, ''), c.account_key) AS account_label,
                   COUNT(*) AS entry_count,
                   SUM(CASE WHEN c.expires_at <= ? THEN 1 ELSE 0 END) AS expired_count,
                   MIN(c.touched_at) AS oldest_touched_at,
                   MAX(c.touched_at) AS newest_touched_at
            FROM chat_completions_reasoning_cache c
            LEFT JOIN accounts a
              ON c.account_key = a.principal_id || '|' || a.account_id
            GROUP BY c.account_key, account_label
            ORDER BY newest_touched_at DESC, account_label COLLATE NOCASE ASC;
            """,
            bindings: [.int(now)]
        )
        let accounts = rows.map { row in
            ReasoningCacheAccountSummary(
                accountKey: row.text("account_key"),
                accountLabel: row.text("account_label"),
                entryCount: Int(row.int("entry_count")),
                expiredCount: Int(row.int("expired_count")),
                oldestTouchedAt: row.optionalInt("oldest_touched_at"),
                newestTouchedAt: row.optionalInt("newest_touched_at")
            )
        }
        return ReasoningCacheSummary(
            totalCount: accounts.reduce(0) { $0 + $1.entryCount },
            expiredCount: accounts.reduce(0) { $0 + $1.expiredCount },
            oldestTouchedAt: accounts.compactMap(\.oldestTouchedAt).min(),
            newestTouchedAt: accounts.compactMap(\.newestTouchedAt).max(),
            accounts: accounts
        )
    }

    @discardableResult
    func pruneExpiredChatCompletionsReasoningCache(now: Int64 = Helpers.now()) throws -> Int {
        try self.deleteChatCompletionsReasoningCache(whereSQL: "expires_at <= ?", bindings: [.int(now)])
    }

    @discardableResult
    func clearChatCompletionsReasoningCache(accountKey: String) throws -> Int {
        try self.deleteChatCompletionsReasoningCache(whereSQL: "account_key = ?", bindings: [.text(accountKey)])
    }

    @discardableResult
    func clearChatCompletionsReasoningCache(_ request: ClearReasoningCacheRequest, now: Int64 = Helpers.now()) throws -> Int {
        if request.clearAll {
            return try self.deleteChatCompletionsReasoningCache(whereSQL: nil, bindings: [])
        }

        var clauses: [String] = []
        var bindings: [Binding] = []
        if request.expiredOnly {
            clauses.append("expires_at <= ?")
            bindings.append(.int(now))
        }
        if let olderThanSeconds = request.olderThanSeconds {
            clauses.append("touched_at < ?")
            bindings.append(.int(max(0, now - olderThanSeconds)))
        }
        if request.accountKeys.isEmpty == false {
            clauses.append("account_key IN (\(Self.sqlPlaceholders(count: request.accountKeys.count)))")
            bindings.append(contentsOf: request.accountKeys.map { .text($0) })
        }
        guard clauses.isEmpty == false else {
            throw ProxyError.message("请选择要清理的 reasoning 回传缓存范围。")
        }
        return try self.deleteChatCompletionsReasoningCache(whereSQL: clauses.joined(separator: " AND "), bindings: bindings)
    }

    @discardableResult
    private func clearChatCompletionsReasoningCache(cacheKey: String) throws -> Int {
        try self.deleteChatCompletionsReasoningCache(whereSQL: "cache_key = ?", bindings: [.text(cacheKey)])
    }

    @discardableResult
    private func deleteChatCompletionsReasoningCache(whereSQL: String?, bindings: [Binding]) throws -> Int {
        let sql: String
        if let whereSQL, whereSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            sql = "DELETE FROM chat_completions_reasoning_cache WHERE \(whereSQL);"
        } else {
            sql = "DELETE FROM chat_completions_reasoning_cache;"
        }
        return try self.withDatabaseLock {
            try self.execute(sql, bindings: bindings)
            return Int(sqlite3_changes(self.db))
        }
    }

    private func enforceChatCompletionsReasoningCacheCapacity(_ capacity: Int) throws {
        let capacity = max(1, capacity)
        let count = Int((try self.querySingle(
            "SELECT COUNT(*) AS entry_count FROM chat_completions_reasoning_cache;"
        ))?.int("entry_count") ?? 0)
        guard count > capacity else { return }
        let overflow = count - capacity
        try self.execute(
            """
            DELETE FROM chat_completions_reasoning_cache
            WHERE cache_key IN (
                SELECT cache_key
                FROM chat_completions_reasoning_cache
                ORDER BY touched_at ASC, updated_at ASC
                LIMIT ?
            );
            """,
            bindings: [.int(Int64(overflow))]
        )
    }

    func upsertOCRResultCacheEntry(
        imageHash: String,
        entry: OCRResultCacheEntry,
        capacity: Int
    ) throws {
        let key = try self.secretStore.masterKey()
        let plaintext = try JSONEncoder().encode(entry)
        let cipher = try CryptoBox.seal(plaintext, using: key)
        let storedAt = entry.touchedAt
        try self.execute(
            """
            INSERT INTO ocr_result_cache (
                image_hash, result_cipher, mime_type, byte_count, expires_at, touched_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(image_hash) DO UPDATE SET
                result_cipher = excluded.result_cipher,
                mime_type = excluded.mime_type,
                byte_count = excluded.byte_count,
                expires_at = excluded.expires_at,
                touched_at = excluded.touched_at,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(imageHash),
                .blob(cipher),
                .text(entry.mimeType),
                .int(Int64(entry.byteCount)),
                .int(entry.expiresAt),
                .int(entry.touchedAt),
                .int(storedAt),
                .int(storedAt),
            ]
        )
        try self.pruneExpiredOCRResultCache(now: storedAt)
        try self.enforceOCRResultCacheCapacity(capacity)
    }

    func loadOCRResultCacheEntry(
        imageHash: String,
        now: Int64 = Helpers.now()
    ) throws -> OCRResultCacheEntry? {
        guard let row = try self.querySingle(
            """
            SELECT image_hash, result_cipher, expires_at
            FROM ocr_result_cache
            WHERE image_hash = ?
            LIMIT 1;
            """,
            bindings: [.text(imageHash)]
        ) else {
            return nil
        }
        if row.int("expires_at") <= now {
            _ = try self.clearOCRResultCache(ClearOCRCacheRequest(expiredOnly: true), now: now)
            return nil
        }
        do {
            let key = try self.secretStore.masterKey()
            let plaintext = try CryptoBox.open(row.blob("result_cipher"), using: key)
            var entry = try JSONDecoder().decode(OCRResultCacheEntry.self, from: plaintext)
            entry.touchedAt = now
            try self.execute(
                "UPDATE ocr_result_cache SET touched_at = ?, updated_at = ? WHERE image_hash = ?;",
                bindings: [.int(now), .int(now), .text(imageHash)]
            )
            return entry
        } catch {
            _ = try self.clearOCRResultCache(imageHash: row.text("image_hash"))
            throw error
        }
    }

    func touchOCRResultCacheEntry(imageHash: String, now: Int64 = Helpers.now()) throws {
        try self.execute(
            "UPDATE ocr_result_cache SET touched_at = ?, updated_at = ? WHERE image_hash = ?;",
            bindings: [.int(now), .int(now), .text(imageHash)]
        )
    }

    func ocrResultCacheSummary(now: Int64 = Helpers.now()) throws -> OCRCacheSummary {
        let row = try self.querySingle(
            """
            SELECT COUNT(*) AS total_count,
                   SUM(CASE WHEN expires_at <= ? THEN 1 ELSE 0 END) AS expired_count,
                   MIN(touched_at) AS oldest_touched_at,
                   MAX(touched_at) AS newest_touched_at
            FROM ocr_result_cache;
            """,
            bindings: [.int(now)]
        )
        return OCRCacheSummary(
            totalCount: Int(row?.int("total_count") ?? 0),
            expiredCount: Int(row?.int("expired_count") ?? 0),
            oldestTouchedAt: row?.optionalInt("oldest_touched_at"),
            newestTouchedAt: row?.optionalInt("newest_touched_at")
        )
    }

    @discardableResult
    func pruneExpiredOCRResultCache(now: Int64 = Helpers.now()) throws -> Int {
        try self.deleteOCRResultCache(whereSQL: "expires_at <= ?", bindings: [.int(now)])
    }

    @discardableResult
    func clearOCRResultCache(_ request: ClearOCRCacheRequest, now: Int64 = Helpers.now()) throws -> Int {
        if request.clearAll {
            return try self.deleteOCRResultCache(whereSQL: nil, bindings: [])
        }

        var clauses: [String] = []
        var bindings: [Binding] = []
        if request.expiredOnly {
            clauses.append("expires_at <= ?")
            bindings.append(.int(now))
        }
        if let olderThanSeconds = request.olderThanSeconds {
            clauses.append("touched_at < ?")
            bindings.append(.int(max(0, now - olderThanSeconds)))
        }
        guard clauses.isEmpty == false else {
            throw ProxyError.message("请选择要清理的 OCR 缓存范围。")
        }
        return try self.deleteOCRResultCache(whereSQL: clauses.joined(separator: " AND "), bindings: bindings)
    }

    @discardableResult
    private func clearOCRResultCache(imageHash: String) throws -> Int {
        try self.deleteOCRResultCache(whereSQL: "image_hash = ?", bindings: [.text(imageHash)])
    }

    @discardableResult
    private func deleteOCRResultCache(whereSQL: String?, bindings: [Binding]) throws -> Int {
        let sql: String
        if let whereSQL, whereSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            sql = "DELETE FROM ocr_result_cache WHERE \(whereSQL);"
        } else {
            sql = "DELETE FROM ocr_result_cache;"
        }
        return try self.withDatabaseLock {
            try self.execute(sql, bindings: bindings)
            return Int(sqlite3_changes(self.db))
        }
    }

    @discardableResult
    func insertOCRRecognitionLog(_ entry: OCRRecognitionLogEntry) throws -> OCRRecognitionLogEntry {
        let createdAt = entry.createdAt > 0 ? entry.createdAt : Helpers.now()
        try self.execute(
            """
            INSERT INTO ocr_recognition_logs (
                created_at, endpoint, account_key, account_label, requested_model, ocr_model,
                image_index, image_hash, mime_type, byte_count, status, cache_hit, latency_ms, error_summary
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int(createdAt),
                .text(entry.endpoint),
                .text(entry.accountKey),
                .text(entry.accountLabel),
                .text(entry.requestedModel),
                .text(entry.ocrModel),
                .int(Int64(entry.imageIndex)),
                .text(entry.imageHash),
                .text(entry.mimeType),
                .int(Int64(entry.byteCount)),
                .text(entry.status.rawValue),
                .int(entry.cacheHit ? 1 : 0),
                .int(entry.latencyMS),
                .text(entry.errorSummary),
            ]
        )
        let insertedID = try self.querySingle("SELECT last_insert_rowid() AS id;")?.int("id") ?? 0
        var stored = entry
        stored.id = insertedID
        stored.createdAt = createdAt
        return stored
    }

    func listOCRRecognitionLogs(_ request: OCRRecognitionLogListRequest) throws -> OCRRecognitionLogListResponse {
        let (whereSQL, bindings) = self.ocrRecognitionLogFilterSQL(status: request.status)
        let countSQL = "SELECT COUNT(*) AS total_count FROM ocr_recognition_logs\(whereSQL);"
        let totalCount = Int((try self.querySingle(countSQL, bindings: bindings))?.int("total_count") ?? 0)
        let rows = try self.query(
            """
            SELECT id, created_at, endpoint, account_key, account_label, requested_model, ocr_model,
                   image_index, image_hash, mime_type, byte_count, status, cache_hit, latency_ms, error_summary
            FROM ocr_recognition_logs
            \(whereSQL)
            ORDER BY created_at DESC, id DESC
            LIMIT ? OFFSET ?;
            """,
            bindings: bindings + [.int(Int64(request.limit)), .int(Int64(request.offset))]
        )
        return OCRRecognitionLogListResponse(
            entries: rows.map(self.ocrRecognitionLogEntry(from:)),
            totalCount: totalCount
        )
    }

    func loadOCRRecognitionLog(id: Int64) throws -> OCRRecognitionLogEntry? {
        try self.querySingle(
            """
            SELECT id, created_at, endpoint, account_key, account_label, requested_model, ocr_model,
                   image_index, image_hash, mime_type, byte_count, status, cache_hit, latency_ms, error_summary
            FROM ocr_recognition_logs
            WHERE id = ?
            LIMIT 1;
            """,
            bindings: [.int(id)]
        ).map(self.ocrRecognitionLogEntry(from:))
    }

    func loadOCRRecognitionResult(logID: Int64, now: Int64 = Helpers.now()) throws -> OCRRecognitionResultLookupResponse {
        guard let entry = try self.loadOCRRecognitionLog(id: logID) else {
            throw ProxyError.message("OCR recognition log not found.")
        }
        guard let imageHash = entry.imageHash, imageHash.isEmpty == false else {
            return OCRRecognitionResultLookupResponse(
                entry: entry,
                available: false,
                message: "OCR 缓存已清理，无法查看正文。"
            )
        }
        guard let cached = try self.loadOCRResultCacheEntry(imageHash: imageHash, now: now) else {
            return OCRRecognitionResultLookupResponse(
                entry: entry,
                available: false,
                message: "OCR 缓存已清理，无法查看正文。"
            )
        }
        return OCRRecognitionResultLookupResponse(entry: entry, available: true, text: cached.text)
    }


    func ocrRecognitionLogSummary(now: Int64 = Helpers.now()) throws -> OCRRecognitionLogSummary {
        let thirtyDays: Int64 = 30 * 24 * 3600
        let row = try self.querySingle(
            """
            SELECT COUNT(*) AS total_count,
                   SUM(CASE WHEN created_at <= ? THEN 1 ELSE 0 END) AS expired_count,
                   MIN(created_at) AS oldest_created_at,
                   MAX(created_at) AS newest_created_at
            FROM ocr_recognition_logs;
            """,
            bindings: [.int(now - thirtyDays)]
        )
        return OCRRecognitionLogSummary(
            totalCount: Int(row?.int("total_count") ?? 0),
            expiredCount: Int(row?.int("expired_count") ?? 0),
            oldestCreatedAt: row?.optionalInt("oldest_created_at"),
            newestCreatedAt: row?.optionalInt("newest_created_at")
        )
    }

    @discardableResult
    func pruneExpiredOCRRecognitionLogs(now: Int64 = Helpers.now()) throws -> Int {
        let thirtyDays: Int64 = 30 * 24 * 3600
        return try self.deleteOCRRecognitionLogs(
            whereSQL: "created_at <= ?",
            bindings: [.int(now - thirtyDays)]
        )
    }

    @discardableResult
    func clearOCRRecognitionLogs(_ request: ClearOCRRecognitionLogsRequest, now: Int64 = Helpers.now()) throws -> Int {
        if request.clearAll {
            return try self.deleteOCRRecognitionLogs(whereSQL: nil, bindings: [])
        }

        let thirtyDays: Int64 = 30 * 24 * 3600
        var clauses: [String] = []
        var bindings: [Binding] = []
        if request.expiredOnly {
            clauses.append("created_at <= ?")
            bindings.append(.int(now - thirtyDays))
        }
        if let olderThanSeconds = request.olderThanSeconds {
            clauses.append("created_at < ?")
            bindings.append(.int(max(0, now - olderThanSeconds)))
        }
        guard clauses.isEmpty == false else {
            throw ProxyError.message("请选择要清理的识别日志范围。")
        }
        return try self.deleteOCRRecognitionLogs(
            whereSQL: clauses.joined(separator: " AND "),
            bindings: bindings
        )
    }

    @discardableResult
    private func deleteOCRRecognitionLogs(whereSQL: String?, bindings: [Binding]) throws -> Int {
        let sql: String
        if let whereSQL, whereSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            sql = "DELETE FROM ocr_recognition_logs WHERE \(whereSQL);"
        } else {
            sql = "DELETE FROM ocr_recognition_logs;"
        }
        return try self.withDatabaseLock {
            try self.execute(sql, bindings: bindings)
            return Int(sqlite3_changes(self.db))
        }
    }

    private func ocrRecognitionLogFilterSQL(
        status: OCRRecognitionLogStatus?
    ) -> (sql: String, bindings: [Binding]) {
        guard let status else {
            return ("", [])
        }
        return (" WHERE status = ?", [.text(status.rawValue)])
    }

    private func ocrRecognitionLogEntry(from row: SQLiteRow) -> OCRRecognitionLogEntry {
        OCRRecognitionLogEntry(
            id: row.int("id"),
            createdAt: row.int("created_at"),
            endpoint: row.text("endpoint"),
            accountKey: row.text("account_key"),
            accountLabel: row.text("account_label"),
            requestedModel: row.text("requested_model"),
            ocrModel: row.text("ocr_model"),
            imageIndex: Int(row.int("image_index")),
            imageHash: row.optionalText("image_hash"),
            mimeType: row.text("mime_type"),
            byteCount: Int(row.int("byte_count")),
            status: OCRRecognitionLogStatus(rawValue: row.text("status")) ?? .failed,
            cacheHit: row.int("cache_hit") == 1,
            latencyMS: row.int("latency_ms"),
            errorSummary: row.optionalText("error_summary")
        )
    }

    private func enforceOCRResultCacheCapacity(_ capacity: Int) throws {
        let capacity = max(1, capacity)
        let count = Int((try self.querySingle(
            "SELECT COUNT(*) AS entry_count FROM ocr_result_cache;"
        ))?.int("entry_count") ?? 0)
        guard count > capacity else { return }
        let overflow = count - capacity
        try self.execute(
            """
            DELETE FROM ocr_result_cache
            WHERE image_hash IN (
                SELECT image_hash
                FROM ocr_result_cache
                ORDER BY touched_at ASC, updated_at ASC
                LIMIT ?
            );
            """,
            bindings: [.int(Int64(overflow))]
        )
    }

    private static func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }

    private static func migrate(on db: OpaquePointer?) throws {
        try self.execute("PRAGMA journal_mode=WAL;", on: db)
        try self.execute("PRAGMA foreign_keys=ON;", on: db)
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,
            on: db
        )
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS accounts (
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
                automatic_cooldown_disabled INTEGER NOT NULL DEFAULT 0,
                selection_order INTEGER NOT NULL DEFAULT 0,
                consecutive_failure_count INTEGER NOT NULL DEFAULT 0,
                cooldown_until INTEGER,
                usage_json BLOB,
                usage_error TEXT,
                auth_refresh_blocked INTEGER NOT NULL DEFAULT 0,
                auth_refresh_error TEXT,
                auth_mode TEXT NOT NULL DEFAULT 'chatgpt',
                provider_preset TEXT NOT NULL DEFAULT 'generic_openai_compatible',
                upstream_base_url TEXT,
                managed_proxy_node_name TEXT,
                model_routing_json TEXT,
                reasoning_effort_json TEXT,
                supports_vision INTEGER NOT NULL DEFAULT 1,
                usage_windows_visible INTEGER NOT NULL DEFAULT 1
            );
            """,
            on: db
        )
        if try !self.columnExists("enabled", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;", on: db)
        }
        if try !self.columnExists("automatic_cooldown_disabled", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN automatic_cooldown_disabled INTEGER NOT NULL DEFAULT 0;", on: db)
        }
        if try !self.columnExists("selection_order", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN selection_order INTEGER NOT NULL DEFAULT 0;", on: db)
            try self.initializeAccountSelectionOrder(on: db)
        }
        if try !self.columnExists("consecutive_failure_count", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN consecutive_failure_count INTEGER NOT NULL DEFAULT 0;", on: db)
        }
        if try !self.columnExists("cooldown_until", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN cooldown_until INTEGER;", on: db)
        }
        if try !self.columnExists("auth_mode", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN auth_mode TEXT NOT NULL DEFAULT 'chatgpt';", on: db)
        }
        if try !self.columnExists("provider_preset", in: "accounts", on: db) {
            try self.execute(
                "ALTER TABLE accounts ADD COLUMN provider_preset TEXT NOT NULL DEFAULT 'generic_openai_compatible';",
                on: db
            )
        }
        if try !self.columnExists("upstream_base_url", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN upstream_base_url TEXT;", on: db)
        }
        if try !self.columnExists("managed_proxy_node_name", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN managed_proxy_node_name TEXT;", on: db)
        }
        if try !self.columnExists("model_routing_json", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN model_routing_json TEXT;", on: db)
        }
        if try !self.columnExists("reasoning_effort_json", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN reasoning_effort_json TEXT;", on: db)
        }
        if try !self.columnExists("usage_windows_visible", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN usage_windows_visible INTEGER NOT NULL DEFAULT 1;", on: db)
        }
        if try !self.columnExists("supports_vision", in: "accounts", on: db) {
            try self.execute("ALTER TABLE accounts ADD COLUMN supports_vision INTEGER NOT NULL DEFAULT 1;", on: db)
        }
        try self.execute("UPDATE accounts SET enabled = 1 WHERE enabled IS NULL;", on: db)
        try self.execute("UPDATE accounts SET consecutive_failure_count = 0 WHERE consecutive_failure_count IS NULL;", on: db)
        try self.execute("UPDATE accounts SET auth_mode = 'chatgpt' WHERE auth_mode IS NULL OR auth_mode = '';", on: db)
        try self.execute(
            "UPDATE accounts SET provider_preset = 'generic_openai_compatible' WHERE provider_preset IS NULL OR provider_preset = '';",
            on: db
        )
        try self.execute("UPDATE accounts SET usage_windows_visible = 1 WHERE usage_windows_visible IS NULL;", on: db)
        try self.execute("UPDATE accounts SET supports_vision = 1 WHERE supports_vision IS NULL;", on: db)
        try self.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_account_key ON accounts(principal_id, account_id);", on: db)
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS request_stats_hourly (
                granularity TEXT NOT NULL,
                bucket_start INTEGER NOT NULL,
                endpoint TEXT NOT NULL,
                api_key_hash TEXT NOT NULL,
                account_key TEXT NOT NULL,
                account_label TEXT NOT NULL,
                model TEXT NOT NULL,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                auth_failure_count INTEGER NOT NULL DEFAULT 0,
                rate_limit_count INTEGER NOT NULL DEFAULT 0,
                quota_failure_count INTEGER NOT NULL DEFAULT 0,
                total_latency_ms INTEGER NOT NULL DEFAULT 0,
                latency_histogram TEXT NOT NULL DEFAULT '{}',
                total_input_tokens INTEGER NOT NULL DEFAULT 0,
                total_output_tokens INTEGER NOT NULL DEFAULT 0,
                total_tokens INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                PRIMARY KEY (granularity, bucket_start, endpoint, api_key_hash, account_key, model)
            );
            """,
            on: db
        )
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS request_stats_daily (
                granularity TEXT NOT NULL,
                bucket_start INTEGER NOT NULL,
                endpoint TEXT NOT NULL,
                api_key_hash TEXT NOT NULL,
                account_key TEXT NOT NULL,
                account_label TEXT NOT NULL,
                model TEXT NOT NULL,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                auth_failure_count INTEGER NOT NULL DEFAULT 0,
                rate_limit_count INTEGER NOT NULL DEFAULT 0,
                quota_failure_count INTEGER NOT NULL DEFAULT 0,
                total_latency_ms INTEGER NOT NULL DEFAULT 0,
                latency_histogram TEXT NOT NULL DEFAULT '{}',
                total_input_tokens INTEGER NOT NULL DEFAULT 0,
                total_output_tokens INTEGER NOT NULL DEFAULT 0,
                total_tokens INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                PRIMARY KEY (granularity, bucket_start, endpoint, api_key_hash, account_key, model)
            );
            """,
            on: db
        )
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS request_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                endpoint TEXT NOT NULL,
                upstream_url TEXT,
                client_source TEXT NOT NULL DEFAULT 'other',
                api_key_hash TEXT NOT NULL,
                api_key_cipher BLOB,
                account_key TEXT NOT NULL,
                account_label TEXT NOT NULL,
                model TEXT NOT NULL,
                actual_model TEXT,
                reasoning_effort TEXT,
                project_route_id TEXT,
                project_route_label TEXT,
                effective_proxy_api_key_id TEXT,
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
            on: db
        )
        if try !self.columnExists("actual_model", in: "request_logs", on: db) {
            try self.execute("ALTER TABLE request_logs ADD COLUMN actual_model TEXT;", on: db)
        }
        if try !self.columnExists("upstream_url", in: "request_logs", on: db) {
            try self.execute("ALTER TABLE request_logs ADD COLUMN upstream_url TEXT;", on: db)
        }
        if try !self.columnExists("client_source", in: "request_logs", on: db) {
            try self.execute(
                "ALTER TABLE request_logs ADD COLUMN client_source TEXT NOT NULL DEFAULT 'other';",
                on: db
            )
        }
        if try !self.columnExists("reasoning_effort", in: "request_logs", on: db) {
            try self.execute("ALTER TABLE request_logs ADD COLUMN reasoning_effort TEXT;", on: db)
        }
        if try !self.columnExists("project_route_id", in: "request_logs", on: db) {
            try self.execute("ALTER TABLE request_logs ADD COLUMN project_route_id TEXT;", on: db)
        }
        if try !self.columnExists("project_route_label", in: "request_logs", on: db) {
            try self.execute("ALTER TABLE request_logs ADD COLUMN project_route_label TEXT;", on: db)
        }
        if try !self.columnExists("effective_proxy_api_key_id", in: "request_logs", on: db) {
            try self.execute("ALTER TABLE request_logs ADD COLUMN effective_proxy_api_key_id TEXT;", on: db)
        }
        try self.execute("CREATE INDEX IF NOT EXISTS idx_request_logs_created_at ON request_logs(created_at DESC);", on: db)
        try self.execute("CREATE INDEX IF NOT EXISTS idx_request_logs_model ON request_logs(model);", on: db)
        try self.execute("CREATE INDEX IF NOT EXISTS idx_request_logs_project_route_id ON request_logs(project_route_id);", on: db)
        try self.execute("CREATE INDEX IF NOT EXISTS idx_request_logs_api_key_hash ON request_logs(api_key_hash);", on: db)
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS diagnostic_request_bodies (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                request_log_id INTEGER,
                created_at INTEGER NOT NULL,
                endpoint TEXT NOT NULL,
                upstream_url TEXT,
                account_key TEXT NOT NULL,
                account_label TEXT NOT NULL,
                model TEXT NOT NULL,
                actual_model TEXT,
                body_sha256 TEXT NOT NULL,
                prefix_sha256 TEXT NOT NULL,
                byte_count INTEGER NOT NULL DEFAULT 0,
                relative_path TEXT,
                expires_at INTEGER NOT NULL,
                status TEXT NOT NULL,
                error_summary TEXT,
                metadata_json TEXT
            );
            """,
            on: db
        )
        if try !self.columnExists("metadata_json", in: "diagnostic_request_bodies", on: db) {
            try self.execute("ALTER TABLE diagnostic_request_bodies ADD COLUMN metadata_json TEXT;", on: db)
        }
        try self.execute("CREATE INDEX IF NOT EXISTS idx_diagnostic_request_bodies_request_log_id ON diagnostic_request_bodies(request_log_id);", on: db)
        try self.execute("CREATE INDEX IF NOT EXISTS idx_diagnostic_request_bodies_created_at ON diagnostic_request_bodies(created_at DESC);", on: db)
        try self.execute("CREATE INDEX IF NOT EXISTS idx_diagnostic_request_bodies_expires_at ON diagnostic_request_bodies(expires_at);", on: db)
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS chat_completions_reasoning_cache (
                cache_key TEXT PRIMARY KEY,
                account_key TEXT NOT NULL,
                session_key TEXT NOT NULL,
                entry_cipher BLOB NOT NULL,
                expires_at INTEGER NOT NULL,
                touched_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            """,
            on: db
        )
        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_reasoning_cache_account_key ON chat_completions_reasoning_cache(account_key);",
            on: db
        )
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS ocr_result_cache (
                image_hash TEXT PRIMARY KEY,
                result_cipher BLOB NOT NULL,
                mime_type TEXT NOT NULL DEFAULT '',
                byte_count INTEGER NOT NULL DEFAULT 0,
                expires_at INTEGER NOT NULL,
                touched_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            """,
            on: db
        )
        try self.execute("CREATE INDEX IF NOT EXISTS idx_ocr_result_cache_touched_at ON ocr_result_cache(touched_at);", on: db)
        try self.execute("CREATE INDEX IF NOT EXISTS idx_ocr_result_cache_expires_at ON ocr_result_cache(expires_at);", on: db)
        try self.execute(
            """
            CREATE TABLE IF NOT EXISTS ocr_recognition_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                endpoint TEXT NOT NULL DEFAULT '',
                account_key TEXT NOT NULL DEFAULT '',
                account_label TEXT NOT NULL DEFAULT '',
                requested_model TEXT NOT NULL DEFAULT '',
                ocr_model TEXT NOT NULL DEFAULT '',
                image_index INTEGER NOT NULL,
                image_hash TEXT,
                mime_type TEXT NOT NULL DEFAULT '',
                byte_count INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                cache_hit INTEGER NOT NULL DEFAULT 0,
                latency_ms INTEGER NOT NULL DEFAULT 0,
                error_summary TEXT
            );
            """,
            on: db
        )
        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_ocr_recognition_logs_created_at ON ocr_recognition_logs(created_at DESC);",
            on: db
        )
        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_ocr_recognition_logs_status ON ocr_recognition_logs(status);",
            on: db
        )
        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_ocr_recognition_logs_image_hash ON ocr_recognition_logs(image_hash);",
            on: db
        )
        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_reasoning_cache_expires_at ON chat_completions_reasoning_cache(expires_at);",
            on: db
        )
        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_reasoning_cache_touched_at ON chat_completions_reasoning_cache(touched_at);",
            on: db
        )
    }

    private static func execute(_ sql: String, on db: OpaquePointer?, bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProxyError.message(self.lastSQLiteError(for: db))
        }
        defer { sqlite3_finalize(statement) }
        try self.bind(bindings, to: statement, db: db)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw ProxyError.message(self.lastSQLiteError(for: db))
        }
    }

    private static func initializeAccountSelectionOrder(on db: OpaquePointer?) throws {
        var statement: OpaquePointer?
        let query = """
        SELECT id
        FROM accounts
        ORDER BY enabled DESC, updated_at DESC, label COLLATE NOCASE ASC, id ASC;
        """
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProxyError.message(self.lastSQLiteError(for: db))
        }
        defer { sqlite3_finalize(statement) }

        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawID = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: rawID))
            }
        }

        for (index, id) in ids.enumerated() {
            try self.execute(
                "UPDATE accounts SET selection_order = ? WHERE id = ?;",
                on: db,
                bindings: [.int(Int64(index)), .text(id)]
            )
        }
    }

    private func readSetting(key: String) throws -> String? {
        try self.querySingle("SELECT value FROM settings WHERE key = ?;", bindings: [.text(key)])?.text("value")
    }

    private func writeSetting(key: String, value: String) throws {
        try self.execute(
            "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            bindings: [.text(key), .text(value)]
        )
    }

    private func nextAccountSelectionOrder() throws -> Int64 {
        ((try self.querySingle("SELECT COALESCE(MAX(selection_order), -1) AS max_order FROM accounts;"))?.int("max_order") ?? -1) + 1
    }

    private func compactAccountSelectionOrder() throws {
        let ids = try self.query(
            "SELECT id FROM accounts ORDER BY selection_order ASC, label COLLATE NOCASE ASC, id ASC;"
        ).map { $0.text("id") }
        for (index, id) in ids.enumerated() {
            try self.execute(
                "UPDATE accounts SET selection_order = ? WHERE id = ?;",
                bindings: [.int(Int64(index)), .text(id)]
            )
        }
    }

    private func lookupExistingAccountMetadata(
        accountKey: String
    ) throws -> (
        id: String,
        enabled: Bool,
        addedAt: Int64,
        selectionOrder: Int64,
        consecutiveFailureCount: Int64,
        cooldownUntil: Int64?,
        automaticCooldownDisabled: Bool,
        usageWindowsVisible: Bool,
        managedProxyNodeName: String?,
        modelRouting: String?,
        reasoningEffort: String?,
        supportsVision: Bool
    )? {
        guard let row = try self.querySingle(
            """
            SELECT id, enabled, added_at, selection_order, consecutive_failure_count, cooldown_until,
                   automatic_cooldown_disabled, usage_windows_visible, managed_proxy_node_name, model_routing_json,
                   reasoning_effort_json, supports_vision
            FROM accounts
            WHERE principal_id || '|' || account_id = ?;
            """,
            bindings: [.text(accountKey)]
        ) else {
            return nil
        }
        return (
            row.text("id"),
            row.int("enabled") == 1,
            row.int("added_at"),
            row.int("selection_order"),
            row.int("consecutive_failure_count"),
            row.optionalInt("cooldown_until"),
            row.int("automatic_cooldown_disabled") == 1,
            row.int("usage_windows_visible") == 1,
            row.optionalText("managed_proxy_node_name"),
            row.optionalText("model_routing_json"),
            row.optionalText("reasoning_effort_json"),
            row.int("supports_vision") == 1
        )
    }

    private func accountModelRouting(from value: String?) throws -> AccountModelRoutingConfig? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false, let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return AccountSummary.normalizedModelRouting(try Helpers.readJSON(AccountModelRoutingConfig.self, from: data))
    }

    private func accountReasoningEffort(from value: String?) throws -> AccountReasoningEffortConfig {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false, let data = trimmed.data(using: .utf8) else {
            return .defaultConfig
        }
        return try Helpers.readJSON(AccountReasoningEffortConfig.self, from: data)
    }

    private static func columnExists(_ column: String, in table: String, on db: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProxyError.message(self.lastSQLiteError(for: db))
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                let value = String(cString: name)
                if value == column {
                    return true
                }
            }
        }
        return false
    }

    private func accountMetadata(
        authJSON: String,
        fallbackAuthMode: String?,
        fallbackProviderPreset: String?,
        fallbackUpstreamBaseURL: String?
    ) -> (
        providerFamily: AccountProviderFamily,
        authMode: AccountAuthMode,
        providerPreset: OpenAICompatibleProviderPreset,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter?,
        chatCompatibilityProfile: ChatCompletionsCompatibilityProfile,
        upstreamBaseURL: String?
    ) {
        let metadata = AuthService.extractAuthMetadata(from: authJSON)
        let authMode = fallbackAuthMode
            .flatMap(AccountAuthMode.init(rawValue:))
            ?? metadata.authMode
        let providerPreset = fallbackProviderPreset
            .flatMap(OpenAICompatibleProviderPreset.init(rawValue:))
            ?? metadata.providerPreset
        let storedUpstreamBaseURL = fallbackUpstreamBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            metadata.providerFamily,
            authMode,
            providerPreset,
            metadata.upstreamAdapter,
            metadata.chatCompatibilityProfile,
            storedUpstreamBaseURL?.isEmpty == false ? storedUpstreamBaseURL : metadata.upstreamBaseURL
        )
    }

    private func upsertMetric(_ trace: ProxyRequestTrace, granularity: String, bucketStart: Int64) throws {
        let table = granularity == "hour" ? "request_stats_hourly" : "request_stats_daily"
        let existing = try self.querySingle(
            """
            SELECT success_count, failure_count, auth_failure_count, rate_limit_count, quota_failure_count,
                   total_latency_ms, latency_histogram, total_input_tokens, total_output_tokens, total_tokens, last_error
            FROM \(table)
            WHERE granularity = ? AND bucket_start = ? AND endpoint = ? AND api_key_hash = ? AND account_key = ? AND model = ?;
            """,
            bindings: [
                .text(granularity),
                .int(bucketStart),
                .text(trace.endpoint),
                .text(trace.apiKeyHash),
                .text(trace.accountKey),
                .text(trace.model),
            ]
        )
        var histogram = Self.parseHistogram(existing?.optionalText("latency_histogram"))
        Self.recordLatency(trace.latencyMS, histogram: &histogram)

        let successCount = Int(existing?.int("success_count") ?? 0) + (trace.success ? 1 : 0)
        let failureCount = Int(existing?.int("failure_count") ?? 0)
            + (trace.success || trace.failureCategory == .cancelled ? 0 : 1)
        let authFailureCount = Int(existing?.int("auth_failure_count") ?? 0) + (trace.failureCategory == .auth ? 1 : 0)
        let rateLimitCount = Int(existing?.int("rate_limit_count") ?? 0) + (trace.failureCategory == .rateLimit ? 1 : 0)
        let quotaFailureCount = Int(existing?.int("quota_failure_count") ?? 0) + (trace.failureCategory == .quota ? 1 : 0)
        let totalLatency = (existing?.int("total_latency_ms") ?? 0) + trace.latencyMS
        let totalInput = (existing?.int("total_input_tokens") ?? 0) + trace.usage.inputTokens
        let totalOutput = (existing?.int("total_output_tokens") ?? 0) + trace.usage.outputTokens
        let totalTokens = (existing?.int("total_tokens") ?? 0) + trace.usage.totalTokens
        let histogramJSON = try String(decoding: Helpers.encodeJSON(histogram), as: UTF8.self)
        let lastError = trace.lastError ?? existing?.optionalText("last_error")

        try self.execute(
            """
            INSERT OR REPLACE INTO \(table) (
                granularity, bucket_start, endpoint, api_key_hash, account_key, account_label, model,
                success_count, failure_count, auth_failure_count, rate_limit_count, quota_failure_count,
                total_latency_ms, latency_histogram, total_input_tokens, total_output_tokens, total_tokens, last_error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(granularity),
                .int(bucketStart),
                .text(trace.endpoint),
                .text(trace.apiKeyHash),
                .text(trace.accountKey),
                .text(trace.accountLabel),
                .text(trace.model),
                .int(Int64(successCount)),
                .int(Int64(failureCount)),
                .int(Int64(authFailureCount)),
                .int(Int64(rateLimitCount)),
                .int(Int64(quotaFailureCount)),
                .int(totalLatency),
                .text(histogramJSON),
                .int(totalInput),
                .int(totalOutput),
                .int(totalTokens),
                .text(lastError),
            ]
        )
    }

    @discardableResult
    private func insertRequestLog(_ trace: ProxyRequestTrace) throws -> Int64 {
        let encryptedAPIKey: Data?
        if trace.apiKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            encryptedAPIKey = nil
        } else {
            let key = try self.secretStore.masterKey()
            encryptedAPIKey = try CryptoBox.seal(Data(trace.apiKeyValue.utf8), using: key)
        }

        try self.execute(
            """
            INSERT INTO request_logs (
                created_at, endpoint, upstream_url, client_source, api_key_hash, api_key_cipher, account_key, account_label, model, actual_model,
                reasoning_effort, project_route_id, project_route_label, effective_proxy_api_key_id,
                success, latency_ms, input_tokens, output_tokens, total_tokens, cache_hit_tokens,
                failure_category, last_error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int(trace.timestamp),
                .text(trace.endpoint),
                .text(trace.upstreamURL),
                .text(trace.clientSource.rawValue),
                .text(trace.apiKeyHash),
                .blob(encryptedAPIKey),
                .text(trace.accountKey),
                .text(trace.accountLabel),
                .text(trace.model),
                .text(trace.actualModel),
                .text(trace.reasoningEffort),
                .text(trace.projectRouteID),
                .text(trace.projectRouteLabel),
                .text(trace.effectiveProxyAPIKeyID),
                .int(trace.success ? 1 : 0),
                .int(trace.latencyMS),
                .int(trace.usage.inputTokens),
                .int(trace.usage.outputTokens),
                .int(trace.usage.totalTokens),
                .int(trace.usage.cacheHitTokens),
                .text(trace.failureCategory.rawValue),
                .text(trace.lastError),
            ]
        )
        return sqlite3_last_insert_rowid(self.db)
    }

    public func insertDiagnosticRequestBody(_ input: DiagnosticRequestBodyCaptureInput) throws -> DiagnosticRequestBodyEntry {
        let bodySHA256 = DiagnosticRequestBodySupport.bodySHA256(input.body)
        let prefixSHA256 = DiagnosticRequestBodySupport.normalizedPrefixSHA256(from: input.bodyObject)
        let expiresAt = input.createdAt + Int64(max(1, input.config.retentionDays)) * 24 * 60 * 60
        let metadataJSON = self.diagnosticRequestBodyMetadataJSON(from: input.metadata)
        var status: DiagnosticRequestBodyCaptureStatus = .captured
        var relativePath: String?
        var errorSummary: String?

        if input.config.captureJSONOnly,
           (try? JSONSerialization.jsonObject(with: input.body)) == nil
        {
            status = .skipped
            errorSummary = "请求体不是可解析 JSON，已跳过完整正文保存。"
        } else if input.body.count > input.config.maxBodySizeBytes {
            status = .skipped
            errorSummary = "请求体超过诊断保存上限：\(input.body.count) bytes > \(input.config.maxBodySizeBytes) bytes。"
        } else {
            do {
                let directory = Paths.diagnosticRequestBodiesDirectoryURL(in: self.dataDirectory)
                try Helpers.ensureDirectory(directory)
                let filename = "\(input.createdAt)-\(UUID().uuidString).cpxdiag"
                let sealed = try CryptoBox.seal(input.body, using: self.secretStore.masterKey())
                try sealed.write(to: directory.appendingPathComponent(filename), options: .atomic)
                relativePath = filename
            } catch {
                status = .failed
                errorSummary = Helpers.truncate(error.localizedDescription)
            }
        }

        try self.execute(
            """
            INSERT INTO diagnostic_request_bodies (
                request_log_id, created_at, endpoint, upstream_url, account_key, account_label, model,
                actual_model, body_sha256, prefix_sha256, byte_count, relative_path, expires_at, status, error_summary,
                metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int(nil),
                .int(input.createdAt),
                .text(input.endpoint),
                .text(input.upstreamURL),
                .text(input.accountKey),
                .text(input.accountLabel),
                .text(input.model),
                .text(input.actualModel),
                .text(bodySHA256),
                .text(prefixSHA256),
                .int(Int64(input.body.count)),
                .text(relativePath),
                .int(expiresAt),
                .text(status.rawValue),
                .text(errorSummary),
                .text(metadataJSON),
            ]
        )

        return DiagnosticRequestBodyEntry(
            id: sqlite3_last_insert_rowid(self.db),
            requestLogID: nil,
            createdAt: input.createdAt,
            endpoint: input.endpoint,
            upstreamURL: input.upstreamURL,
            accountKey: input.accountKey,
            accountLabel: input.accountLabel,
            model: input.model,
            actualModel: input.actualModel,
            bodySHA256: bodySHA256,
            prefixSHA256: prefixSHA256,
            byteCount: input.body.count,
            expiresAt: expiresAt,
            status: status,
            errorSummary: errorSummary,
            metadata: input.metadata
        )
    }

    public func linkDiagnosticRequestBody(id: Int64, requestLogID: Int64) throws {
        guard id > 0, requestLogID > 0 else { return }
        try self.execute(
            "UPDATE diagnostic_request_bodies SET request_log_id = ? WHERE id = ?;",
            bindings: [.int(requestLogID), .int(id)]
        )
    }

    public func diagnosticRequestBodySummary(now: Int64 = Helpers.now()) throws -> DiagnosticRequestBodySummary {
        let row = try self.querySingle(
            """
            SELECT
                COUNT(*) AS total_count,
                COALESCE(SUM(CASE WHEN status = 'captured' THEN 1 ELSE 0 END), 0) AS captured_count,
                COALESCE(SUM(CASE WHEN expires_at <= ? THEN 1 ELSE 0 END), 0) AS expired_count,
                COALESCE(SUM(byte_count), 0) AS total_bytes,
                MIN(created_at) AS oldest_created_at,
                MAX(created_at) AS newest_created_at
            FROM diagnostic_request_bodies;
            """,
            bindings: [.int(now)]
        )
        return DiagnosticRequestBodySummary(
            totalCount: Int(row?.int("total_count") ?? 0),
            capturedCount: Int(row?.int("captured_count") ?? 0),
            expiredCount: Int(row?.int("expired_count") ?? 0),
            totalBytes: row?.int("total_bytes") ?? 0,
            oldestCreatedAt: row?.optionalInt("oldest_created_at"),
            newestCreatedAt: row?.optionalInt("newest_created_at")
        )
    }

    public func listDiagnosticRequestBodies(requestLogID: Int64? = nil, limit: Int = 20) throws -> [DiagnosticRequestBodyEntry] {
        let normalizedLimit = min(max(limit, 1), 200)
        let whereSQL: String
        let bindings: [Binding]
        if let requestLogID, requestLogID > 0 {
            whereSQL = " WHERE request_log_id = ?"
            bindings = [.int(requestLogID)]
        } else {
            whereSQL = ""
            bindings = []
        }
        let rows = try self.query(
            """
            SELECT id, request_log_id, created_at, endpoint, upstream_url, account_key, account_label, model, actual_model,
                   body_sha256, prefix_sha256, byte_count, expires_at, status, error_summary, metadata_json
            FROM diagnostic_request_bodies\(whereSQL)
            ORDER BY created_at DESC
            LIMIT \(normalizedLimit);
            """,
            bindings: bindings
        )
        return rows.map(self.diagnosticRequestBodyEntry)
    }

    public func loadDiagnosticRequestBodyDetail(id: Int64) throws -> DiagnosticRequestBodyDetail {
        let row = try self.querySingle(
            """
            SELECT id, request_log_id, created_at, endpoint, upstream_url, account_key, account_label, model, actual_model,
                   body_sha256, prefix_sha256, byte_count, relative_path, expires_at, status, error_summary, metadata_json
            FROM diagnostic_request_bodies
            WHERE id = ?;
            """,
            bindings: [.int(id)]
        )
        guard let row else {
            throw ProxyError.message("Request body diagnostic not found.")
        }
        let entry = self.diagnosticRequestBodyEntry(from: row)
        guard entry.status == DiagnosticRequestBodyCaptureStatus.captured,
              let relativePath = row.optionalText("relative_path"),
              relativePath.isEmpty == false
        else {
            return DiagnosticRequestBodyDetail(
                entry: entry,
                available: false,
                message: entry.errorSummary ?? "该诊断记录没有保存完整请求体。"
            )
        }

        let fileURL = Paths.diagnosticRequestBodiesDirectoryURL(in: self.dataDirectory)
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DiagnosticRequestBodyDetail(
                entry: entry,
                available: false,
                message: "请求体诊断文件已被清理或丢失。"
            )
        }
        do {
            let sealed = try Data(contentsOf: fileURL)
            let body = try CryptoBox.open(sealed, using: self.secretStore.masterKey())
            return DiagnosticRequestBodyDetail(
                entry: entry,
                bodyText: String(decoding: body, as: UTF8.self),
                available: true
            )
        } catch {
            return DiagnosticRequestBodyDetail(
                entry: entry,
                available: false,
                message: "请求体诊断文件无法解密：\(Helpers.truncate(error.localizedDescription))"
            )
        }
    }

    public func clearDiagnosticRequestBodies(
        _ request: ClearDiagnosticRequestBodiesRequest,
        now: Int64 = Helpers.now()
    ) throws -> ClearDiagnosticRequestBodiesResult {
        let (whereSQL, bindings) = self.diagnosticRequestBodyClearConditions(for: request, now: now)
        let rows = try self.query(
            "SELECT id, relative_path FROM diagnostic_request_bodies\(whereSQL);",
            bindings: bindings
        )
        for row in rows {
            if let relativePath = row.optionalText("relative_path"), relativePath.isEmpty == false {
                let url = Paths.diagnosticRequestBodiesDirectoryURL(in: self.dataDirectory)
                    .appendingPathComponent(relativePath)
                try? FileManager.default.removeItem(at: url)
            }
        }
        try self.execute("DELETE FROM diagnostic_request_bodies\(whereSQL);", bindings: bindings)
        return ClearDiagnosticRequestBodiesResult(
            deletedCount: Int(sqlite3_changes(self.db)),
            summary: try self.diagnosticRequestBodySummary(now: now)
        )
    }

    private func diagnosticRequestBodyEntry(from row: SQLiteRow) -> DiagnosticRequestBodyEntry {
        DiagnosticRequestBodyEntry(
            id: row.int("id"),
            requestLogID: row.optionalInt("request_log_id"),
            createdAt: row.int("created_at"),
            endpoint: row.text("endpoint"),
            upstreamURL: row.optionalText("upstream_url"),
            accountKey: row.text("account_key"),
            accountLabel: row.text("account_label"),
            model: row.text("model"),
            actualModel: row.optionalText("actual_model"),
            bodySHA256: row.text("body_sha256"),
            prefixSHA256: row.text("prefix_sha256"),
            byteCount: Int(row.int("byte_count")),
            expiresAt: row.int("expires_at"),
            status: DiagnosticRequestBodyCaptureStatus(rawValue: row.text("status")) ?? .failed,
            errorSummary: row.optionalText("error_summary"),
            metadata: self.diagnosticRequestBodyMetadata(from: row.optionalText("metadata_json"))
        )
    }

    private func diagnosticRequestBodyMetadataJSON(from metadata: [String: String]) -> String? {
        let normalized = DiagnosticRequestBodyEntry(metadata: metadata).metadata
        guard normalized.isEmpty == false,
              let data = try? Helpers.encodeJSON(normalized),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private func diagnosticRequestBodyMetadata(from text: String?) -> [String: String] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false,
              let data = text.data(using: .utf8),
              let decoded = try? Helpers.readJSON([String: String].self, from: data)
        else {
            return [:]
        }
        return DiagnosticRequestBodyEntry(metadata: decoded).metadata
    }

    private func diagnosticRequestBodyClearConditions(
        for request: ClearDiagnosticRequestBodiesRequest,
        now: Int64
    ) -> (String, [Binding]) {
        if request.clearAll {
            return ("", [])
        }

        var clauses: [String] = []
        var bindings: [Binding] = []
        if request.expiredOnly {
            clauses.append("expires_at <= ?")
            bindings.append(.int(now))
        }
        if let olderThanSeconds = request.olderThanSeconds {
            clauses.append("created_at < ?")
            bindings.append(.int(now - olderThanSeconds))
        }
        if request.requestLogIDs.isEmpty == false {
            let placeholders = Array(repeating: "?", count: request.requestLogIDs.count).joined(separator: ", ")
            clauses.append("request_log_id IN (\(placeholders))")
            bindings.append(contentsOf: request.requestLogIDs.map { .int($0) })
        }
        guard clauses.isEmpty == false else {
            return (" WHERE 0", [])
        }
        return (" WHERE " + clauses.joined(separator: " AND "), bindings)
    }

    private func requestLogConditions(for query: RequestLogQuery) -> (String, [Binding]) {
        let normalized = query.normalized()
        let bounds = normalized.effectiveTimeBounds()
        var clauses = ["created_at >= ?", "created_at <= ?"]
        var bindings: [Binding] = [
            .int(bounds.from),
            .int(bounds.to),
        ]

        if let apiKey = normalized.apiKey, !apiKey.isEmpty {
            clauses.append("api_key_hash = ?")
            bindings.append(.text(Helpers.sha256(apiKey)))
        }

        if let accountKey = normalized.accountKey, !accountKey.isEmpty {
            clauses.append("account_key = ?")
            bindings.append(.text(accountKey))
        }

        if let clientSource = normalized.clientSource {
            clauses.append("client_source = ?")
            bindings.append(.text(clientSource.rawValue))
        }

        if let model = normalized.model, !model.isEmpty {
            clauses.append("model = ?")
            bindings.append(.text(model))
        }

        return (" WHERE " + clauses.joined(separator: " AND "), bindings)
    }

    private func loadRequestLogEntries(
        query: RequestLogQuery,
        bindings: [Binding],
        limitClause: String
    ) throws -> [RequestLogEntry] {
        let normalized = query.normalized()
        let key = try self.secretStore.masterKey()
        let (whereSQL, _) = self.requestLogConditions(for: normalized)
        let orderBy = self.requestLogOrderClause(for: normalized)
        let rows = try self.query(
            """
            SELECT id, created_at, endpoint, upstream_url, client_source, api_key_cipher, account_key, account_label, model, actual_model, reasoning_effort,
                   project_route_id, project_route_label, effective_proxy_api_key_id,
                   success, latency_ms, input_tokens, output_tokens, total_tokens, cache_hit_tokens,
                   failure_category, last_error,
                   EXISTS(SELECT 1 FROM diagnostic_request_bodies WHERE request_log_id = request_logs.id AND status = 'captured') AS has_diagnostic_request_body
            FROM request_logs\(whereSQL)
            ORDER BY \(orderBy)\(limitClause);
            """,
            bindings: bindings
        )

        return try rows.map { row in
            let decryptedAPIKey: String
            if let cipher = row.optionalBlob("api_key_cipher"), !cipher.isEmpty {
                decryptedAPIKey = String(decoding: try CryptoBox.open(cipher, using: key), as: UTF8.self)
            } else {
                decryptedAPIKey = ""
            }

            return RequestLogEntry(
                id: row.int("id"),
                timestamp: row.int("created_at"),
                endpoint: row.text("endpoint"),
                upstreamURL: row.optionalText("upstream_url"),
                clientSource: RequestLogClientSource(rawValue: row.text("client_source")) ?? .other,
                model: row.text("model"),
                actualModel: row.optionalText("actual_model"),
                reasoningEffort: row.optionalText("reasoning_effort"),
                projectRouteID: row.optionalText("project_route_id"),
                projectRouteLabel: row.optionalText("project_route_label"),
                effectiveProxyAPIKeyID: row.optionalText("effective_proxy_api_key_id"),
                apiKey: decryptedAPIKey,
                accountKey: row.text("account_key"),
                accountLabel: row.text("account_label"),
                success: row.int("success") == 1,
                latencyMS: row.int("latency_ms"),
                inputTokens: row.int("input_tokens"),
                outputTokens: row.int("output_tokens"),
                totalTokens: row.int("total_tokens"),
                cacheHitTokens: row.optionalInt("cache_hit_tokens"),
                failureCategory: row.text("failure_category"),
                errorSummary: row.optionalText("last_error"),
                hasDiagnosticRequestBody: row.int("has_diagnostic_request_body") == 1
            )
        }
    }

    private func requestLogOrderClause(for query: RequestLogQuery) -> String {
        let normalized = query.normalized()
        let direction = normalized.sortDirection == .ascending ? "ASC" : "DESC"
        let timeFallback = "created_at DESC, id DESC"

        switch normalized.sortBy {
        case .time:
            return "created_at \(direction), id \(direction)"
        case .endpoint:
            return "endpoint COLLATE NOCASE \(direction), \(timeFallback)"
        case .model:
            return "model COLLATE NOCASE \(direction), \(timeFallback)"
        case .accountLabel:
            return "account_label COLLATE NOCASE \(direction), \(timeFallback)"
        case .status:
            return "success \(direction), \(timeFallback)"
        case .latency:
            return "latency_ms \(direction), \(timeFallback)"
        case .totalTokens:
            return "total_tokens \(direction), \(timeFallback)"
        }
    }

    private func loadNaturalTokenUsageSummary(
        now: Date = Date(),
        calendar: Calendar = .current,
        apiKeyHash: String? = nil
    ) throws -> AdminStatsSummary.NaturalTokenUsageSummary {
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = self.startOfMondayWeek(for: now, calendar: calendar)
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart
        let upperBound = Int64(now.timeIntervalSince1970)
        let earliestTrendWeekStart = calendar.date(byAdding: .day, value: -21, to: weekStart) ?? weekStart
        let earliestTrendMonthStart = calendar.date(byAdding: .month, value: -11, to: monthStart) ?? monthStart
        let dailyTrend = try self.loadNaturalDailyTrend(
            from: Int64(earliestTrendWeekStart.timeIntervalSince1970),
            to: upperBound,
            calendar: calendar,
            apiKeyHash: apiKeyHash
        )
        let weeklyTrend = self.loadNaturalWeeklyTrend(
            dailyTrend: dailyTrend,
            currentWeekStart: weekStart,
            calendar: calendar
        )
        let monthlyTrend = try self.loadNaturalMonthlyTrend(
            from: Int64(earliestTrendMonthStart.timeIntervalSince1970),
            to: upperBound,
            currentMonthStart: monthStart,
            calendar: calendar,
            apiKeyHash: apiKeyHash
        )

        return AdminStatsSummary.NaturalTokenUsageSummary(
            today: try self.loadTokenUsageRange(
                from: Int64(todayStart.timeIntervalSince1970),
                to: upperBound,
                apiKeyHash: apiKeyHash
            ),
            week: try self.loadTokenUsageRange(
                from: Int64(weekStart.timeIntervalSince1970),
                to: upperBound,
                apiKeyHash: apiKeyHash
            ),
            month: try self.loadTokenUsageRange(
                from: Int64(monthStart.timeIntervalSince1970),
                to: upperBound,
                apiKeyHash: apiKeyHash
            ),
            dailyTrend: dailyTrend,
            weeklyTrend: weeklyTrend,
            monthlyTrend: monthlyTrend
        )
    }

    private func loadNaturalDailyTrend(
        from: Int64,
        to: Int64,
        calendar: Calendar,
        apiKeyHash: String? = nil
    ) throws -> [AdminStatsSummary.NaturalTimeBucketUsage] {
        // Use request_logs so local-day boundaries match the natural day/week cards.
        let apiKeySQL = apiKeyHash == nil ? "" : " AND api_key_hash = ?"
        var bindings: [Binding] = [
            .int(from),
            .int(to),
        ]
        if let apiKeyHash {
            bindings.append(.text(apiKeyHash))
        }
        let rows = try self.query(
            """
            SELECT
                date(created_at, 'unixepoch', 'localtime') AS local_day,
                COUNT(*) AS request_count,
                COALESCE(SUM(input_tokens), 0) AS total_input_tokens,
                COALESCE(SUM(output_tokens), 0) AS total_output_tokens,
                COALESCE(SUM(COALESCE(cache_hit_tokens, 0)), 0) AS total_cache_hit_tokens,
                COALESCE(SUM(CASE WHEN input_tokens - COALESCE(cache_hit_tokens, 0) > 0 THEN input_tokens - COALESCE(cache_hit_tokens, 0) ELSE 0 END), 0) AS total_cache_miss_tokens
            FROM request_logs
            WHERE created_at >= ? AND created_at <= ?
            \(apiKeySQL)
            GROUP BY local_day
            ORDER BY local_day ASC;
            """,
            bindings: bindings
        )

        return try rows.map { row in
            AdminStatsSummary.NaturalTimeBucketUsage(
                bucketStart: try self.localDayStartTimestamp(from: row.text("local_day"), calendar: calendar),
                windowSeconds: 86_400,
                requestCount: row.int("request_count"),
                inputTokens: row.int("total_input_tokens"),
                outputTokens: row.int("total_output_tokens"),
                cacheHitTokens: row.int("total_cache_hit_tokens"),
                cacheMissTokens: row.int("total_cache_miss_tokens")
            )
        }
    }

    private func loadNaturalWeeklyTrend(
        dailyTrend: [AdminStatsSummary.NaturalTimeBucketUsage],
        currentWeekStart: Date,
        calendar: Calendar
    ) -> [AdminStatsSummary.NaturalTimeBucketUsage] {
        var grouped: [Int64: AdminStatsSummary.NaturalTimeBucketUsage] = [:]

        for bucket in dailyTrend {
            let bucketDate = Date(timeIntervalSince1970: TimeInterval(bucket.bucketStart))
            let weekStart = self.startOfMondayWeek(for: bucketDate, calendar: calendar)
            let weekStartTimestamp = Int64(weekStart.timeIntervalSince1970)
            let existing = grouped[weekStartTimestamp] ?? AdminStatsSummary.NaturalTimeBucketUsage(
                bucketStart: weekStartTimestamp,
                windowSeconds: 604_800
            )
            grouped[weekStartTimestamp] = AdminStatsSummary.NaturalTimeBucketUsage(
                bucketStart: weekStartTimestamp,
                windowSeconds: 604_800,
                requestCount: existing.requestCount + bucket.requestCount,
                inputTokens: existing.inputTokens + bucket.inputTokens,
                outputTokens: existing.outputTokens + bucket.outputTokens,
                cacheHitTokens: existing.cacheHitTokens + bucket.cacheHitTokens,
                cacheMissTokens: existing.cacheMissTokens + bucket.cacheMissTokens
            )
        }

        return (-3...0).compactMap { offset -> AdminStatsSummary.NaturalTimeBucketUsage? in
            guard let weekStart = calendar.date(byAdding: .day, value: offset * 7, to: currentWeekStart) else {
                return nil
            }
            let timestamp = Int64(weekStart.timeIntervalSince1970)
            return grouped[timestamp] ?? AdminStatsSummary.NaturalTimeBucketUsage(
                bucketStart: timestamp,
                windowSeconds: 604_800
            )
        }
    }

    private func loadNaturalMonthlyTrend(
        from: Int64,
        to: Int64,
        currentMonthStart: Date,
        calendar: Calendar,
        apiKeyHash: String? = nil
    ) throws -> [AdminStatsSummary.NaturalTimeBucketUsage] {
        let apiKeySQL = apiKeyHash == nil ? "" : " AND api_key_hash = ?"
        var bindings: [Binding] = [
            .int(from),
            .int(to),
        ]
        if let apiKeyHash {
            bindings.append(.text(apiKeyHash))
        }
        let rows = try self.query(
            """
            SELECT
                strftime('%Y-%m', created_at, 'unixepoch', 'localtime') AS local_month,
                COUNT(*) AS request_count,
                COALESCE(SUM(input_tokens), 0) AS total_input_tokens,
                COALESCE(SUM(output_tokens), 0) AS total_output_tokens,
                COALESCE(SUM(COALESCE(cache_hit_tokens, 0)), 0) AS total_cache_hit_tokens,
                COALESCE(SUM(CASE WHEN input_tokens - COALESCE(cache_hit_tokens, 0) > 0 THEN input_tokens - COALESCE(cache_hit_tokens, 0) ELSE 0 END), 0) AS total_cache_miss_tokens
            FROM request_logs
            WHERE created_at >= ? AND created_at <= ?
            \(apiKeySQL)
            GROUP BY local_month
            ORDER BY local_month ASC;
            """,
            bindings: bindings
        )

        var grouped: [Int64: AdminStatsSummary.NaturalTimeBucketUsage] = [:]
        for row in rows {
            let bucketStart = try self.localMonthStartTimestamp(from: row.text("local_month"), calendar: calendar)
            let bucketDate = Date(timeIntervalSince1970: TimeInterval(bucketStart))
            grouped[bucketStart] = AdminStatsSummary.NaturalTimeBucketUsage(
                bucketStart: bucketStart,
                windowSeconds: self.monthWindowSeconds(start: bucketDate, calendar: calendar),
                requestCount: row.int("request_count"),
                inputTokens: row.int("total_input_tokens"),
                outputTokens: row.int("total_output_tokens"),
                cacheHitTokens: row.int("total_cache_hit_tokens"),
                cacheMissTokens: row.int("total_cache_miss_tokens")
            )
        }

        return stride(from: 11, through: 0, by: -1).compactMap { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart) else {
                return nil
            }
            let timestamp = Int64(monthStart.timeIntervalSince1970)
            return grouped[timestamp] ?? AdminStatsSummary.NaturalTimeBucketUsage(
                bucketStart: timestamp,
                windowSeconds: self.monthWindowSeconds(start: monthStart, calendar: calendar)
            )
        }
    }

    private func loadTokenUsageRange(
        from: Int64,
        to: Int64,
        apiKeyHash: String? = nil
    ) throws -> AdminStatsSummary.NaturalRangeTokenUsage {
        let apiKeySQL = apiKeyHash == nil ? "" : " AND api_key_hash = ?"
        var bindings: [Binding] = [
            .int(from),
            .int(to),
        ]
        if let apiKeyHash {
            bindings.append(.text(apiKeyHash))
        }
        let row = try self.querySingle(
            """
            SELECT
                COUNT(*) AS request_count,
                COALESCE(SUM(input_tokens), 0) AS total_input_tokens,
                COALESCE(SUM(output_tokens), 0) AS total_output_tokens,
                COALESCE(SUM(COALESCE(cache_hit_tokens, 0)), 0) AS total_cache_hit_tokens,
                COALESCE(SUM(CASE WHEN input_tokens - COALESCE(cache_hit_tokens, 0) > 0 THEN input_tokens - COALESCE(cache_hit_tokens, 0) ELSE 0 END), 0) AS total_cache_miss_tokens
            FROM request_logs
            WHERE created_at >= ? AND created_at <= ?
            \(apiKeySQL);
            """,
            bindings: bindings
        )

        return AdminStatsSummary.NaturalRangeTokenUsage(
            requestCount: row?.int("request_count") ?? 0,
            inputTokens: row?.int("total_input_tokens") ?? 0,
            outputTokens: row?.int("total_output_tokens") ?? 0,
            cacheHitTokens: row?.int("total_cache_hit_tokens") ?? 0,
            cacheMissTokens: row?.int("total_cache_miss_tokens") ?? 0
        )
    }

    private func traceHourStart(for timestamp: Int64) -> Int64 {
        timestamp - (timestamp % 3600)
    }

    private func traceDayStart(for timestamp: Int64) -> Int64 {
        timestamp - (timestamp % 86_400)
    }

    private func startOfMondayWeek(
        for date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let offset = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: startOfDay) ?? startOfDay
    }

    private func localDayStartTimestamp(
        from text: String,
        calendar: Calendar
    ) throws -> Int64 {
        let components = text.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              let date = calendar.date(
                  from: DateComponents(
                      calendar: calendar,
                      timeZone: calendar.timeZone,
                      year: year,
                      month: month,
                      day: day
                  )
              )
        else {
            throw ProxyError.message("无法解析本地日期桶：\(text)")
        }
        return Int64(date.timeIntervalSince1970)
    }

    private func localMonthStartTimestamp(
        from text: String,
        calendar: Calendar
    ) throws -> Int64 {
        let components = text.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let date = calendar.date(
                  from: DateComponents(
                      calendar: calendar,
                      timeZone: calendar.timeZone,
                      year: year,
                      month: month,
                      day: 1
                  )
              )
        else {
            throw ProxyError.message("无法解析本地月份桶：\(text)")
        }
        return Int64(date.timeIntervalSince1970)
    }

    private func monthWindowSeconds(
        start: Date,
        calendar: Calendar
    ) -> Int64 {
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(31 * 86_400)
        return max(0, Int64(nextMonthStart.timeIntervalSince(start)))
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        try self.withDatabaseLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ProxyError.message(self.lastSQLiteError())
            }
            defer { sqlite3_finalize(statement) }
            try Self.bind(bindings, to: statement, db: self.db)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw ProxyError.message(self.lastSQLiteError())
            }
        }
    }

    private func query(_ sql: String, bindings: [Binding] = []) throws -> [SQLiteRow] {
        try self.withDatabaseLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ProxyError.message(self.lastSQLiteError())
            }
            defer { sqlite3_finalize(statement) }
            try Self.bind(bindings, to: statement, db: self.db)

            var rows: [SQLiteRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(SQLiteRow(statement: statement))
            }
            return rows
        }
    }

    private func querySingle(_ sql: String, bindings: [Binding] = []) throws -> SQLiteRow? {
        try self.query(sql, bindings: bindings).first
    }

    private static func bind(_ bindings: [Binding], to statement: OpaquePointer, db: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            var result: Int32 = SQLITE_OK
            switch binding {
            case .text(let value):
                if let value {
                    result = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
                } else {
                    result = sqlite3_bind_null(statement, position)
                }
            case .int(let value):
                if let value {
                    result = sqlite3_bind_int64(statement, position, value)
                } else {
                    result = sqlite3_bind_null(statement, position)
                }
            case .blob(let value):
                if let value {
                    value.withUnsafeBytes { bytes in
                        result = sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
                    }
                } else {
                    result = sqlite3_bind_null(statement, position)
                }
            }
            guard result == SQLITE_OK else {
                throw ProxyError.message(self.lastSQLiteError(for: db))
            }
        }
    }

    private func lastSQLiteError() -> String {
        Self.lastSQLiteError(for: self.db)
    }

    private func latestCipherForAPIKeyHash(_ hash: String, whereSQL: String, bindings: [Binding]) throws -> Data? {
        try self.querySingle(
            """
            SELECT api_key_cipher
            FROM request_logs\(whereSQL)\(whereSQL.isEmpty ? " WHERE " : " AND ")api_key_hash = ?
                  AND api_key_cipher IS NOT NULL
            ORDER BY created_at DESC, id DESC
            LIMIT 1;
            """,
            bindings: bindings + [.text(hash)]
        )?.optionalBlob("api_key_cipher")
    }

    private func withDatabaseLock<T>(_ operation: () throws -> T) throws -> T {
        self.databaseLock.lock()
        defer { self.databaseLock.unlock() }
        return try operation()
    }

    private func withDatabaseTransaction<T>(_ operation: () throws -> T) throws -> T {
        try self.withDatabaseLock {
            guard sqlite3_exec(self.db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
                throw ProxyError.message(self.lastSQLiteError())
            }
            do {
                let result = try operation()
                guard sqlite3_exec(self.db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw ProxyError.message(self.lastSQLiteError())
                }
                return result
            } catch {
                sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    private static func lastSQLiteError(for db: OpaquePointer?) -> String {
        if let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "Unknown SQLite error"
    }

    private static let latencyBoundaries: [Int64] = [50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000]

    private static func parseHistogram(_ text: String?) -> [String: Int] {
        guard let text, let data = text.data(using: .utf8), let histogram = try? Helpers.readJSON([String: Int].self, from: data) else {
            return [:]
        }
        return histogram
    }

    private static func recordLatency(_ latency: Int64, histogram: inout [String: Int]) {
        let bucket = self.latencyBoundaries.first(where: { latency <= $0 }) ?? 99_999
        histogram[String(bucket), default: 0] += 1
    }

    private static func histogramToP95(_ text: String?) -> Int64 {
        let histogram = self.parseHistogram(text)
        let sorted = histogram.compactMap { (key, value) -> (Int64, Int)? in
            guard let boundary = Int64(key) else { return nil }
            return (boundary, value)
        }.sorted { $0.0 < $1.0 }
        let total = sorted.map(\.1).reduce(0, +)
        guard total > 0 else { return 0 }
        let target = Int(Double(total) * 0.95.rounded(.up))
        var running = 0
        for (boundary, count) in sorted {
            running += count
            if running >= target {
                return boundary
            }
        }
        return sorted.last?.0 ?? 0
    }
}

private enum Binding {
    case text(String?)
    case int(Int64?)
    case blob(Data?)
}

private struct SQLiteRow {
    private let values: [String: SQLiteValue]

    init(statement: OpaquePointer) {
        var mapped: [String: SQLiteValue] = [:]
        let count = sqlite3_column_count(statement)
        for index in 0..<count {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                mapped[name] = .int(sqlite3_column_int64(statement, index))
            case SQLITE_BLOB:
                let length = Int(sqlite3_column_bytes(statement, index))
                let pointer = sqlite3_column_blob(statement, index)
                let data = pointer.map { Data(bytes: $0, count: length) } ?? Data()
                mapped[name] = .blob(data)
            case SQLITE_NULL:
                mapped[name] = .null
            default:
                let text = sqlite3_column_text(statement, index).map { String(cString: $0) }
                mapped[name] = .text(text ?? "")
            }
        }
        self.values = mapped
    }

    func text(_ key: String) -> String {
        switch self.values[key] {
        case .text(let value):
            return value
        case .int(let value):
            return String(value)
        case .blob(let data):
            return String(decoding: data, as: UTF8.self)
        default:
            return ""
        }
    }

    func optionalText(_ key: String) -> String? {
        switch self.values[key] {
        case .text(let value):
            return value
        case .int(let value):
            return String(value)
        case .blob(let data):
            return String(decoding: data, as: UTF8.self)
        default:
            return nil
        }
    }

    func int(_ key: String) -> Int64 {
        switch self.values[key] {
        case .int(let value):
            return value
        case .text(let value):
            return Int64(value) ?? 0
        default:
            return 0
        }
    }

    func optionalInt(_ key: String) -> Int64? {
        switch self.values[key] {
        case .int(let value):
            return value
        case .text(let value):
            return Int64(value)
        default:
            return nil
        }
    }

    func blob(_ key: String) -> Data {
        switch self.values[key] {
        case .blob(let data):
            return data
        case .text(let value):
            return Data(value.utf8)
        default:
            return Data()
        }
    }

    func optionalBlob(_ key: String) -> Data? {
        switch self.values[key] {
        case .blob(let data):
            return data
        case .text(let value):
            return Data(value.utf8)
        default:
            return nil
        }
    }
}

private enum SQLiteValue {
    case text(String)
    case int(Int64)
    case blob(Data)
    case null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
