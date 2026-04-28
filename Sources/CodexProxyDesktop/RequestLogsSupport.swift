#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct RequestLogFilterState: Equatable, Sendable {
    var timePreset: RequestLogTimePreset
    var fromDate: Date
    var toDate: Date
    var selectedAPIKey: String
    var selectedAccountKey: String
    var selectedClientSource: RequestLogClientSource?
    var selectedModel: String
    var sortBy: RequestLogSortField
    var sortDirection: RequestLogSortDirection
    var page: Int
    var pageSize: Int

    init(
        timePreset: RequestLogTimePreset = .last24Hours,
        fromDate: Date = Date().addingTimeInterval(-86_400),
        toDate: Date = Date(),
        selectedAPIKey: String = "",
        selectedAccountKey: String = "",
        selectedClientSource: RequestLogClientSource? = nil,
        selectedModel: String = "",
        sortBy: RequestLogSortField = .time,
        sortDirection: RequestLogSortDirection = .descending,
        page: Int = 1,
        pageSize: Int = 50
    ) {
        self.timePreset = timePreset
        self.fromDate = fromDate
        self.toDate = toDate
        self.selectedAPIKey = selectedAPIKey
        self.selectedAccountKey = selectedAccountKey
        self.selectedClientSource = selectedClientSource
        self.selectedModel = selectedModel
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.page = page
        self.pageSize = pageSize
    }

    static func defaultState(now: Date = Date()) -> RequestLogFilterState {
        RequestLogFilterState(
            timePreset: .last24Hours,
            fromDate: now.addingTimeInterval(-86_400),
            toDate: now,
            selectedAPIKey: "",
            selectedAccountKey: "",
            selectedModel: "",
            sortBy: .time,
            sortDirection: .descending,
            page: 1,
            pageSize: 50
        )
    }

    var query: RequestLogQuery {
        RequestLogQuery(
            timePreset: self.timePreset,
            from: self.timePreset == .custom ? Int64(self.fromDate.timeIntervalSince1970) : nil,
            to: self.timePreset == .custom ? Int64(self.toDate.timeIntervalSince1970) : nil,
            apiKey: self.selectedAPIKey.isEmpty ? nil : self.selectedAPIKey,
            accountKey: self.selectedAccountKey.isEmpty ? nil : self.selectedAccountKey,
            clientSource: self.selectedClientSource,
            model: self.selectedModel.isEmpty ? nil : self.selectedModel,
            sortBy: self.sortBy,
            sortDirection: self.sortDirection,
            page: self.page,
            pageSize: self.pageSize
        )
    }

    func hasSameFilters(as other: RequestLogFilterState) -> Bool {
        let datesMatch: Bool
        if self.timePreset == .custom {
            datesMatch = self.fromDate == other.fromDate && self.toDate == other.toDate
        } else {
            datesMatch = true
        }

        return self.timePreset == other.timePreset
            && datesMatch
            && self.selectedAPIKey == other.selectedAPIKey
            && self.selectedAccountKey == other.selectedAccountKey
            && self.selectedClientSource == other.selectedClientSource
            && self.selectedModel == other.selectedModel
            && self.sortBy == other.sortBy
            && self.sortDirection == other.sortDirection
            && self.pageSize == other.pageSize
    }

    func withPage(_ page: Int) -> RequestLogFilterState {
        var copy = self
        copy.page = page
        return copy
    }
}

struct RequestLogAccountOption: Identifiable, Equatable, Sendable {
    var accountKey: String
    var title: String

    var id: String { self.accountKey }
}

enum RequestLogErrorSummaryCopySupport {
    static func copyValue(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        guard rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return rawValue
    }
}

@MainActor
extension DesktopAppModel {
    var requestLogsHasMorePages: Bool {
        Int64(self.requestLogPage.page * self.requestLogPage.pageSize) < self.requestLogPage.totalCount
    }

    var requestLogsHasPreviousPage: Bool {
        self.requestLogPage.page > 1
    }

    var requestLogsStatusText: String {
        if self.requestLogsIsRefreshing {
            return self.text(.statusLoadingLogs)
        }
        return self.requestLogPage.entries.isEmpty ? self.text(.statusNoData) : self.text(.statusReady)
    }

    var requestLogsStatusTone: StatusPill.Tone {
        if self.requestLogsIsRefreshing {
            return .accent
        }
        return self.requestLogPage.entries.isEmpty ? .neutral : .success
    }

