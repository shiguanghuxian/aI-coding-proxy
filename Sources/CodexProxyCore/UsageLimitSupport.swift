import Foundation

struct UsageLimitReachedSignal: Error, LocalizedError, Sendable, Equatable {
    let type: String
    let message: String
    let planType: String?
    let resetsAt: Int64

    var errorDescription: String? {
        self.normalizedUsageError
    }

    var normalizedUsageError: String {
        var components = ["usage_limit_reached"]
        if let planType = self.planType?.trimmingCharacters(in: .whitespacesAndNewlines), !planType.isEmpty {
            components.append("plan=\(planType)")
        }
        components.append("resets_at=\(FixedDisplayDateTimeFormat.string(fromUnixSeconds: self.resetsAt))")
        return components.joined(separator: ", ")
    }

    static func parse(from bodyText: String) -> UsageLimitReachedSignal? {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let data = trimmed.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return self.parse(jsonObject: object)
    }

    private static func parse(jsonObject: Any) -> UsageLimitReachedSignal? {
        guard let object = jsonObject as? [String: Any] else { return nil }
        let payload = (object["error"] as? [String: Any]) ?? object
        guard
            let type = (payload["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            type.lowercased() == "usage_limit_reached",
            let resetsAt = self.int64Value(payload["resets_at"]) ?? self.int64Value(object["resets_at"])
        else {
            return nil
        }

        return UsageLimitReachedSignal(
            type: type,
            message: (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "The usage limit has been reached",
            planType: (payload["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (object["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            resetsAt: resetsAt
        )
    }

    private static func int64Value(_ rawValue: Any?) -> Int64? {
        switch rawValue {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(value.rounded())
        case let value as String:
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

enum UsageLimitWindowKind: Sendable, Equatable {
    case fiveHour
    case oneWeek
}

enum UsageLimitWindowSupport {
    private static let matchToleranceSeconds: Int64 = 7_200
    private static let fiveHourWindowSeconds = 18_000
    private static let oneWeekWindowSeconds = 604_800

    static func usageByApplyingLimit(
        _ signal: UsageLimitReachedSignal,
        to usage: UsageSnapshot?,
        fallbackPlanType: String?,
        now: Int64 = Helpers.now()
    ) -> UsageSnapshot {
        var snapshot = usage ?? UsageSnapshot(
            fetchedAt: now,
            planType: signal.planType ?? fallbackPlanType,
            fiveHour: nil,
            oneWeek: nil,
            credits: nil
        )
        snapshot.fetchedAt = now
        snapshot.planType = signal.planType ?? snapshot.planType ?? fallbackPlanType

        switch self.resolveWindowKind(in: snapshot, resetsAt: signal.resetsAt, now: now) {
        case .fiveHour:
            snapshot.fiveHour = self.exhaustedWindow(
                from: snapshot.fiveHour,
                defaultWindowSeconds: self.fiveHourWindowSeconds,
                resetsAt: signal.resetsAt
            )
        case .oneWeek:
            snapshot.oneWeek = self.exhaustedWindow(
                from: snapshot.oneWeek,
                defaultWindowSeconds: self.oneWeekWindowSeconds,
                resetsAt: signal.resetsAt
            )
        }

        return snapshot
    }

    static func blockedUntil(in usage: UsageSnapshot?, now: Int64 = Helpers.now()) -> Int64? {
        let blockedResets = [usage?.fiveHour, usage?.oneWeek].compactMap { window -> Int64? in
            guard let window, self.isBlocked(window, now: now), let resetAt = window.resetAt else {
                return nil
            }
            return resetAt
        }
        return blockedResets.max()
    }

    static func isBlocked(_ usage: UsageSnapshot?, now: Int64 = Helpers.now()) -> Bool {
        self.blockedUntil(in: usage, now: now) != nil
    }

    static func effectiveRemainingPercent(for window: UsageWindow?, now: Int64 = Helpers.now()) -> Int {
        guard let window else { return -1 }
        if self.isBlocked(window, now: now) {
            return -1
        }
        if let resetAt = window.resetAt, window.remainingPercent <= 0, resetAt <= now {
            return 100
        }
        return window.remainingPercent
    }

    private static func resolveWindowKind(
        in usage: UsageSnapshot?,
        resetsAt: Int64,
        now: Int64
    ) -> UsageLimitWindowKind {
        let matchingWindow = [
            (UsageLimitWindowKind.fiveHour, usage?.fiveHour),
            (UsageLimitWindowKind.oneWeek, usage?.oneWeek),
        ]
        .compactMap { kind, window -> (UsageLimitWindowKind, Int64)? in
            guard let window, let existingResetAt = window.resetAt else { return nil }
            let delta = abs(existingResetAt - resetsAt)
            guard delta <= self.matchToleranceSeconds else { return nil }
            return (kind, delta)
        }
        .min { $0.1 < $1.1 }

        if let matchingWindow {
            return matchingWindow.0
        }

        let remainingSeconds = max(0, resetsAt - now)
        let fiveHourDelta = abs(remainingSeconds - Int64(self.fiveHourWindowSeconds))
        let oneWeekDelta = abs(remainingSeconds - Int64(self.oneWeekWindowSeconds))
        return fiveHourDelta <= oneWeekDelta ? .fiveHour : .oneWeek
    }

    private static func exhaustedWindow(
        from existing: UsageWindow?,
        defaultWindowSeconds: Int,
        resetsAt: Int64
    ) -> UsageWindow {
        UsageWindow(
            usedPercent: 100,
            windowSeconds: existing?.windowSeconds ?? defaultWindowSeconds,
            resetAt: resetsAt
        )
    }

    private static func isBlocked(_ window: UsageWindow, now: Int64) -> Bool {
        guard let resetAt = window.resetAt else { return false }
        return window.remainingPercent <= 0 && resetAt > now
    }
}
