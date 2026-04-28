#if os(macOS)
import CodexProxyCore
import Foundation

enum ProxyWorkspaceTab: String, CaseIterable, Identifiable {
    case access
    case apiKeys
    case usage
    case advanced

    var id: String { self.rawValue }

    var symbolName: String {
        switch self {
        case .access:
            return "link.circle"
        case .apiKeys:
            return "key.fill"
        case .usage:
            return "chart.bar.xaxis"
        case .advanced:
            return "slider.horizontal.3"
        }
    }
}

enum ProxyAPIKeyUsagePreset: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case custom

    var id: String { self.rawValue }
}

struct ProxyAPIKeyUsageFilter: Equatable, Sendable {
    var preset: ProxyAPIKeyUsagePreset
    var customFromDate: Date
    var customToDate: Date

    init(
        preset: ProxyAPIKeyUsagePreset = .today,
        customFromDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
        customToDate: Date = Date()
    ) {
        self.preset = preset
        self.customFromDate = customFromDate
        self.customToDate = customToDate
    }

    func timeRange(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
        switch self.preset {
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, now)
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            return (interval?.start ?? calendar.startOfDay(for: now), now)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            return (interval?.start ?? calendar.startOfDay(for: now), now)
        case .custom:
            if self.customFromDate <= self.customToDate {
                return (self.customFromDate, self.customToDate)
            }
            return (self.customToDate, self.customFromDate)
        }
    }

    var query: RequestLogQuery {
        let range = self.timeRange()
        return RequestLogQuery(
            timePreset: .custom,
            from: Int64(range.from.timeIntervalSince1970),
            to: Int64(range.to.timeIntervalSince1970)
        )
    }
}

struct ProxyAPIKeyDraft: Identifiable, Equatable {
    let id = UUID()
    var editingID: String?
    var label: String
    var key: String
    var dataSource: ProxyDataSource
    var allowedAccountKeys: [String]
    var enabled: Bool
    var isPrimary: Bool

    init(
        editingID: String? = nil,
        label: String = "",
        key: String = AppConfig.generatedProxyAPIKey(),
        dataSource: ProxyDataSource = .all,
        allowedAccountKeys: [String] = [],
        enabled: Bool = true,
        isPrimary: Bool = false
    ) {
        self.editingID = editingID
        self.label = label
        self.key = key
        self.dataSource = dataSource
        self.allowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(allowedAccountKeys)
        self.enabled = enabled
        self.isPrimary = isPrimary
    }
}

struct ProxyAPIKeyAccountOption: Identifiable, Equatable {
    let account: AccountSummary
    let title: String
    let secondaryText: String

    var id: String { self.account.accountKey }
    var accountKey: String { self.account.accountKey }
}

struct ProxyAPIKeyStaleSelection: Identifiable, Equatable {
    let accountKey: String
    let title: String
    let secondaryText: String?
    let reason: String

    var id: String { self.accountKey }
}

struct ProxyAPIKeyAccountEditorContext: Equatable {
    var selectableOptions: [ProxyAPIKeyAccountOption]
    var staleSelections: [ProxyAPIKeyStaleSelection]
}

struct ProxyAPIKeyRestrictionSummary: Equatable {
    let text: String
    let staleCount: Int
}

