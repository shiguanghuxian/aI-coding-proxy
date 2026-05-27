import Foundation

public struct DiagnosticRequestBodyCaptureInput {
    public var endpoint: String
    public var upstreamURL: String
    public var accountKey: String
    public var accountLabel: String
    public var model: String
    public var actualModel: String?
    public var body: Data
    public var bodyObject: [String: Any]
    public var config: DiagnosticRequestBodyCaptureConfig
    public var createdAt: Int64

    public init(
        endpoint: String,
        upstreamURL: String,
        accountKey: String,
        accountLabel: String,
        model: String,
        actualModel: String?,
        body: Data,
        bodyObject: [String: Any],
        config: DiagnosticRequestBodyCaptureConfig,
        createdAt: Int64 = Helpers.now()
    ) {
        self.endpoint = endpoint
        self.upstreamURL = upstreamURL
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.model = model
        self.actualModel = actualModel
        self.body = body
        self.bodyObject = bodyObject
        self.config = config
        self.createdAt = createdAt
    }
}

public enum DiagnosticRequestBodySupport {
    public static func bodySHA256(_ body: Data) -> String {
        Helpers.sha256(body)
    }

    public static func normalizedPrefixSHA256(from bodyObject: [String: Any]) -> String {
        let prefixObject = self.normalizedPrefixObject(from: bodyObject)
        guard JSONSerialization.isValidJSONObject(prefixObject),
              let data = try? JSONSerialization.data(withJSONObject: prefixObject, options: [.sortedKeys])
        else {
            return Helpers.sha256(Data())
        }
        return Helpers.sha256(data)
    }

    public static func normalizedPrefixObject(from bodyObject: [String: Any]) -> [String: Any] {
        let keys = [
            "model",
            "messages",
            "input",
            "instructions",
            "system",
            "contents",
            "tools",
            "tool_choice",
            "toolConfig",
            "tool_config",
            "reasoning",
            "reasoning_effort",
            "thinking",
            "generationConfig",
            "generation_config",
        ]
        var result: [String: Any] = [:]
        for key in keys {
            if let value = bodyObject[key] {
                result[key] = value
            }
        }
        return result
    }
}
