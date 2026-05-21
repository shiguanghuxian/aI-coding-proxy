import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

public enum Paths {
    public static func defaultDataDirectory() -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share", isDirectory: true)
        #endif
        return base.appendingPathComponent("CodexProxy", isDirectory: true)
    }

    public static func databaseURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("codex-proxy.sqlite3")
    }

    public static func keyFileURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("master.key")
    }

    public static func proxyAPIKeyURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("proxy-api-key.txt")
    }

    public static func adminTokenURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("admin-token.txt")
    }

    public static func mihomoSubscriptionURLURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("mihomo-subscription-url.txt")
    }

    public static func mihomoControllerSecretURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("mihomo-controller-secret.txt")
    }

    public static func anthropicOAuthSecretDirectoryURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("anthropic-oauth-secrets", isDirectory: true)
    }

    public static func anthropicOAuthSecretURL(ref: String, in dataDirectory: URL) -> URL {
        self.anthropicOAuthSecretDirectoryURL(in: dataDirectory)
            .appendingPathComponent("\(ref).json")
    }

    public static func geminiOAuthSecretDirectoryURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("gemini-oauth-secrets", isDirectory: true)
    }

    public static func geminiOAuthSecretURL(ref: String, in dataDirectory: URL) -> URL {
        self.geminiOAuthSecretDirectoryURL(in: dataDirectory)
            .appendingPathComponent("\(ref).json")
    }

    public static func mihomoDirectoryURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("mihomo", isDirectory: true)
    }

    public static func mihomoConfigURL(in dataDirectory: URL) -> URL {
        self.mihomoDirectoryURL(in: dataDirectory).appendingPathComponent("config.yaml")
    }

    public static func mihomoProvidersDirectoryURL(in dataDirectory: URL) -> URL {
        self.mihomoDirectoryURL(in: dataDirectory).appendingPathComponent("providers", isDirectory: true)
    }

    public static func mihomoProviderStateURL(in dataDirectory: URL) -> URL {
        self.mihomoProvidersDirectoryURL(in: dataDirectory).appendingPathComponent("codex-subscription.yaml")
    }

    public static func mihomoCacheDirectoryURL(in dataDirectory: URL) -> URL {
        self.mihomoDirectoryURL(in: dataDirectory).appendingPathComponent("cache", isDirectory: true)
    }

    public static func mihomoRuntimeStateURL(in dataDirectory: URL) -> URL {
        self.mihomoDirectoryURL(in: dataDirectory).appendingPathComponent("runtime-state.json")
    }

    public static func mihomoNodeListenerPortsURL(in dataDirectory: URL) -> URL {
        self.mihomoDirectoryURL(in: dataDirectory).appendingPathComponent("node-listener-ports.json")
    }

    public static func mihomoStdoutLogURL(in dataDirectory: URL) -> URL {
        self.mihomoDirectoryURL(in: dataDirectory).appendingPathComponent("mihomo.out.log")
    }

    public static func mihomoStderrLogURL(in dataDirectory: URL) -> URL {
        self.mihomoDirectoryURL(in: dataDirectory).appendingPathComponent("mihomo.err.log")
    }

    public static func launchAgentURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("io.shiguanghuxian.codex-proxy.plist")
    }

    public static func bootstrapAccountsURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("bootstrap-accounts.json")
    }

    public static func bootstrapSettingsURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("settings-bootstrap.json")
    }

    public static func desktopPreferencesURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("desktop-preferences.json")
    }

    public static func clientConfigBackupsDirectoryURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("client-config-backups", isDirectory: true)
    }

}

public enum RuntimeInfo {
    public static let releaseVersion = "1.0.2"
    public static let displayVersion = "1.0.2"
    public static let daemonServerToken = "CodexProxyDaemon/\(releaseVersion)"
}

public enum Helpers {
    public static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    public static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    public static func jsonEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if pretty {
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        }
        return encoder
    }

    public static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func randomToken(length: Int = 48) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    public static func secureRandomData(length: Int = 32) -> Data {
        Data((0..<length).map { _ in UInt8.random(in: 0...255) })
    }

    public static func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func truncate(_ text: String, limit: Int = 200) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "..."
    }

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public static func writeFile(_ url: URL, data: Data, posixMode: Int16 = 0o600) throws {
        try self.ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: posixMode)], ofItemAtPath: url.path)
        #endif
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try self.jsonDecoder().decode(T.self, from: data)
    }

    public static func encodeJSON<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        try self.jsonEncoder(pretty: pretty).encode(value)
    }
}

public enum FixedDisplayDateTimeFormat {
    public static let pattern = "yyyy-MM-dd HH:mm:ss"

    public static func string(from date: Date) -> String {
        self.formatter.string(from: date)
    }

