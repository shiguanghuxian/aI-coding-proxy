import Foundation

public enum AccountRanking {
    public static func sort(_ records: [AccountRecord]) -> [AccountRecord] {
        records.sorted(by: self.compare)
    }

    public static func compare(_ lhs: AccountRecord, _ rhs: AccountRecord) -> Bool {
        let now = Helpers.now()
        if lhs.authRefreshBlocked != rhs.authRefreshBlocked {
            return rhs.authRefreshBlocked
        }
        let lhsFree = (lhs.effectivePlanType ?? "").lowercased() == "free"
        let rhsFree = (rhs.effectivePlanType ?? "").lowercased() == "free"
        if lhsFree != rhsFree {
            return lhsFree
        }
        let lhsWeek = UsageLimitWindowSupport.effectiveRemainingPercent(for: lhs.usage?.oneWeek, now: now)
        let rhsWeek = UsageLimitWindowSupport.effectiveRemainingPercent(for: rhs.usage?.oneWeek, now: now)
        if lhsWeek != rhsWeek {
            return lhsWeek > rhsWeek
        }
        let lhsFive = UsageLimitWindowSupport.effectiveRemainingPercent(for: lhs.usage?.fiveHour, now: now)
        let rhsFive = UsageLimitWindowSupport.effectiveRemainingPercent(for: rhs.usage?.fiveHour, now: now)
        if lhsFive != rhsFive {
            return lhsFive > rhsFive
        }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
}
