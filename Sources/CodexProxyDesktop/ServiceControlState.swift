#if os(macOS)
import CodexProxyCore
import Foundation

enum LocalServiceControlState: Sendable, Equatable {
    case checking
    case notInstalled
    case stopped
    case starting
    case runningHealthy
    case runningDegraded
    case stopping
}

enum RemoteServiceControlState: Sendable, Equatable {
    case unloaded
    case stopped
    case starting
    case running
    case stopping
    case unreachable
}

enum LocalServiceOperation: Sendable, Equatable {
    case idle
    case starting
    case stopping
}

enum RemoteOperation: Sendable, Equatable {
    case idle
    case saving(hostID: String?)
    case testing(hostID: String)
    case deploying(hostID: String)
    case loadingStatus(hostID: String)
    case loadingLogs(hostID: String)
    case starting(hostID: String)
    case stopping(hostID: String)
    case deleting(hostID: String)

    var hostID: String? {
        switch self {
        case .idle:
            return nil
        case .saving(let hostID):
            return hostID
        case .testing(let hostID),
             .deploying(let hostID),
             .loadingStatus(let hostID),
             .loadingLogs(let hostID),
             .starting(let hostID),
             .stopping(let hostID),
             .deleting(let hostID):
            return hostID
        }
    }
}

enum ServiceControlResolver {
    static func localState(
        localStatus: LocalServiceStatus?,
        proxyStatus: ProxyStatus?,
        operation: LocalServiceOperation
    ) -> LocalServiceControlState {
        switch operation {
        case .starting:
            return .starting
        case .stopping:
            return .stopping
        case .idle:
            break
        }

        guard let localStatus else {
            return .checking
        }

        if localStatus.installed == false {
            return .notInstalled
        }

        if localStatus.running {
            return proxyStatus?.running == true ? .runningHealthy : .runningDegraded
        }

        return .stopped
    }

    static func remoteState(
        status: RemoteDeployStatus?,
        loadError: String?,
        operation: RemoteOperation,
        hostID: String
    ) -> RemoteServiceControlState {
        switch operation {
        case .starting(let currentHostID) where currentHostID == hostID:
            return .starting
        case .stopping(let currentHostID) where currentHostID == hostID:
            return .stopping
        default:
            break
        }

        if loadError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .unreachable
        }

        guard let status else {
            return .unloaded
        }

        return status.running ? .running : .stopped
    }
}
#endif