    public static func string(fromUnixSeconds seconds: Int64) -> String {
        self.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    public static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = Self.pattern
        formatter.isLenient = false
        return formatter
    }

    private static let formatter = Self.makeFormatter()
}

public enum RequestLogPresentation {
    public static func maskedAPIKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let scalars = Array(trimmed)
        if scalars.count <= 6 {
            return String(scalars.prefix(2)) + "****"
        }
        if scalars.count <= 12 {
            return String(scalars.prefix(3)) + "****" + String(scalars.suffix(2))
        }
        return String(scalars.prefix(6)) + "****" + String(scalars.suffix(4))
    }
}

public enum RequestLogCSVExport {
    public static func data(entries: [RequestLogEntry], maskAPIKeys: Bool = true) -> Data {
        let lines = [self.headerRow] + entries.map { self.rowString($0, maskAPIKeys: maskAPIKeys) }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(lines.joined(separator: "\r\n").utf8))
        return data
    }

    public static func rowString(_ entry: RequestLogEntry, maskAPIKeys: Bool = true) -> String {
        let apiKey = maskAPIKeys ? RequestLogPresentation.maskedAPIKey(entry.apiKey) : entry.apiKey
        let cacheValue = entry.cacheHitTokens.map(String.init) ?? ""
        let status = entry.success ? "success" : "failure"
        let columns = [
            FixedDisplayDateTimeFormat.string(fromUnixSeconds: entry.timestamp),
            entry.endpoint,
            entry.upstreamURL ?? "",
            entry.clientSource.rawValue,
            entry.model,
            entry.actualModel ?? "",
            entry.reasoningEffort ?? "",
            apiKey,
            entry.accountLabel,
            status,
            String(entry.latencyMS),
            String(entry.inputTokens),
            String(entry.outputTokens),
            String(entry.totalTokens),
            cacheValue,
            entry.failureCategory,
            entry.errorSummary ?? "",
        ]
        return columns.map(self.escapeCSV).joined(separator: ",")
    }

    private static let headerRow = [
        "time",
        "endpoint",
        "upstream_url",
        "client_source",
        "model",
        "actual_model",
        "reasoning_effort",
        "api_key",
        "account_label",
        "status",
        "latency_ms",
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "cache_hit_tokens",
        "failure_category",
        "error_summary",
    ].joined(separator: ",")

    private static func escapeCSV(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        let needsQuotes = escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") || escaped.contains("\r")
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }
}

public enum HTTPErrorClassifier {
    public static func containsAuthSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("invalid_api_key")
            || lower.contains("unauthorized")
            || lower.contains("authentication")
            || lower.contains("access token")
            || lower.contains("expired")
    }

    public static func containsRateLimitSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("rate limit")
            || lower.contains("too many requests")
            || lower.contains("retry after")
    }

    public static func containsQuotaSignal(_ text: String) -> Bool {
        if UsageLimitReachedSignal.parse(from: text) != nil {
            return true
        }
        let lower = text.lowercased()
        return lower.contains("quota")
            || lower.contains("usage_limit")
            || lower.contains("payment_required")
            || lower.contains("exceeded")
    }
}

public enum DecodingDiagnostics {
    public struct Parsed: Sendable, Equatable {
        public enum FailureKind: Sendable, Equatable {
            case missingKey(String)
            case missingValue(String)
            case typeMismatch(String)
            case dataCorrupted
            case other(String)
        }

        public var method: String
        public var endpoint: String
        public var targetType: String?
        public var failureKind: FailureKind
        public var codingPath: String?
        public var debugDescription: String?
        public var responseBodyPreview: String?

        public init(
            method: String,
            endpoint: String,
            targetType: String?,
            failureKind: FailureKind,
            codingPath: String?,
            debugDescription: String?,
            responseBodyPreview: String?
        ) {
            self.method = method
            self.endpoint = endpoint
            self.targetType = targetType
            self.failureKind = failureKind
            self.codingPath = codingPath
            self.debugDescription = debugDescription
            self.responseBodyPreview = responseBodyPreview
        }
    }