    var requestLogsSummaryText: String {
        self.localization.requestLogsSummaryText(
            totalCount: self.requestLogPage.totalCount,
            page: self.requestLogPage.page,
            pageSize: self.requestLogPage.pageSize,
            hasMore: self.requestLogsHasMorePages
        )
    }

    var requestLogsLastRefreshedText: String {
        guard let requestLogsLastRefreshedAt else {
            return self.text(.statusNoData)
        }
        return DesktopDateTimeFormat.string(from: requestLogsLastRefreshedAt)
    }

    var requestLogsAPIKeyOptions: [String] {
        self.pickerOptions(
            base: self.requestLogFilterOptions.availableAPIKeys,
            selected: self.requestLogsDraftFilterState.selectedAPIKey
        )
    }

    var requestLogsAccountOptions: [RequestLogAccountOption] {
        let sortedAccounts = self.orderedAccountsBySelection
        let duplicateLabels = self.accountSelectionDuplicateLabels(in: sortedAccounts)
        var options = sortedAccounts.map { account in
            RequestLogAccountOption(
                accountKey: account.accountKey,
                title: self.accountSelectionOptionTitle(for: account, duplicateLabels: duplicateLabels)
            )
        }

        let selectedAccountKey = self.requestLogsDraftFilterState.selectedAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedAccountKey.isEmpty, options.contains(where: { $0.accountKey == selectedAccountKey }) == false {
            options.insert(self.missingRequestLogsAccountOption(accountKey: selectedAccountKey), at: 0)
        }

        return options
    }

    var requestLogsModelOptions: [String] {
        self.pickerOptions(
            base: self.requestLogFilterOptions.availableModels,
            selected: self.requestLogsDraftFilterState.selectedModel
        )
    }

    var requestLogsHasPendingFilterChanges: Bool {
        self.requestLogsDraftFilterState.hasSameFilters(as: self.requestLogsAppliedFilterState) == false
    }

    var requestLogsCanExport: Bool {
        self.requestLogsIsExporting == false && self.requestLogsIsRefreshing == false
    }

    func label(for preset: RequestLogTimePreset) -> String {
        self.localization.label(for: preset)
    }

    func label(for sortField: RequestLogSortField) -> String {
        self.localization.label(for: sortField)
    }

    func label(for sortDirection: RequestLogSortDirection) -> String {
        self.localization.label(for: sortDirection)
    }

    func requestLogStatusText(_ entry: RequestLogEntry) -> String {
        entry.success ? self.text(.statusSuccess) : self.text(.statusFailed)
    }

    func requestLogStatusTone(_ entry: RequestLogEntry) -> StatusPill.Tone {
        entry.success ? .success : .danger
    }

    func requestLogTimeText(_ timestamp: Int64) -> String {
        DesktopDateTimeFormat.string(fromUnixSeconds: timestamp)
    }

    func requestLogLatencyText(_ latencyMS: Int64) -> String {
        self.localization.requestLogsLatencyText(latencyMS)
    }

    func requestLogClientSourceText(_ source: RequestLogClientSource) -> String {
        switch source {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        case .gemini:
            return "Gemini"
        case .other:
            return self.localized(zh: "其它", en: "Other")
        }
    }

