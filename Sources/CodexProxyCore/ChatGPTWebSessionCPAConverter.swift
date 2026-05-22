import Foundation

public struct ChatGPTWebSessionCPAConversion: Sendable, Equatable {
    public var sourcePath: String
    public var email: String?
    public var accountID: String
    public var cpaJSON: String

    public init(sourcePath: String, email: String?, accountID: String, cpaJSON: String) {
        self.sourcePath = sourcePath
        self.email = email
        self.accountID = accountID
        self.cpaJSON = cpaJSON
    }
}

public enum ChatGPTWebSessionCPAConversionError: LocalizedError, Equatable {
    case invalidJSON
    case noSessionObjects
    case missingAccessToken
    case missingAccountID
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "ChatGPT Web session JSON 解析失败"
        case .noSessionObjects:
            return "未找到包含 accessToken 和 user/email/account 信息的 ChatGPT Web session 对象"
        case .missingAccessToken:
            return "ChatGPT Web session 缺少 accessToken"
        case .missingAccountID:
            return "ChatGPT Web session 缺少 account.id 或可解析的 chatgpt_account_id"
        case .invalidOutput:
            return "转换后的 CPA JSON 无效"
        }
    }
}

public struct ChatGPTWebSessionCPAConverter {
    private typealias JSONObject = [String: Any]

    public init() {}

