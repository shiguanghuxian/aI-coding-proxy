#if os(macOS)
import Foundation

enum ManagedProxyHealthcheckFeedbackKind: Equatable, Sendable {
    case node
    case batch
}

enum ManagedProxyHealthcheckFeedbackStatus: Equatable, Sendable {
    case info
    case success
    case warning
    case failure
}

enum ManagedProxyNodeHealthcheckDisplayStatus: Equatable, Sendable {
    case running
    case succeeded
    case failed
}

struct ManagedProxyNodeHealthcheckDisplayState: Equatable, Sendable {
    let status: ManagedProxyNodeHealthcheckDisplayStatus
    let latencyMS: Int64?
    let checkedAt: Date

    init(
        status: ManagedProxyNodeHealthcheckDisplayStatus,
        latencyMS: Int64? = nil,
        checkedAt: Date = Date()
    ) {
        self.status = status
        self.latencyMS = latencyMS
        self.checkedAt = checkedAt
    }
}

struct ManagedProxyHealthcheckFeedback: Equatable, Sendable {
    let kind: ManagedProxyHealthcheckFeedbackKind
    let status: ManagedProxyHealthcheckFeedbackStatus
    let nodeName: String?
    let latencyMS: Int64?
    let succeededNodeCount: Int
    let failedNodeCount: Int
    let totalNodeCount: Int
    let checkedAt: Date

    init(
        kind: ManagedProxyHealthcheckFeedbackKind,
        status: ManagedProxyHealthcheckFeedbackStatus? = nil,
        nodeName: String? = nil,
        latencyMS: Int64? = nil,
        succeededNodeCount: Int = 0,
        failedNodeCount: Int = 0,
        totalNodeCount: Int = 0,
        checkedAt: Date = Date()
    ) {
        self.kind = kind
        self.status = status ?? (latencyMS == nil ? .info : .success)
        self.nodeName = nodeName
        self.latencyMS = latencyMS
        self.succeededNodeCount = succeededNodeCount
        self.failedNodeCount = failedNodeCount
        self.totalNodeCount = totalNodeCount
        self.checkedAt = checkedAt
    }
}
#endif
