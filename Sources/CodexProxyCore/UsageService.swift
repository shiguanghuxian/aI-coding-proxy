import Foundation

public enum UsageService {
    public static func fetchUsageSnapshot(
        accessToken: String,
        accountID: String,
        config: AppConfig
    ) async throws -> UsageSnapshot {
        let candidates = self.resolveUsageURLs(config: config)
        var errors: [String] = []
        for url in candidates {
            do {
                let response = try await HTTPClientFactory.request(
                    config: config,
                    url: url,
                    headers: [
                        "Authorization": "Bearer \(accessToken)",
                        "ChatGPT-Account-Id": accountID,
                        "Accept": "application/json",
                    ]
                )
                guard (200..<300).contains(response.statusCode) else {
                    if let usageLimit = UsageLimitReachedSignal.parse(from: response.bodyText) {
                        throw usageLimit
                    }
                    errors.append("\(url) -> \(response.statusCode): \(Helpers.truncate(response.bodyText))")
                    continue
                }
                let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
                return self.mapUsagePayload(payload)
            } catch let error as UsageLimitReachedSignal {
                throw error
            } catch {
                errors.append("\(url) -> \(error.localizedDescription)")
            }
        }
        throw ProxyError.message(errors.prefix(2).joined(separator: " | "))
    }

    public static func resolveUsageURLs(config: AppConfig) -> [String] {
        let base = config.chatGPTBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let backendBase = base.hasSuffix("/backend-api") ? base : base + "/backend-api"
        let urls = [
            backendBase + "/wham/usage",
            base + "/wham/usage",
            base + "/api/codex/usage",
            "https://chatgpt.com/backend-api/wham/usage",
            "https://chatgpt.com/api/codex/usage",
        ]
        var deduped: [String] = []
        for item in urls where !deduped.contains(item) {
            deduped.append(item)
        }
        return deduped
    }

    private static func mapUsagePayload(_ payload: [String: Any]) -> UsageSnapshot {
        var windows: [(usedPercent: Double, windowSeconds: Int, resetAt: Int64?)] = []
        let directRateLimit = payload["rate_limit"] as? [String: Any]
        windows.append(contentsOf: self.extractWindows(from: directRateLimit))
        if let additional = payload["additional_rate_limits"] as? [[String: Any]] {
            for limit in additional {
                windows.append(contentsOf: self.extractWindows(from: limit["rate_limit"] as? [String: Any]))
            }
        }
        let fiveHour = self.pickNearest(windows, target: 18_000).map {
            UsageWindow(usedPercent: $0.usedPercent, windowSeconds: $0.windowSeconds, resetAt: $0.resetAt)
        }
        let oneWeek = self.pickNearest(windows, target: 604_800).map {
            UsageWindow(usedPercent: $0.usedPercent, windowSeconds: $0.windowSeconds, resetAt: $0.resetAt)
        }
        let creditSnapshot: CreditSnapshot?
        if let credit = payload["credits"] as? [String: Any] {
            creditSnapshot = CreditSnapshot(
                hasCredits: credit["has_credits"] as? Bool ?? false,
                unlimited: credit["unlimited"] as? Bool ?? false,
                balance: credit["balance"] as? String
            )
        } else {
            creditSnapshot = nil
        }
        return UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: payload["plan_type"] as? String,
            fiveHour: fiveHour,
            oneWeek: oneWeek,
            credits: creditSnapshot
        )
    }

    private static func extractWindows(from rateLimit: [String: Any]?) -> [(usedPercent: Double, windowSeconds: Int, resetAt: Int64?)] {
        guard let rateLimit else { return [] }
        let candidates = [rateLimit["primary_window"], rateLimit["secondary_window"]]
        return candidates.compactMap { item in
            guard let item = item as? [String: Any] else { return nil }
            return (
                usedPercent: item["used_percent"] as? Double ?? 0,
                windowSeconds: item["limit_window_seconds"] as? Int ?? 0,
                resetAt: item["reset_at"] as? Int64 ?? (item["reset_at"] as? Int).map(Int64.init)
            )
        }
    }

    private static func pickNearest(
        _ windows: [(usedPercent: Double, windowSeconds: Int, resetAt: Int64?)],
        target: Int
    ) -> (usedPercent: Double, windowSeconds: Int, resetAt: Int64?)? {
        windows.min { abs($0.windowSeconds - target) < abs($1.windowSeconds - target) }
    }
}