    public func convertPastedSessions(_ text: String, now: Date = Date()) throws -> [ChatGPTWebSessionCPAConversion] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ChatGPTWebSessionCPAConversionError.noSessionObjects
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw ChatGPTWebSessionCPAConversionError.invalidJSON
        }

        var sources: [(object: JSONObject, path: String)] = []
        self.collectSessionLikeObjects(parsed, path: "$", into: &sources)
        guard sources.isEmpty == false else {
            throw ChatGPTWebSessionCPAConversionError.noSessionObjects
        }

        return try sources.map { source in
            try self.convertSession(source.object, now: now, sourcePath: source.path)
        }
    }

    private func convertSession(
        _ record: JSONObject,
        now: Date,
        sourcePath: String
    ) throws -> ChatGPTWebSessionCPAConversion {
        guard let accessToken = Self.firstNonEmpty(
            record["accessToken"],
            record["access_token"],
            record.object("tokens")?["accessToken"],
            record.object("tokens")?["access_token"],
            record.object("token")?["accessToken"],
            record.object("token")?["access_token"],
            record.object("credentials")?["accessToken"],
            record.object("credentials")?["access_token"]
        ) else {
            throw ChatGPTWebSessionCPAConversionError.missingAccessToken
        }

        let sessionToken = Self.firstNonEmpty(
            record["sessionToken"],
            record["session_token"],
            record.object("tokens")?["sessionToken"],
            record.object("tokens")?["session_token"],
            record.object("token")?["sessionToken"],
            record.object("token")?["session_token"],
            record.object("credentials")?["session_token"]
        )
        let refreshToken = Self.firstNonEmpty(
            record["refreshToken"],
            record["refresh_token"],
            record.object("tokens")?["refreshToken"],
            record.object("tokens")?["refresh_token"],
            record.object("token")?["refreshToken"],
            record.object("token")?["refresh_token"],
            record.object("credentials")?["refresh_token"]
        )
        let inputIDToken = Self.firstNonEmpty(
            record["idToken"],
            record["id_token"],
            record.object("tokens")?["idToken"],
            record.object("tokens")?["id_token"],
            record.object("token")?["idToken"],
            record.object("token")?["id_token"],
            record.object("credentials")?["id_token"]
        )

        let accessPayload = Self.jwtPayload(accessToken)
        let idPayload = Self.jwtPayload(inputIDToken)
        let accessAuth = Self.openAIAuthSection(accessPayload)
        let idAuth = Self.openAIAuthSection(idPayload)
        let accessProfile = Self.openAIProfileSection(accessPayload)

        let expiresAt = Self.firstNonEmpty(
            accessPayload.flatMap { Self.timestampFromUnixSeconds($0["exp"]) },
            Self.normalizeTimestamp(record["expires"]),
            Self.normalizeTimestamp(record["expiresAt"]),
            Self.normalizeTimestamp(record["expired"]),
            Self.normalizeTimestamp(record["expires_at"])
        )
        let email = Self.firstNonEmpty(
            record.object("user")?["email"],
            record["email"],
            record.object("meta")?["label"],
            record["label"],
            record.object("credentials")?["email"],
            record.object("providerSpecificData")?["email"],
            accessProfile["email"],
            idPayload?["email"],
            accessPayload?["email"]
        )
        let accountID = Self.firstNonEmpty(
            record.object("account")?["id"],
            record["account_id"],
            record.object("tokens")?["accountId"],
            record.object("tokens")?["account_id"],
            record["chatgptAccountId"],
            record["chatgpt_account_id"],
            record.object("meta")?["chatgptAccountId"],
            record.object("meta")?["chatgpt_account_id"],
            record.object("tokens")?["chatgptAccountId"],
            record.object("tokens")?["chatgpt_account_id"],
            record.object("providerSpecificData")?["chatgptAccountId"],
            record.object("providerSpecificData")?["chatgpt_account_id"],
            record.object("credentials")?["chatgpt_account_id"],
            accessAuth["chatgpt_account_id"],
            idAuth["chatgpt_account_id"],
            record.string("provider") == "codex" ? record["id"] : nil
        )
        guard let accountID else {
            throw ChatGPTWebSessionCPAConversionError.missingAccountID
        }

        let userID = Self.firstNonEmpty(
            record.object("user")?["id"],
            record["user_id"],
            record["chatgptUserId"],
            record.object("providerSpecificData")?["chatgptUserId"],
            record.object("providerSpecificData")?["chatgpt_user_id"],
            accessAuth["chatgpt_user_id"],
            accessAuth["user_id"],
            idAuth["chatgpt_user_id"],
            idAuth["user_id"]
        )
        let planType = Self.firstNonEmpty(
            record.object("account")?["planType"],
            record.object("account")?["plan_type"],
            record["planType"],
            record["plan_type"],
            record.object("providerSpecificData")?["chatgptPlanType"],
            record.object("providerSpecificData")?["chatgpt_plan_type"],
            record.object("credentials")?["plan_type"],
            accessAuth["chatgpt_plan_type"],
            idAuth["chatgpt_plan_type"]
        )
        let name = Self.firstNonEmpty(email, record["name"], record["label"], "ChatGPT Account") ?? "ChatGPT Account"
        let syntheticIDToken = inputIDToken == nil
            ? Self.syntheticCodexIDToken(
                email: email,
                accountID: accountID,
                planType: planType,
                userID: userID,
                expiresAt: expiresAt,
                now: now
            )
            : nil
        let idToken = Self.firstNonEmpty(inputIDToken, syntheticIDToken)
        let exportedAt = Self.isoString(from: now)

        let cpa = Self.compactKeepingEmpty([
            ("type", "codex"),
            ("account_id", accountID),
            ("chatgpt_account_id", accountID),
            ("email", email),
            ("name", name),
            ("plan_type", planType),
            ("chatgpt_plan_type", planType),
            ("id_token", idToken),
            ("id_token_synthetic", syntheticIDToken == nil ? nil : true),
            ("access_token", accessToken),
            ("refresh_token", refreshToken ?? ""),
            ("session_token", sessionToken),
            ("last_refresh", exportedAt),
            ("expired", expiresAt),
            ("disabled", record.bool("disabled") == true ? true : nil),
        ])

        guard JSONSerialization.isValidJSONObject(cpa),
              let data = try? JSONSerialization.data(withJSONObject: cpa, options: [.prettyPrinted, .sortedKeys])
        else {
            throw ChatGPTWebSessionCPAConversionError.invalidOutput
        }
        return ChatGPTWebSessionCPAConversion(
            sourcePath: sourcePath,
            email: email,
            accountID: accountID,
            cpaJSON: String(decoding: data, as: UTF8.self)
        )
    }

    private func collectSessionLikeObjects(
        _ value: Any,
        path: String,
        into found: inout [(object: JSONObject, path: String)]
    ) {
        if let object = value as? JSONObject {
            let token = Self.firstNonEmpty(
                object["accessToken"],
                object["access_token"],
                object.object("tokens")?["accessToken"],
                object.object("tokens")?["access_token"],
                object.object("token")?["accessToken"],
                object.object("token")?["access_token"],
                object.object("credentials")?["accessToken"],
                object.object("credentials")?["access_token"]
            )
            let hasIdentity = object.object("user") != nil || Self.firstNonEmpty(
                object["email"],
                object["name"],
                object["label"],
                object.object("account")?["id"],
                object.object("meta")?["label"],
                object.object("tokens")?["accountId"],
                object.object("tokens")?["account_id"],
                object.object("tokens")?["chatgptAccountId"],
                object.object("tokens")?["chatgpt_account_id"],
                object.object("providerSpecificData")?["chatgptAccountId"],
                object.object("providerSpecificData")?["chatgpt_account_id"],
                object["id"]
            ) != nil

            if token != nil && hasIdentity {
                found.append((object, path))
                return
            }

            for (key, child) in object where !["accessToken", "access_token", "sessionToken"].contains(key) {
                self.collectSessionLikeObjects(child, path: "\(path).\(key)", into: &found)
            }
            return
        }

        if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                self.collectSessionLikeObjects(child, path: "\(path)[\(index)]", into: &found)
            }
        }
    }

    private static func firstNonEmpty(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func compactKeepingEmpty(_ entries: [(String, Any?)]) -> JSONObject {
        var result: JSONObject = [:]
        for (key, value) in entries {
            if let value {
                result[key] = value
            }
        }
        return result
    }

    private static func jwtPayload(_ token: String?) -> JSONObject? {
        guard let token, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let segments = token.split(separator: ".")
        guard segments.count >= 2, let data = Self.base64URLDecode(String(segments[1])) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    private static func openAIAuthSection(_ payload: JSONObject?) -> JSONObject {
        payload?["https://api.openai.com/auth"] as? JSONObject ?? [:]
    }

    private static func openAIProfileSection(_ payload: JSONObject?) -> JSONObject {
        payload?["https://api.openai.com/profile"] as? JSONObject ?? [:]
    }

    private static func syntheticCodexIDToken(
        email: String?,
        accountID: String,
        planType: String?,
        userID: String?,
        expiresAt: String?,
        now: Date
    ) -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        var authInfo: JSONObject = ["chatgpt_account_id": accountID]
        if let planType {
            authInfo["chatgpt_plan_type"] = planType
        }
        if let userID {
            authInfo["chatgpt_user_id"] = userID
            authInfo["user_id"] = userID
        }

        var payload: JSONObject = [
            "iat": issuedAt,
            "exp": Self.epochSeconds(from: expiresAt) == 0
                ? issuedAt + 90 * 24 * 60 * 60
                : Self.epochSeconds(from: expiresAt),
            "https://api.openai.com/auth": authInfo,
        ]
        if let email {
            payload["email"] = email
        }

        let header = Self.base64URLEncodeJSONObject([
            "alg": "none",
            "typ": "JWT",
            "cpa_synthetic": true,
        ])
        let body = Self.base64URLEncodeJSONObject(payload)
        return "\(header).\(body).synthetic"
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLEncodeJSONObject(_ value: JSONObject) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return Self.base64URLEncode(data)
    }

    private static func normalizeTimestamp(_ value: Any?) -> String? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            return Self.isoString(from: Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw))
        }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let numeric = Double(trimmed), numeric.isFinite {
            return Self.isoString(from: Date(timeIntervalSince1970: numeric > 1e11 ? numeric / 1000 : numeric))
        }
        guard let date = Self.parseDate(trimmed) else { return nil }
        return Self.isoString(from: date)
    }

    private static func timestampFromUnixSeconds(_ value: Any?) -> String? {
        let numeric: Double?
        if let number = value as? NSNumber {
            numeric = number.doubleValue
        } else if let string = value as? String {
            numeric = Double(string)
        } else {
            numeric = nil
        }
        guard let numeric, numeric.isFinite else { return nil }
        return Self.isoString(from: Date(timeIntervalSince1970: numeric))
    }

    private static func epochSeconds(from value: Any?) -> Int {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite else { return 0 }
            return Int(raw > 1e11 ? raw / 1000 : raw)
        }
        guard let string = value as? String else { return 0 }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numeric = Double(trimmed), numeric.isFinite {
            return Int(numeric > 1e11 ? numeric / 1000 : numeric)
        }
        guard let date = Self.parseDate(trimmed) else { return 0 }
        return Int(date.timeIntervalSince1970)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }
        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        if let date = withoutFractionalSeconds.date(from: string) {
            return date
        }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = .current
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: string)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func string(_ key: String) -> String? {
        if let string = self[key] as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let bool = self[key] as? Bool {
            return bool
        }
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}