    func requestLogTokenText(_ value: Int64) -> String {
        Self.requestLogsNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func requestLogCacheHitText(_ value: Int64?) -> String {
        guard let value else { return self.text(.statusNotApplicable) }
        return self.requestLogTokenText(value)
    }

    func requestLogMaskedAPIKeyText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.text(.statusNoData) }
        return RequestLogPresentation.maskedAPIKey(trimmed)
    }

    func requestLogTokenSummary(_ entry: RequestLogEntry) -> LocalizationStore.RequestLogTokenSummaryLines {
        self.localization.requestLogsTokenSummaryLines(
            inputTokens: self.requestLogTokenText(entry.inputTokens),
            outputTokens: self.requestLogTokenText(entry.outputTokens),
            totalTokens: self.requestLogTokenText(entry.totalTokens),
            cacheHitTokens: self.requestLogCacheHitText(entry.cacheHitTokens)
        )
    }

    func openRequestLogsWindow() {
        let shouldStartNewSession = self.isRequestLogsPresented == false
        if shouldStartNewSession {
            self.resetRequestLogsSessionState(now: self.requestLogsNowProvider())
        }
        if self.requestLogsWindowController == nil {
            self.requestLogsWindowController = RequestLogsWindowController(model: self)
        }
        self.isRequestLogsPresented = true
        self.requestLogsWindowController?.showWindow()
        if shouldStartNewSession {
            self.applyRequestLogsFiltersAndRefresh()
        }
    }

    func dismissRequestLogsWindow() {
        self.requestLogsWindowController?.closeWindow()
    }

    func handleRequestLogsWindowDidClose() {
        self.isRequestLogsPresented = false
        self.requestLogsRefreshGeneration += 1
        self.requestLogsRefreshTask?.cancel()
        self.requestLogsRefreshTask = nil
        self.requestLogsIsRefreshing = false
    }

    func resetRequestLogsSessionState(now: Date = Date()) {
        let state = RequestLogFilterState.defaultState(now: now)
        self.requestLogsDraftFilterState = state
        self.requestLogsAppliedFilterState = state
        self.requestLogPage = RequestLogPage()
        self.requestLogFilterOptions = RequestLogFilterOptions()
        self.requestLogsLastRefreshedAt = nil
        self.clearRequestLogsBanner()
    }

    func clearRequestLogsBanner() {
        withAnimation(.easeInOut(duration: 0.18)) {
            self.requestLogsBanners.removeAll()
        }
    }

    func dismissRequestLogsBanner(id: BannerState.ID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            self.requestLogsBanners.removeAll { $0.id == id }
        }
    }

    func copyRequestLogErrorSummary(_ value: String) {
        self.copyRequestLogValue(
            RequestLogErrorSummaryCopySupport.copyValue(from: value),
            successTitle: self.text(.successCopiedErrorSummary)
        )
    }

    func scheduleRequestLogsRefresh() {
        self.requestLogsRefreshGeneration += 1
        let generation = self.requestLogsRefreshGeneration
        self.requestLogsRefreshTask?.cancel()
        self.requestLogsRefreshTask = Task { [weak self] in
            await self?.refreshRequestLogs(generation: generation)
        }
    }

    func applyRequestLogsFiltersAndRefresh() {
        self.requestLogsAppliedFilterState = self.requestLogsDraftFilterState.withPage(1)
        self.scheduleRequestLogsRefresh()
    }

    private func refreshRequestLogs(generation: UInt64) async {
        let query = self.requestLogsAppliedFilterState.query
        self.requestLogsIsRefreshing = true
        defer { self.finishRequestLogsRefresh(generation: generation) }

        do {
            let page = try await self.admin.getRequestLogs(query: query)
            try Task.checkCancellation()
            guard self.requestLogsRefreshGeneration == generation else { return }
            self.requestLogPage = page
            self.requestLogFilterOptions = self.normalizedFilterOptions(
                RequestLogFilterOptions(
                    availableAPIKeys: page.availableAPIKeys,
                    availableModels: page.availableModels
                )
            )
            self.requestLogsLastRefreshedAt = Date()
            self.clearRequestLogsBanner()
        } catch is CancellationError {
            return
        } catch {
            guard self.requestLogsRefreshGeneration == generation else { return }
            self.presentRequestLogsError(error)
        }
    }

    func setRequestLogsTimePreset(_ preset: RequestLogTimePreset) {
        guard self.requestLogsDraftFilterState.timePreset != preset else { return }
        self.requestLogsDraftFilterState.timePreset = preset
        if preset != .custom {
            self.requestLogsDraftFilterState.toDate = Date()
        }
    }

    func setRequestLogsFromDate(_ date: Date) {
        self.requestLogsDraftFilterState.fromDate = date
    }

    func setRequestLogsToDate(_ date: Date) {
        self.requestLogsDraftFilterState.toDate = date
    }

    func setRequestLogsAPIKey(_ value: String) {
        self.requestLogsDraftFilterState.selectedAPIKey = value
    }

    func setRequestLogsAccountKey(_ value: String) {
        self.requestLogsDraftFilterState.selectedAccountKey = value
    }

    func setRequestLogsClientSource(_ value: RequestLogClientSource?) {
        self.requestLogsDraftFilterState.selectedClientSource = value
    }

    func setRequestLogsModel(_ value: String) {
        self.requestLogsDraftFilterState.selectedModel = value
    }

    func setRequestLogsSortField(_ value: RequestLogSortField) {
        self.requestLogsDraftFilterState.sortBy = value
    }

    func setRequestLogsSortDirection(_ value: RequestLogSortDirection) {
        self.requestLogsDraftFilterState.sortDirection = value
    }

    func toggleRequestLogsSortDirection() {
        self.requestLogsDraftFilterState.sortDirection = self.requestLogsDraftFilterState.sortDirection == .ascending
            ? .descending
            : .ascending
    }

    func previousRequestLogsPage() {
        guard self.requestLogsHasPreviousPage else { return }
        self.requestLogsAppliedFilterState.page -= 1
        self.scheduleRequestLogsRefresh()
    }

    func nextRequestLogsPage() {
        guard self.requestLogsHasMorePages else { return }
        self.requestLogsAppliedFilterState.page += 1
        self.scheduleRequestLogsRefresh()
    }

    func exportRequestLogs() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = self.requestLogsExportFilename()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        self.requestLogsIsExporting = true
        defer { self.requestLogsIsExporting = false }

        do {
            let data = try await self.admin.exportRequestLogs(query: self.requestLogsAppliedFilterState.query)
            try data.write(to: url, options: .atomic)
            self.publishRequestLogsBanner(
                .success,
                title: self.text(.successRequestLogsExported),
                detail: url.lastPathComponent
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publishRequestLogsBanner(
                .error,
                title: self.text(.errorRequestLogsExportFailed),
                detail: detail.isEmpty ? nil : detail
            )
        }
    }

    func copyRequestLogValue(_ rawValue: String?, successTitle: String) {
        let original = rawValue ?? ""
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.publishRequestLogsBanner(
                .warning,
                title: self.text(.errorCopyFailed),
                detail: self.text(.statusNoData)
            )
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(original, forType: .string) {
            self.publishRequestLogsBanner(.success, title: successTitle, detail: nil)
        } else {
            self.publishRequestLogsBanner(.error, title: self.text(.errorCopyFailed), detail: nil)
        }
    }

    func copyRequestLogRowCSV(_ entry: RequestLogEntry) {
        self.copyRequestLogValue(
            RequestLogCSVExport.rowString(entry, maskAPIKeys: true),
            successTitle: self.text(.successCopiedRowCSV)
        )
    }

    private func presentRequestLogsError(_ error: Error) {
        let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publishRequestLogsBanner(
            .error,
            title: self.localization.errorTitle(for: rawDetail, context: .loadRequestLogs),
            detail: self.localization.errorDetail(for: rawDetail, context: .loadRequestLogs)
        )
    }

    func publishRequestLogsBanner(
        _ tone: BannerState.Tone,
        title: String,
        detail: String?
    ) {
        let state = BannerState(tone: tone, title: title, detail: detail)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            self.requestLogsBanners.insert(state, at: 0)
        }
        guard tone != .error else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.toastAutoDismissDuration ?? .seconds(3.5))
            guard self?.requestLogsBanners.contains(where: { $0.id == state.id }) == true else { return }
            self?.dismissRequestLogsBanner(id: state.id)
        }
    }

    private func normalizedFilterOptions(_ options: RequestLogFilterOptions) -> RequestLogFilterOptions {
        RequestLogFilterOptions(
            availableAPIKeys: self.pickerOptions(
                base: options.availableAPIKeys,
                selected: self.requestLogsDraftFilterState.selectedAPIKey
            ),
            availableModels: self.pickerOptions(
                base: options.availableModels,
                selected: self.requestLogsDraftFilterState.selectedModel
            )
        )
    }

    private func pickerOptions(base: [String], selected: String) -> [String] {
        var options = base
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, options.contains(trimmed) == false {
            options.insert(trimmed, at: 0)
        }
        return options
    }

    private func missingRequestLogsAccountOption(accountKey: String) -> RequestLogAccountOption {
        if let matchingEntry = self.requestLogPage.entries.first(where: { $0.accountKey == accountKey }) {
            let label = matchingEntry.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                return RequestLogAccountOption(
                    accountKey: accountKey,
                    title: "\(label) · \(accountKey)"
                )
            }
        }

        return RequestLogAccountOption(accountKey: accountKey, title: accountKey)
    }

    private func finishRequestLogsRefresh(generation: UInt64) {
        guard self.requestLogsRefreshGeneration == generation else { return }
        self.requestLogsIsRefreshing = false
        self.requestLogsRefreshTask = nil
    }

    private func requestLogsExportFilename() -> String {
        let appliedQuery = self.requestLogsAppliedFilterState.query
        let bounds = appliedQuery.effectiveTimeBounds(now: Helpers.now())
        let exportTime = DesktopDateTimeFormat.string(from: Date())
        let fromText = DesktopDateTimeFormat.string(fromUnixSeconds: bounds.from)
        let toText = DesktopDateTimeFormat.string(fromUnixSeconds: bounds.to)
        return "request-logs-\(self.sanitizeFilenameDate(fromText))_to_\(self.sanitizeFilenameDate(toText))_exported_\(self.sanitizeFilenameDate(exportTime)).csv"
    }

    private func sanitizeFilenameDate(_ value: String) -> String {
        value
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static let requestLogsNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
#endif