    public static func describe(
        _ error: Error,
        endpoint: String,
        method: String,
        targetType: Any.Type? = nil,
        responseBody: Data? = nil
    ) -> String? {
        guard let decodingError = error as? DecodingError else { return nil }

        let requestLabel = "\(method.uppercased()) \(endpoint)"
        let typeLabel = targetType.map { " as \($0)" } ?? ""
        let bodyLabel = self.responseBodyLabel(responseBody)

        switch decodingError {
        case .keyNotFound(let key, let context):
            let codingPath = self.codingPathString(context.codingPath + [key])
            return "Decoding \(requestLabel)\(typeLabel) failed: missing key `\(key.stringValue)` at `\(codingPath)`. \(context.debugDescription)\(bodyLabel)"
        case .valueNotFound(let type, let context):
            let codingPath = self.codingPathString(context.codingPath)
            return "Decoding \(requestLabel)\(typeLabel) failed: missing value of type `\(type)` at `\(codingPath)`. \(context.debugDescription)\(bodyLabel)"
        case .typeMismatch(let type, let context):
            let codingPath = self.codingPathString(context.codingPath)
            return "Decoding \(requestLabel)\(typeLabel) failed: type mismatch for `\(type)` at `\(codingPath)`. \(context.debugDescription)\(bodyLabel)"
        case .dataCorrupted(let context):
            let codingPath = self.codingPathString(context.codingPath)
            return "Decoding \(requestLabel)\(typeLabel) failed: data corrupted at `\(codingPath)`. \(context.debugDescription)\(bodyLabel)"
        @unknown default:
            return "Decoding \(requestLabel)\(typeLabel) failed: \(error.localizedDescription)\(bodyLabel)"
        }
    }

    public static func parse(_ message: String) -> Parsed? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Decoding ") else { return nil }

        let withoutPrefix = String(trimmed.dropFirst("Decoding ".count))
        guard let failedRange = withoutPrefix.range(of: " failed: ") else { return nil }

        let requestPart = String(withoutPrefix[..<failedRange.lowerBound])
        var detailPart = String(withoutPrefix[failedRange.upperBound...])
        var responseBodyPreview: String?

        if let bodyRange = detailPart.range(of: " Response body: ") {
            responseBodyPreview = String(detailPart[bodyRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            detailPart = String(detailPart[..<bodyRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let targetType: String?
        let requestLabel: String
        if let asRange = requestPart.range(of: " as ", options: .backwards) {
            requestLabel = String(requestPart[..<asRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            targetType = String(requestPart[asRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            requestLabel = requestPart.trimmingCharacters(in: .whitespacesAndNewlines)
            targetType = nil
        }

        let requestPieces = requestLabel.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard requestPieces.count == 2 else { return nil }

        let method = String(requestPieces[0])
        let endpoint = String(requestPieces[1])
        let debugDescription = self.debugDescription(from: detailPart)

        if let key = self.capture(in: detailPart, prefix: "missing key `", suffix: "`") {
            return Parsed(
                method: method,
                endpoint: endpoint,
                targetType: targetType,
                failureKind: .missingKey(key),
                codingPath: self.capture(in: detailPart, prefix: " at `", suffix: "`"),
                debugDescription: debugDescription,
                responseBodyPreview: responseBodyPreview
            )
        }

        if let type = self.capture(in: detailPart, prefix: "missing value of type `", suffix: "`") {
            return Parsed(
                method: method,
                endpoint: endpoint,
                targetType: targetType,
                failureKind: .missingValue(type),
                codingPath: self.capture(in: detailPart, prefix: " at `", suffix: "`"),
                debugDescription: debugDescription,
                responseBodyPreview: responseBodyPreview
            )
        }

        if let type = self.capture(in: detailPart, prefix: "type mismatch for `", suffix: "`") {
            return Parsed(
                method: method,
                endpoint: endpoint,
                targetType: targetType,
                failureKind: .typeMismatch(type),
                codingPath: self.capture(in: detailPart, prefix: " at `", suffix: "`"),
                debugDescription: debugDescription,
                responseBodyPreview: responseBodyPreview
            )
        }

        if detailPart.hasPrefix("data corrupted at `") {
            return Parsed(
                method: method,
                endpoint: endpoint,
                targetType: targetType,
                failureKind: .dataCorrupted,
                codingPath: self.capture(in: detailPart, prefix: "data corrupted at `", suffix: "`"),
                debugDescription: debugDescription,
                responseBodyPreview: responseBodyPreview
            )
        }

        return Parsed(
            method: method,
            endpoint: endpoint,
            targetType: targetType,
            failureKind: .other(detailPart),
            codingPath: nil,
            debugDescription: debugDescription,
            responseBodyPreview: responseBodyPreview
        )
    }

    private static func codingPathString(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "$" }

        var result = "$"
        for key in path {
            if let intValue = key.intValue {
                result += "[\(intValue)]"
            } else if !key.stringValue.isEmpty {
                result += ".\(key.stringValue)"
            }
        }
        return result
    }

    private static func responseBodyLabel(_ data: Data?) -> String {
        guard let data else { return "" }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return " Response body: \(Helpers.truncate(text, limit: 180))"
    }

    private static func capture(in text: String, prefix: String, suffix: String) -> String? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        let remainder = text[prefixRange.upperBound...]
        guard let suffixRange = remainder.range(of: suffix) else { return nil }
        return String(remainder[..<suffixRange.lowerBound])
    }

    private static func debugDescription(from detail: String) -> String? {
        guard let range = detail.range(of: ". ") else { return nil }
        let description = String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? nil : description
    }
}
