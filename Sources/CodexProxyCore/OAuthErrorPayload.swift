import Foundation

public struct OAuthErrorPayload: Codable, Sendable, Equatable {
    public var kind: String
    public var errorCode: String
    public var requestId: String?

    public init(kind: String, errorCode: String, requestId: String?) {
        self.kind = kind
        self.errorCode = errorCode
        self.requestId = requestId
    }
}
