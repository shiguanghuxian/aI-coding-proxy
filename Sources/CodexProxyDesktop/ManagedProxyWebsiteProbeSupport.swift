#if os(macOS)
import CodexProxyCore
import Foundation

enum ManagedProxyWebsiteProbeTarget: String, CaseIterable, Identifiable, Sendable {
    case custom
    case google
    case github
    case youtube
    case wikipedia

    var id: String { self.rawValue }

    var fixedProbeURL: URL? {
        switch self {
        case .custom:
            return nil
        case .google:
            return URL(string: "https://www.google.com/generate_204")!
        case .github:
            return URL(string: "https://github.com/robots.txt")!
        case .youtube:
            return URL(string: "https://www.youtube.com/robots.txt")!
        case .wikipedia:
            return URL(string: "https://www.wikipedia.org/robots.txt")!
        }
    }

    var fixedHostText: String? {
        switch self {
        case .custom:
            return nil
        case .google:
            return "www.google.com/generate_204"
        case .github:
            return "github.com/robots.txt"
        case .youtube:
            return "www.youtube.com/robots.txt"
        case .wikipedia:
            return "www.wikipedia.org/robots.txt"
        }
    }
}

enum ManagedProxyWebsiteProbeState: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case reachableButUnexpected
    case failed
}

struct ManagedProxyWebsiteProbeResult: Equatable, Sendable {
    let target: ManagedProxyWebsiteProbeTarget
    let state: ManagedProxyWebsiteProbeState
    let statusCode: Int?
    let latencyMilliseconds: Int?
    let errorSummary: String?
    let testedAt: Date?

    init(
        target: ManagedProxyWebsiteProbeTarget,
        state: ManagedProxyWebsiteProbeState = .idle,
        statusCode: Int? = nil,
        latencyMilliseconds: Int? = nil,
        errorSummary: String? = nil,
        testedAt: Date? = nil
    ) {
        self.target = target
        self.state = state
        self.statusCode = statusCode
        self.latencyMilliseconds = latencyMilliseconds
        self.errorSummary = errorSummary
        self.testedAt = testedAt
    }
}

struct ManagedProxyWebsiteProbeResponse: Equatable, Sendable {
    let statusCode: Int
    let latencyMilliseconds: Int
}

actor ManagedProxyWebsiteProbeClient {
    typealias ProbeHandler = @Sendable (ManagedProxyWebsiteProbeTarget, URL, Int) async throws -> ManagedProxyWebsiteProbeResponse

    private let probeHandler: ProbeHandler?

    init(probeHandler: ProbeHandler? = nil) {
        self.probeHandler = probeHandler
    }

    func probe(
        _ target: ManagedProxyWebsiteProbeTarget,
        url: URL,
        mixedPort: Int
    ) async -> ManagedProxyWebsiteProbeResult {
        let startedAt = Date()

        do {
            let response: ManagedProxyWebsiteProbeResponse
            if let probeHandler {
                response = try await probeHandler(target, url, mixedPort)
            } else {
                response = try await self.performRequest(url: url, mixedPort: mixedPort, startedAt: startedAt)
            }

            return ManagedProxyWebsiteProbeResult(
                target: target,
                state: Self.state(forStatusCode: response.statusCode),
                statusCode: response.statusCode,
                latencyMilliseconds: response.latencyMilliseconds,
                errorSummary: nil,
                testedAt: Date()
            )
        } catch {
            let latency = Self.elapsedMilliseconds(since: startedAt)
            return ManagedProxyWebsiteProbeResult(
                target: target,
                state: .failed,
                statusCode: nil,
                latencyMilliseconds: latency > 0 ? latency : nil,
                errorSummary: Self.errorSummary(for: error),
                testedAt: Date()
            )
        }
    }

    private func performRequest(
        url: URL,
        mixedPort: Int,
        startedAt: Date
    ) async throws -> ManagedProxyWebsiteProbeResponse {
        let response = try await HTTPProxyProbe.probe(
            url: url.absoluteString,
            proxySettings: OutboundProxySettings(
                scheme: .http,
                host: "127.0.0.1",
                port: mixedPort
            ),
            timeoutMilliseconds: 8_000
        )

        return ManagedProxyWebsiteProbeResponse(
            statusCode: response.statusCode,
            latencyMilliseconds: max(response.latencyMilliseconds, Int64(Self.elapsedMilliseconds(since: startedAt)))
                .clampedToInt()
        )
    }

    private static func state(forStatusCode statusCode: Int) -> ManagedProxyWebsiteProbeState {
        if (100..<600).contains(statusCode) {
            return .succeeded
        }
        return .failed
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }

    private static func errorSummary(for error: Error) -> String {
        if let error = error as? HTTPProxyProbeError {
            return error.summary
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Request timed out"
            case .cannotConnectToHost, .cannotFindHost:
                return "Proxy connection failed"
            case .networkConnectionLost:
                return "Network connection was lost"
            case .resourceUnavailable:
                return "Proxy resource is unavailable"
            case .notConnectedToInternet:
                return "No internet connection"
            case .badServerResponse:
                return "Invalid HTTP response"
            default:
                break
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Probe request failed" : message
    }
}

private extension Int64 {
    func clampedToInt() -> Int {
        if self > Int64(Int.max) {
            return Int.max
        }
        if self < Int64(Int.min) {
            return Int.min
        }
        return Int(self)
    }
}
#endif
