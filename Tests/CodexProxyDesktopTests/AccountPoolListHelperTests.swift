#if os(macOS)
import CodexProxyCore
import XCTest
@testable import CodexProxyDesktop

final class AccountPoolListHelperTests: XCTestCase {
    func testVisibleAccountsSortBySelectionOrder() {
        let accounts = [
            self.makeAccount(label: "Zulu", updatedAt: 30, enabled: false, selectionOrder: 3, isCurrent: true),
            self.makeAccount(label: "Bravo", updatedAt: 20, enabled: true, selectionOrder: 1, isCurrent: false),
            self.makeAccount(label: "Alpha", updatedAt: 10, enabled: true, selectionOrder: 0, isCurrent: true),
            self.makeAccount(label: "Charlie", updatedAt: 20, enabled: true, selectionOrder: 2, isCurrent: false),
        ]

        let visible = AccountPoolListHelper.visibleAccounts(from: accounts, filters: AccountPoolFilterState())

        XCTAssertEqual(visible.map(\.label), ["Alpha", "Bravo", "Charlie", "Zulu"])
    }

    func testSearchMatchesLabelEmailAndAccountID() {
        let target = self.makeAccount(
            label: "OpenAI API",
            email: "dev@example.com",
            accountID: "acct-123-search"
        )
        let accounts = [target, self.makeAccount(label: "Other")]

        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(searchQuery: "openai")
            ).map(\.label),
            ["OpenAI API"]
        )
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(searchQuery: "dev@example.com")
            ).map(\.label),
            ["OpenAI API"]
        )
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(searchQuery: "123-search")
            ).map(\.label),
            ["OpenAI API"]
        )
    }

    func testPlanFiltersRecognizeNormalizedPlanTypes() {
        let accounts = [
            self.makeAccount(label: "API Key", planType: "api_key"),
            self.makeAccount(label: "Free", planType: "free"),
            self.makeAccount(label: "Plus", planType: "plus"),
            self.makeAccount(label: "Pro", planType: "pro"),
            self.makeAccount(label: "Unknown", planType: nil),
        ]

        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(plan: .apiKey)
            ).map(\.label),
            ["API Key"]
        )
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(plan: .free)
            ).map(\.label),
            ["Free"]
        )
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(plan: .other)
            ).map(\.label),
            ["Unknown"]
        )
    }

    func testPlanFiltersPreferUsagePlanTypeOverStoredPlanType() {
        let upgraded = self.makeAccount(
            label: "Upgraded OAuth",
            planType: "free",
            usage: UsageSnapshot(
                fetchedAt: Helpers.now(),
                planType: "plus",
                fiveHour: nil,
                oneWeek: nil,
                credits: nil
            )
        )

        XCTAssertEqual(AccountPoolListHelper.normalizedPlan(for: upgraded), .plus)
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: [upgraded],
                filters: AccountPoolFilterState(plan: .plus)
            ).map(\.label),
            ["Upgraded OAuth"]
        )
    }

    func testIssueFiltersSplitHealthyRefreshBlockedAndUsageIssue() {
        let accounts = [
            self.makeAccount(label: "Healthy"),
            self.makeAccount(label: "Blocked", authRefreshBlocked: true),
            self.makeAccount(label: "Usage", usageError: "quota"),
            self.makeAccount(label: "Refresh Error", authRefreshError: "refresh failed"),
        ]

        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(issue: .healthy)
            ).map(\.label),
            ["Healthy"]
        )
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(issue: .refreshBlocked)
            ).map(\.label),
            ["Blocked"]
        )
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(issue: .usageIssue)
            ).map(\.label),
            ["Refresh Error", "Usage"]
        )
        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(
                from: accounts,
                filters: AccountPoolFilterState(issue: .anyIssue)
            ).map(\.label),
            ["Blocked", "Refresh Error", "Usage"]
        )
    }

    func testIssueFiltersTreatActiveQuotaBlockAsUsageIssueButIgnoreExpiredQuotaError() {
        let activeQuotaAccount = self.makeAccount(
            label: "Quota Active",
            usage: UsageSnapshot(
                fetchedAt: Helpers.now(),
                planType: "free",
                fiveHour: nil,
                oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: Helpers.now() + 3_600),
                credits: nil
            ),
            usageError: "usage_limit_reached, plan=free, resets_at=2099-01-01 00:00:00"
        )
        let expiredQuotaAccount = self.makeAccount(
            label: "Quota Expired",
            usage: UsageSnapshot(
                fetchedAt: Helpers.now(),
                planType: "free",
                fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: Helpers.now() - 10),
                oneWeek: nil,
                credits: nil
            ),
            usageError: "usage_limit_reached, plan=free, resets_at=2026-04-14 00:00:00"
        )

        XCTAssertTrue(AccountPoolListHelper.hasUsageIssue(activeQuotaAccount))
        XCTAssertFalse(AccountPoolListHelper.hasUsageIssue(expiredQuotaAccount))
    }

    func testUsageWindowResetAtOnlyShowsFutureVisibleChatGPTWindows() {
        let now = Helpers.now()
        let futureWindow = UsageWindow(usedPercent: 42, windowSeconds: 18_000, resetAt: now + 3_600)
        let expiredWindow = UsageWindow(usedPercent: 42, windowSeconds: 18_000, resetAt: now - 10)
        let noResetWindow = UsageWindow(usedPercent: 42, windowSeconds: 18_000, resetAt: nil)
        let chatGPTAccount = self.makeAccount(label: "ChatGPT")
        let hiddenChatGPTAccount = self.makeAccount(label: "Hidden", usageWindowsVisible: false)
        let apiKeyAccount = self.makeAccount(label: "API Key", authMode: .openAIAPIKey)

        XCTAssertEqual(
            AccountPoolListHelper.usageWindowResetAt(for: chatGPTAccount, window: futureWindow, now: now),
            now + 3_600
        )
        XCTAssertNil(AccountPoolListHelper.usageWindowResetAt(for: chatGPTAccount, window: expiredWindow, now: now))
        XCTAssertNil(AccountPoolListHelper.usageWindowResetAt(for: chatGPTAccount, window: noResetWindow, now: now))
        XCTAssertNil(AccountPoolListHelper.usageWindowResetAt(for: hiddenChatGPTAccount, window: futureWindow, now: now))
        XCTAssertNil(AccountPoolListHelper.usageWindowResetAt(for: apiKeyAccount, window: futureWindow, now: now))
    }

    func testExhaustedFutureWindowStillUsesQuotaBlockedUntil() {
        let now = Helpers.now()
        let resetAt = now + 3_600
        let account = self.makeAccount(
            label: "Quota Active",
            usage: UsageSnapshot(
                fetchedAt: now,
                planType: "free",
                fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: resetAt),
                oneWeek: nil,
                credits: nil
            )
        )

        XCTAssertEqual(AccountPoolListHelper.quotaBlockedUntil(account, now: now), resetAt)
        XCTAssertTrue(AccountPoolListHelper.hasActiveQuotaBlock(account, now: now))
    }

    func testCombinedFiltersNarrowResults() {
        let accounts = [
            self.makeAccount(label: "API Enabled", planType: "api_key", updatedAt: 20, enabled: true),
            self.makeAccount(label: "Free Disabled", planType: "free", updatedAt: 50, enabled: false),
            self.makeAccount(label: "Plus Enabled", planType: "plus", updatedAt: 10, enabled: true, usageError: "quota"),
        ]

        let filters = AccountPoolFilterState(
            searchQuery: "enabled",
            status: .enabled,
            plan: .apiKey,
            issue: .healthy
        )

        XCTAssertEqual(
            AccountPoolListHelper.visibleAccounts(from: accounts, filters: filters).map(\.label),
            ["API Enabled"]
        )
    }

    private func makeAccount(
        label: String,
        email: String? = nil,
        accountID: String = UUID().uuidString,
        planType: String? = "free",
        updatedAt: Int64 = 10,
        enabled: Bool = true,
        selectionOrder: Int64 = 0,
        authMode: AccountAuthMode = .chatGPT,
        usage: UsageSnapshot? = nil,
        usageWindowsVisible: Bool = true,
        usageError: String? = nil,
        authRefreshBlocked: Bool = false,
        authRefreshError: String? = nil,
        isCurrent: Bool = false
    ) -> AccountSummary {
        AccountSummary(
            id: UUID().uuidString,
            label: label,
            email: email,
            accountKey: "principal|\(accountID)",
            accountID: accountID,
            planType: planType,
            authMode: authMode,
            addedAt: 1,
            updatedAt: updatedAt,
            enabled: enabled,
            selectionOrder: selectionOrder,
            usage: usage,
            usageWindowsVisible: usageWindowsVisible,
            usageError: usageError,
            authRefreshBlocked: authRefreshBlocked,
            authRefreshError: authRefreshError,
            isCurrent: isCurrent
        )
    }
}
#endif
