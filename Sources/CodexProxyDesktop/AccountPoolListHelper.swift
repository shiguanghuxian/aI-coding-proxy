#if os(macOS)
import CodexProxyCore
import Foundation

enum AccountPoolStatusFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case enabled
    case disabled
    case current
}

enum AccountPoolPlanFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case apiKey
    case free
    case plus
    case pro
    case other
}

enum AccountPoolIssueFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case healthy
    case anyIssue
    case refreshBlocked
    case usageIssue
}

struct AccountPoolFilterState: Equatable, Sendable {
    var searchQuery = ""
    var status: AccountPoolStatusFilter = .all
    var plan: AccountPoolPlanFilter = .all
    var issue: AccountPoolIssueFilter = .all

    var isFiltering: Bool {
        self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || self.status != .all
            || self.plan != .all
            || self.issue != .all
    }
}

enum AccountPoolListHelper {
    static func visibleAccounts(from accounts: [AccountSummary], filters: AccountPoolFilterState) -> [AccountSummary] {
        accounts
            .sorted(by: self.compare)
            .filter { self.matches($0, filters: filters) }
    }

    static func compare(_ lhs: AccountSummary, _ rhs: AccountSummary) -> Bool {
        if lhs.selectionOrder != rhs.selectionOrder {
            return lhs.selectionOrder < rhs.selectionOrder
        }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    static func normalizedPlan(for account: AccountSummary) -> AccountPoolPlanFilter {
        let raw = (account.effectivePlanType ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch raw {
        case "":
            return .other
        case "api_key", "openai_api_key", "api key":
            return .apiKey
        case "free":
            return .free
        case "plus":
            return .plus
        case "pro":
            return .pro
        default:
            return .other
        }
    }

    static func hasRefreshIssue(_ account: AccountSummary) -> Bool {
        account.authRefreshBlocked
    }

    static func hasUsageIssue(_ account: AccountSummary) -> Bool {
        self.hasActiveQuotaBlock(account)
            || self.hasNonStaleUsageError(account)
            || self.normalizedText(account.authRefreshError).isEmpty == false
    }

    static func hasAnyIssue(_ account: AccountSummary) -> Bool {
        self.hasRefreshIssue(account) || self.hasUsageIssue(account)
    }

    static func quotaBlockedUntil(_ account: AccountSummary, now: Int64 = Helpers.now()) -> Int64? {
        let blockedResets = [account.usage?.fiveHour, account.usage?.oneWeek].compactMap { window -> Int64? in
            guard let window, let resetAt = window.resetAt else { return nil }
            guard window.remainingPercent <= 0, resetAt > now else { return nil }
            return resetAt
        }
        return blockedResets.max()
    }

    static func hasActiveQuotaBlock(_ account: AccountSummary, now: Int64 = Helpers.now()) -> Bool {
        self.quotaBlockedUntil(account, now: now) != nil
    }

    static func usageWindowResetAt(
        for account: AccountSummary,
        window: UsageWindow?,
        now: Int64 = Helpers.now()
    ) -> Int64? {
        guard account.authMode == .chatGPT, account.usageWindowsVisible else {
            return nil
        }
        guard let resetAt = window?.resetAt, resetAt > now else {
            return nil
        }
        return resetAt
    }

    static func hasNonStaleUsageError(_ account: AccountSummary, now: Int64 = Helpers.now()) -> Bool {
        let usageError = self.normalizedText(account.usageError)
        guard usageError.isEmpty == false else {
            return false
        }
        if usageError.lowercased().contains("usage_limit_reached"), self.hasActiveQuotaBlock(account, now: now) == false {
            return false
        }
        return true
    }

    private static func matches(_ account: AccountSummary, filters: AccountPoolFilterState) -> Bool {
        self.matchesSearch(account, query: filters.searchQuery)
            && self.matchesStatus(account, filter: filters.status)
            && self.matchesPlan(account, filter: filters.plan)
            && self.matchesIssue(account, filter: filters.issue)
    }

    static func matchesSearch(_ account: AccountSummary, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return true
        }

        let haystack = [
            account.label,
            account.email ?? "",
            account.accountID,
        ]
            .joined(separator: "\n")

        return haystack.localizedCaseInsensitiveContains(trimmed)
    }

    private static func matchesStatus(_ account: AccountSummary, filter: AccountPoolStatusFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .enabled:
            return account.enabled
        case .disabled:
            return !account.enabled
        case .current:
            return account.isCurrent
        }
    }

    private static func matchesPlan(_ account: AccountSummary, filter: AccountPoolPlanFilter) -> Bool {
        filter == .all || self.normalizedPlan(for: account) == filter
    }

    private static func matchesIssue(_ account: AccountSummary, filter: AccountPoolIssueFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .healthy:
            return self.hasAnyIssue(account) == false
        case .anyIssue:
            return self.hasAnyIssue(account)
        case .refreshBlocked:
            return self.hasRefreshIssue(account)
        case .usageIssue:
            return self.hasUsageIssue(account)
        }
    }

    private static func normalizedText(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
#endif
