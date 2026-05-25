#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation

enum ReasoningCacheOlderThanPreset: Int64, CaseIterable, Identifiable {
    case oneDay = 86_400
    case sevenDays = 604_800
    case thirtyDays = 2_592_000

    var id: Int64 { self.rawValue }
}

@MainActor
extension DesktopAppModel {
    var reasoningCacheHasEntries: Bool {
        self.reasoningCacheSummary.totalCount > 0
    }

    var reasoningCacheSelectedAccountCanClear: Bool {
        self.reasoningCacheSelectedAccountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var reasoningCacheAccountOptions: [ReasoningCacheAccountSummary] {
        self.reasoningCacheSummary.accounts
            .filter { $0.entryCount > 0 }
            .sorted {
                if $0.accountLabel.localizedCaseInsensitiveCompare($1.accountLabel) == .orderedSame {
                    return $0.accountKey < $1.accountKey
                }
                return $0.accountLabel.localizedCaseInsensitiveCompare($1.accountLabel) == .orderedAscending
            }
    }

    func loadReasoningCacheSummary() async {
        self.reasoningCacheIsRefreshing = true
        defer { self.reasoningCacheIsRefreshing = false }
        do {
            self.reasoningCacheSummary = try await self.admin.getReasoningCacheSummary()
            self.normalizeReasoningCacheSelection()
        } catch {
            self.present(error: error, context: .loadReasoningCache)
        }
    }

    func clearExpiredReasoningCache() async {
        await self.clearReasoningCache(
            request: ClearReasoningCacheRequest(expiredOnly: true),
            title: self.text(.confirmClearReasoningCacheExpiredTitle),
            message: self.text(.confirmClearReasoningCacheExpiredMessage)
        )
    }

    func clearSelectedAccountReasoningCache() async {
        let accountKey = self.reasoningCacheSelectedAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountKey.isEmpty else {
            self.publishBanner(.warning, title: self.text(.errorReasoningCacheClearFailed), detail: self.text(.helperReasoningCacheSelectAccount))
            return
        }
        let label = self.reasoningCacheAccountOptions.first { $0.accountKey == accountKey }?.accountLabel ?? accountKey
        await self.clearReasoningCache(
            request: ClearReasoningCacheRequest(accountKeys: [accountKey]),
            title: self.text(.confirmClearReasoningCacheAccountTitle),
            message: self.localized(
                zh: "将清理账号“\(label)”的 reasoning 回传缓存。缓存正文不会展示，清理后该账号重启后的历史回填能力会丢失。",
                en: "This clears the reasoning backfill cache for “\(label)”. The cached content is not displayed; after clearing, that account loses restart recovery for prior history."
            )
        )
    }

    func clearReasoningCacheOlderThanSelectedPreset() async {
        let seconds = max(1, self.reasoningCacheOlderThanSeconds)
        await self.clearReasoningCache(
            request: ClearReasoningCacheRequest(olderThanSeconds: seconds),
            title: self.text(.confirmClearReasoningCacheOlderThanTitle),
            message: self.localized(
                zh: "将清理最后使用时间早于 \(self.reasoningCacheOlderThanLabel(seconds)) 的 reasoning 回传缓存。",
                en: "This clears reasoning backfill cache entries last used more than \(self.reasoningCacheOlderThanLabel(seconds)) ago."
            )
        )
    }

    func clearAllReasoningCache() async {
        await self.clearReasoningCache(
            request: ClearReasoningCacheRequest(clearAll: true),
            title: self.text(.confirmClearReasoningCacheAllTitle),
            message: self.text(.confirmClearReasoningCacheAllMessage)
        )
    }

    func reasoningCacheTimestampText(_ timestamp: Int64?) -> String {
        guard let timestamp else { return self.text(.statusNoData) }
        return DesktopDateTimeFormat.string(fromUnixSeconds: timestamp)
    }

    func reasoningCacheOlderThanLabel(_ seconds: Int64) -> String {
        switch seconds {
        case ReasoningCacheOlderThanPreset.oneDay.rawValue:
            return self.localized(zh: "1 天", en: "1 day")
        case ReasoningCacheOlderThanPreset.sevenDays.rawValue:
            return self.localized(zh: "7 天", en: "7 days")
        case ReasoningCacheOlderThanPreset.thirtyDays.rawValue:
            return self.localized(zh: "30 天", en: "30 days")
        default:
            return self.localized(zh: "\(seconds / 86_400) 天", en: "\(seconds / 86_400) days")
        }
    }

    private func clearReasoningCache(
        request: ClearReasoningCacheRequest,
        title: String,
        message: String
    ) async {
        guard self.reasoningCacheHasEntries || request.expiredOnly else { return }
        let confirmation = ReasoningCacheClearConfirmationContent(
            title: title,
            informativeText: message,
            actionTitle: self.text(.actionClearReasoningCacheConfirm)
        )
        guard self.confirmClearReasoningCache(confirmation) else { return }

        self.reasoningCacheIsClearing = true
        defer { self.reasoningCacheIsClearing = false }
        do {
            let result = try await self.admin.clearReasoningCache(request)
            self.reasoningCacheSummary = result.summary
            self.normalizeReasoningCacheSelection()
            self.publishBanner(
                .success,
                title: self.text(.successReasoningCacheCleared),
                detail: self.localized(zh: "已清理 \(result.deletedCount) 条缓存。", en: "Cleared \(result.deletedCount) cache entries.")
            )
        } catch {
            self.present(error: error, context: .clearReasoningCache)
        }
    }

    private func normalizeReasoningCacheSelection() {
        let options = self.reasoningCacheAccountOptions
        guard options.contains(where: { $0.accountKey == self.reasoningCacheSelectedAccountKey }) == false else {
            return
        }
        self.reasoningCacheSelectedAccountKey = options.first?.accountKey ?? ""
    }

    private func confirmClearReasoningCache(_ content: ReasoningCacheClearConfirmationContent) -> Bool {
        if let confirmClearReasoningCacheHandler {
            return confirmClearReasoningCacheHandler(content)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    var ocrCacheHasEntries: Bool {
        self.ocrCacheSummary.totalCount > 0
    }

    func loadOCRCacheSummary() async {
        self.ocrCacheIsRefreshing = true
        defer { self.ocrCacheIsRefreshing = false }
        do {
            self.ocrCacheSummary = try await self.admin.getOCRCacheSummary()
        } catch {
            self.present(error: error, context: .loadOCRCache)
        }
    }

    func clearExpiredOCRCache() async {
        await self.clearOCRCache(
            request: ClearOCRCacheRequest(expiredOnly: true),
            title: self.text(.confirmClearOCRCacheExpiredTitle),
            message: self.text(.confirmClearOCRCacheExpiredMessage)
        )
    }

    func clearOCRCacheOlderThanSelectedPreset() async {
        let seconds = max(1, self.ocrCacheOlderThanSeconds)
        await self.clearOCRCache(
            request: ClearOCRCacheRequest(olderThanSeconds: seconds),
            title: self.text(.confirmClearOCRCacheOlderThanTitle),
            message: self.localized(
                zh: "将清理最后使用时间早于 \(self.reasoningCacheOlderThanLabel(seconds)) 的 OCR 结果缓存。",
                en: "This clears OCR result cache entries last used more than \(self.reasoningCacheOlderThanLabel(seconds)) ago."
            )
        )
    }

    func clearAllOCRCache() async {
        await self.clearOCRCache(
            request: ClearOCRCacheRequest(clearAll: true),
            title: self.text(.confirmClearOCRCacheAllTitle),
            message: self.text(.confirmClearOCRCacheAllMessage)
        )
    }

    func ocrCacheTimestampText(_ timestamp: Int64?) -> String {
        self.reasoningCacheTimestampText(timestamp)
    }

    private func clearOCRCache(
        request: ClearOCRCacheRequest,
        title: String,
        message: String
    ) async {
        guard self.ocrCacheHasEntries || request.expiredOnly else { return }
        let confirmation = OCRCacheClearConfirmationContent(
            title: title,
            informativeText: message,
            actionTitle: self.text(.actionClearOCRCacheConfirm)
        )
        guard self.confirmClearOCRCache(confirmation) else { return }

        self.ocrCacheIsClearing = true
        defer { self.ocrCacheIsClearing = false }
        do {
            let result = try await self.admin.clearOCRCache(request)
            self.ocrCacheSummary = result.summary
            self.publishBanner(
                .success,
                title: self.text(.successOCRCacheCleared),
                detail: self.localized(zh: "已清理 \(result.deletedCount) 条 OCR 缓存。", en: "Cleared \(result.deletedCount) OCR cache entries.")
            )
        } catch {
            self.present(error: error, context: .clearOCRCache)
        }
    }

    private func confirmClearOCRCache(_ content: OCRCacheClearConfirmationContent) -> Bool {
        if let confirmClearOCRCacheHandler {
            return confirmClearOCRCacheHandler(content)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