@MainActor
extension DesktopAppModel {
    var configuredProxyAPIKeys: [ProxyAPIKeyRecord] {
        let normalized = self.settings.normalizedAnthropicModelConfig()
        let primaryID = normalized.primaryProxyAPIKeyID
        return normalized.proxyAPIKeys.sorted { lhs, rhs in
            let lhsPrimary = lhs.id == primaryID
            let rhsPrimary = rhs.id == primaryID
            if lhsPrimary != rhsPrimary {
                return lhsPrimary && !rhsPrimary
            }
            if lhs.enabled != rhs.enabled {
                return lhs.enabled && !rhs.enabled
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    var proxyUsageRangeText: String {
        let formatter = DesktopDateTimeFormat.makeFormatter()
        let range = self.proxyAPIKeyUsageFilter.timeRange()
        return "\(formatter.string(from: range.from)) - \(formatter.string(from: range.to))"
    }

    func proxyWorkspaceTabTitle(_ tab: ProxyWorkspaceTab) -> String {
        switch tab {
        case .access:
            return self.text(.sectionAccessInfo)
        case .apiKeys:
            return self.text(.sectionAPIKeys)
        case .usage:
            return self.text(.sectionAPIKeyUsage)
        case .advanced:
            return self.text(.sectionAdvanced)
        }
    }

    func proxyAPIKeyUsagePresetTitle(_ preset: ProxyAPIKeyUsagePreset) -> String {
        switch preset {
        case .today:
            return self.text(.optionToday)
        case .week:
            return self.text(.optionThisWeek)
        case .month:
            return self.text(.optionThisMonth)
        case .custom:
            return self.text(.optionCustom)
        }
    }

    func proxyAPIKeyDisplayLabel(_ record: ProxyAPIKeyRecord) -> String {
        let trimmed = record.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? self.text(.labelAPIKey) : trimmed
    }

    func proxyAPIKeyMaskedValue(_ record: ProxyAPIKeyRecord) -> String {
        RequestLogPresentation.maskedAPIKey(record.key)
    }

    func proxyUsageMaskedKey(_ entry: ProxyAPIKeyUsageEntry) -> String {
        let trimmed = entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return self.text(.statusNoData) }
        return RequestLogPresentation.maskedAPIKey(trimmed)
    }

    func proxyUsageFailureRateText(_ entry: ProxyAPIKeyUsageEntry) -> String {
        guard entry.requestCount > 0 else { return "0%" }
        let rate = (Double(entry.failureCount) / Double(entry.requestCount)) * 100
        return String(format: "%.1f%%", rate)
    }

    func proxyUsageAverageLatencyText(_ entry: ProxyAPIKeyUsageEntry) -> String {
        self.localization.requestLogsLatencyText(entry.averageLatencyMS)
    }

    func proxyUsageLastUsedText(_ entry: ProxyAPIKeyUsageEntry) -> String {
        guard let lastUsedAt = entry.lastUsedAt else { return self.text(.statusNoData) }
        return DesktopDateTimeFormat.string(fromUnixSeconds: lastUsedAt)
    }

    func proxySummaryTokenText(_ value: Int64) -> String {
        OverviewNumberFormat.abbreviated(value)
    }

    func proxySummaryTokenHelp(_ value: Int64) -> String {
        OverviewNumberFormat.full(value)
    }

    func proxySummaryTokenText(_ value: Int64?) -> String {
        guard let value else { return self.text(.statusNoData) }
        return self.proxySummaryTokenText(value)
    }

    func proxySummaryTokenHelp(_ value: Int64?) -> String? {
        guard let value else { return nil }
        return self.proxySummaryTokenHelp(value)
    }

    func openAddProxyAPIKeySheet() {
        self.proxyAPIKeyDraft = ProxyAPIKeyDraft(
            isPrimary: self.configuredProxyAPIKeys.isEmpty
        )
    }

    func openEditProxyAPIKeySheet(_ record: ProxyAPIKeyRecord) {
        self.proxyAPIKeyDraft = ProxyAPIKeyDraft(
            editingID: record.id,
            label: record.label,
            key: record.key,
            dataSource: record.dataSource,
            allowedAccountKeys: record.allowedAccountKeys,
            enabled: record.enabled,
            isPrimary: self.settings.primaryProxyAPIKeyID == record.id
        )
    }

    func dismissProxyAPIKeySheet() {
        self.proxyAPIKeyDraft = nil
    }

    func saveProxyAPIKeyDraft() async {
        guard var draft = self.proxyAPIKeyDraft else { return }
        let trimmedKey = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty == false else {
            self.publishBanner(.warning, title: self.text(.errorProxyAPIKeyFailed), detail: self.text(.helperProxyAPIKeyValueRequired))
            return
        }

        draft.key = trimmedKey
        let trimmedLabel = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.label = trimmedLabel.isEmpty ? self.text(.labelAPIKey) : trimmedLabel
        draft.allowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(draft.allowedAccountKeys)

        let savedRecordID: String
        if let editingID = draft.editingID,
           let index = self.settings.proxyAPIKeys.firstIndex(where: { $0.id == editingID })
        {
            self.settings.proxyAPIKeys[index].label = draft.label
            self.settings.proxyAPIKeys[index].key = draft.key
            self.settings.proxyAPIKeys[index].dataSource = draft.dataSource
            self.settings.proxyAPIKeys[index].allowedAccountKeys = draft.allowedAccountKeys
            self.settings.proxyAPIKeys[index].enabled = draft.enabled
            savedRecordID = self.settings.proxyAPIKeys[index].id
        } else {
            let record = ProxyAPIKeyRecord(
                label: draft.label,
                key: draft.key,
                dataSource: draft.dataSource,
                allowedAccountKeys: draft.allowedAccountKeys,
                enabled: draft.enabled
            )
            self.settings.proxyAPIKeys.append(
                record
            )
            savedRecordID = record.id
        }

        if draft.isPrimary {
            self.settings.primaryProxyAPIKeyID = savedRecordID
        }
        let didPersist = await self.persistProxyAPIKeySettings(
            successTitle: self.text(draft.editingID == nil ? .successProxyAPIKeyAdded : .successProxyAPIKeyUpdated),
            detail: draft.label
        )
        if didPersist {
            self.proxyAPIKeyDraft = nil
        }
    }

    func deleteProxyAPIKey(_ record: ProxyAPIKeyRecord) async {
        guard self.settings.proxyAPIKeys.count > 1 else {
            self.publishBanner(.warning, title: self.text(.errorProxyAPIKeyFailed), detail: self.text(.helperProxyAPIKeyAtLeastOne))
            return
        }
        self.settings.proxyAPIKeys.removeAll { $0.id == record.id }
        if self.settings.primaryProxyAPIKeyID == record.id {
            self.settings.primaryProxyAPIKeyID = self.settings.proxyAPIKeys.first(where: \.enabled)?.id ?? self.settings.proxyAPIKeys.first?.id
        }
        await self.persistProxyAPIKeySettings(successTitle: self.text(.successProxyAPIKeyRemoved), detail: record.label)
    }

    func regenerateProxyAPIKey(_ record: ProxyAPIKeyRecord) async {
        guard let index = self.settings.proxyAPIKeys.firstIndex(where: { $0.id == record.id }) else { return }
        self.settings.proxyAPIKeys[index].key = AppConfig.generatedProxyAPIKey()
        await self.persistProxyAPIKeySettings(successTitle: self.text(.successProxyAPIKeyRegenerated), detail: record.label)
    }

    func setPrimaryProxyAPIKey(_ record: ProxyAPIKeyRecord) async {
        guard let index = self.settings.proxyAPIKeys.firstIndex(where: { $0.id == record.id }) else { return }
        self.settings.proxyAPIKeys[index].enabled = true
        self.settings.primaryProxyAPIKeyID = record.id
        await self.persistProxyAPIKeySettings(successTitle: self.text(.successProxyAPIKeyPrimaryChanged), detail: record.label)
    }

    func proxyAPIKeyAccountEditorContext(draft: ProxyAPIKeyDraft? = nil) -> ProxyAPIKeyAccountEditorContext {
        let resolvedDraft = draft ?? self.proxyAPIKeyDraft
        guard let resolvedDraft else {
            return ProxyAPIKeyAccountEditorContext(selectableOptions: [], staleSelections: [])
        }
        return self.proxyAPIKeyAccountEditorContext(
            allowedAccountKeys: resolvedDraft.allowedAccountKeys,
            dataSource: resolvedDraft.dataSource
        )
    }

    func isProxyAPIKeyAccountSelected(_ accountKey: String, draft: ProxyAPIKeyDraft? = nil) -> Bool {
        let normalized = ProxyAPIKeyRecord.normalizedAllowedAccountKeys((draft ?? self.proxyAPIKeyDraft)?.allowedAccountKeys ?? [])
        return normalized.contains(accountKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func toggleProxyAPIKeyAllowedAccount(_ accountKey: String) {
        guard var draft = self.proxyAPIKeyDraft else { return }
        let trimmedAccountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAccountKey.isEmpty == false else { return }

        if draft.allowedAccountKeys.contains(trimmedAccountKey) {
            draft.allowedAccountKeys.removeAll { $0 == trimmedAccountKey }
        } else {
            draft.allowedAccountKeys.append(trimmedAccountKey)
        }
        draft.allowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(draft.allowedAccountKeys)
        self.proxyAPIKeyDraft = draft
    }

    func removeProxyAPIKeyAllowedAccount(_ accountKey: String) {
        guard var draft = self.proxyAPIKeyDraft else { return }
        let trimmedAccountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.allowedAccountKeys.removeAll { $0 == trimmedAccountKey }
        draft.allowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(draft.allowedAccountKeys)
        self.proxyAPIKeyDraft = draft
    }

    func selectAllCompatibleProxyAPIKeyAccounts() {
        guard var draft = self.proxyAPIKeyDraft else { return }
        let options = self.proxyAPIKeyAccountEditorContext(draft: draft).selectableOptions
        for option in options where draft.allowedAccountKeys.contains(option.accountKey) == false {
            draft.allowedAccountKeys.append(option.accountKey)
        }
        draft.allowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(draft.allowedAccountKeys)
        self.proxyAPIKeyDraft = draft
    }

    func clearProxyAPIKeyAllowedAccounts() {
        guard var draft = self.proxyAPIKeyDraft else { return }
        draft.allowedAccountKeys = []
        self.proxyAPIKeyDraft = draft
    }

    func proxyAPIKeyRestrictionSummary(for record: ProxyAPIKeyRecord) -> ProxyAPIKeyRestrictionSummary {
        let normalizedAllowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(record.allowedAccountKeys)
        guard normalizedAllowedAccountKeys.isEmpty == false else {
            return ProxyAPIKeyRestrictionSummary(
                text: self.localized(zh: "全部兼容账号", en: "all compatible accounts"),
                staleCount: 0
            )
        }

        let context = self.proxyAPIKeyAccountEditorContext(
            allowedAccountKeys: normalizedAllowedAccountKeys,
            dataSource: record.dataSource
        )
        let titleByAccountKey = Dictionary(uniqueKeysWithValues: context.selectableOptions.map { ($0.accountKey, $0.title) })
        let currentTitles = normalizedAllowedAccountKeys.compactMap { titleByAccountKey[$0] }
        let totalCount = normalizedAllowedAccountKeys.count
        let summaryText: String

        if totalCount == 1, let firstTitle = currentTitles.first {
            summaryText = firstTitle
        } else if totalCount == 2, context.staleSelections.isEmpty, currentTitles.count == 2 {
            summaryText = currentTitles.joined(separator: ", ")
        } else {
            summaryText = self.localized(
                zh: "已限制 \(totalCount) 个账号",
                en: "\(totalCount) accounts selected"
            )
        }

        return ProxyAPIKeyRestrictionSummary(
            text: summaryText,
            staleCount: context.staleSelections.count
        )
    }

    func setProxyAPIKeyEnabled(_ record: ProxyAPIKeyRecord, enabled: Bool) async {
        guard let index = self.settings.proxyAPIKeys.firstIndex(where: { $0.id == record.id }) else { return }
        if enabled == false && self.settings.proxyAPIKeys.filter(\.enabled).count <= 1 {
            self.publishBanner(.warning, title: self.text(.errorProxyAPIKeyFailed), detail: self.text(.helperProxyAPIKeyAtLeastOneEnabled))
            return
        }

        self.settings.proxyAPIKeys[index].enabled = enabled
        if enabled == false && self.settings.primaryProxyAPIKeyID == record.id {
            self.settings.primaryProxyAPIKeyID = self.settings.proxyAPIKeys.first(where: { $0.id != record.id && $0.enabled })?.id
                ?? self.settings.proxyAPIKeys.first(where: { $0.id != record.id })?.id
        }
        await self.persistProxyAPIKeySettings(successTitle: self.text(.successProxyAPIKeyUpdated), detail: record.label)
    }

    func copyProxyAPIKey(_ record: ProxyAPIKeyRecord) {
        self.copyToPasteboard(record.key, context: .copyAPIKey)
    }

    func openProxyUsageCustomRangePicker() {
        self.isProxyUsageRangePickerPresented = true
    }

    func applyProxyAPIKeyUsagePreset(_ preset: ProxyAPIKeyUsagePreset) async {
        self.proxyAPIKeyUsageFilter.preset = preset
        if preset == .custom {
            self.isProxyUsageRangePickerPresented = true
            return
        }
        await self.refreshProxyAPIKeyUsage()
    }

    func applyProxyAPIKeyUsageCustomRange() async {
        self.proxyAPIKeyUsageFilter.preset = .custom
        self.isProxyUsageRangePickerPresented = false
        await self.refreshProxyAPIKeyUsage()
    }

    func refreshProxyAPIKeyUsage() async {
        self.proxyAPIKeyUsageIsRefreshing = true
        defer { self.proxyAPIKeyUsageIsRefreshing = false }
        do {
            self.proxyAPIKeyUsageReport = try await self.admin.getProxyAPIKeyUsage(query: self.proxyAPIKeyUsageFilter.query)
        } catch {
            let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publishBanner(
                .error,
                title: self.text(.errorProxyAPIKeyUsageFailed),
                detail: self.localization.errorDetail(for: rawDetail, context: .loadAll)
            )
        }
    }

    private func proxyAPIKeyAccountEditorContext(
        allowedAccountKeys: [String],
        dataSource: ProxyDataSource
    ) -> ProxyAPIKeyAccountEditorContext {
        let normalizedAllowedAccountKeys = ProxyAPIKeyRecord.normalizedAllowedAccountKeys(allowedAccountKeys)
        let orderedAccounts = self.orderedAccountsBySelection
        let duplicateLabels = self.accountSelectionDuplicateLabels(in: orderedAccounts)
        let accountsByKey = Dictionary(uniqueKeysWithValues: orderedAccounts.map { ($0.accountKey, $0) })
        let selectableAccounts = orderedAccounts.filter { account in
            account.enabled && dataSource.allows(providerFamily: account.providerFamily)
        }
        let selectableOptions = selectableAccounts.map { account in
            ProxyAPIKeyAccountOption(
                account: account,
                title: self.accountSelectionOptionTitle(for: account, duplicateLabels: duplicateLabels),
                secondaryText: account.accountID
            )
        }
        let selectableAccountKeys = Set(selectableOptions.map(\.accountKey))
        let staleSelections = normalizedAllowedAccountKeys.compactMap { accountKey -> ProxyAPIKeyStaleSelection? in
            guard selectableAccountKeys.contains(accountKey) == false else { return nil }

            if let account = accountsByKey[accountKey] {
                let reason: String
                let isCompatible = dataSource.allows(providerFamily: account.providerFamily)
                switch (account.enabled, isCompatible) {
                case (false, false):
                    reason = self.localized(
                        zh: "该账号当前已停用，且与当前数据源不兼容",
                        en: "This account is currently disabled and incompatible with the current data source"
                    )
                case (false, true):
                    reason = self.localized(
                        zh: "该账号当前已停用",
                        en: "This account is currently disabled"
                    )
                case (true, false):
                    reason = self.localized(
                        zh: "该账号与当前数据源不兼容",
                        en: "This account is not compatible with the current data source"
                    )
                case (true, true):
                    reason = self.localized(
                        zh: "该账号已不在当前可选范围内",
                        en: "This account is no longer selectable"
                    )
                }
                return ProxyAPIKeyStaleSelection(
                    accountKey: accountKey,
                    title: self.accountSelectionOptionTitle(for: account, duplicateLabels: duplicateLabels),
                    secondaryText: account.accountID,
                    reason: reason
                )
            }

            return ProxyAPIKeyStaleSelection(
                accountKey: accountKey,
                title: accountKey,
                secondaryText: nil,
                reason: self.localized(
                    zh: "该账号已不在账号池中",
                    en: "This account is no longer in the account pool"
                )
            )
        }

        return ProxyAPIKeyAccountEditorContext(
            selectableOptions: selectableOptions,
            staleSelections: staleSelections
        )
    }

    @discardableResult
    private func persistProxyAPIKeySettings(successTitle: String, detail: String?) async -> Bool {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            self.settings = try await self.admin.saveSettings(self.settings)
            let applyOutcome = try await self.daemon.applyLaunchConfiguration(
                config: self.settings,
                preserveRunningService: true
            )
            await self.refreshLocalServiceSnapshot()
            self.proxyAPIKeyUsageReport = try await self.admin.getProxyAPIKeyUsage(query: self.proxyAPIKeyUsageFilter.query)
            if self.isProxyTestPresented {
                await self.refreshProxyTestConsole()
            }
            self.publishBanner(
                applyOutcome == .appliedNow ? .success : .warning,
                title: successTitle,
                detail: applyOutcome == .appliedNow ? detail : self.text(.warningLaunchConfigurationSavedRestartRequired)
            )
            return true
        } catch {
            let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publishBanner(
                .error,
                title: self.text(.errorProxyAPIKeyFailed),
                detail: self.localization.errorDetail(for: rawDetail, context: .saveSettings)
            )
            return false
        }
    }
}
#endif
