import AsyncHTTPClient
import Foundation

public enum HTTPProxyProbeFailureKind: String, Codable, Sendable, Equatable {
    case invalidURL
    case timeout
    case listenerUnavailable
    case proxyConnectionFailed
    case tlsHandshakeFailed
    case invalidHTTPResponse
    case requestFailed
}

public struct HTTPProxyProbeResponse: Sendable, Equatable {
    public let statusCode: Int
    public let latencyMilliseconds: Int64

    public init(statusCode: Int, latencyMilliseconds: Int64) {
        self.statusCode = statusCode
        self.latencyMilliseconds = max(latencyMilliseconds, 1)
    }
}

public struct HTTPProxyProbeError: LocalizedError, Sendable, Equatable {
    public let kind: HTTPProxyProbeFailureKind
    public let summary: String

    public init(kind: HTTPProxyProbeFailureKind, summary: String? = nil) {
        self.kind = kind
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.summary = trimmed.isEmpty ? Self.defaultSummary(for: kind) : trimmed
    }

    public var errorDescription: String? {
        self.summary
    }

    public static func listenerUnavailable() -> HTTPProxyProbeError {
        HTTPProxyProbeError(kind: .listenerUnavailable)
    }

    public static func defaultSummary(for kind: HTTPProxyProbeFailureKind) -> String {
        switch kind {
        case .invalidURL:
            return "Probe URL is invalid"
        case .timeout:
            return "Probe timed out"
        case .listenerUnavailable:
            return "Node listener is not ready"
        case .proxyConnectionFailed:
            return "Proxy connection failed"
        case .tlsHandshakeFailed:
            return "TLS handshake failed"
        case .invalidHTTPResponse:
            return "Invalid HTTP response"
        case .requestFailed:
            return "Probe request failed"
        }
    }
}

public enum HTTPProxyProbe {
    public static func probe(
        url: String,
        proxySettings: OutboundProxySettings,
        timeoutMilliseconds: Int
    ) async throws -> HTTPProxyProbeResponse {
        guard URL(string: url) != nil else {
            throw HTTPProxyProbeError(kind: .invalidURL)
        }

        let timeoutMilliseconds = max(timeoutMilliseconds, 1)
        let client = self.makeClient(
            proxySettings: proxySettings,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let startedAt = Date()

        do {
            var request = HTTPClientRequest(url: url)
            request.method = .GET
            request.headers.add(name: "Accept", value: "*/*")
            let response = try await client.execute(
                request,
                timeout: .milliseconds(Int64(timeoutMilliseconds))
            )
            try await client.shutdown()
            return HTTPProxyProbeResponse(
                statusCode: Int(response.status.code),
                latencyMilliseconds: Int64(Date().timeIntervalSince(startedAt) * 1_000)
            )
        } catch {
            try? await client.shutdown()
            throw self.classify(error)
        }
    }

    public static func classify(_ error: Error) -> HTTPProxyProbeError {
        if let error = error as? HTTPProxyProbeError {
            return error
        }
        if let error = error as? HTTPClientError {
            if error == .invalidURL || error == .emptyHost || error == .emptyScheme || error == .missingSocketPath {
                return HTTPProxyProbeError(kind: .invalidURL)
            }
            if error == .readTimeout ||
                error == .writeTimeout ||
                error == .connectTimeout ||
                error == .socksHandshakeTimeout ||
                error == .httpProxyHandshakeTimeout ||
                error == .deadlineExceeded ||
                error == .getConnectionFromPoolTimeout
            {
                return HTTPProxyProbeError(kind: .timeout)
            }
            if error == .tlsHandshakeTimeout {
                return HTTPProxyProbeError(kind: .tlsHandshakeFailed)
            }
            if error == .invalidProxyResponse ||
                error == .proxyAuthenticationRequired ||
                error == .remoteConnectionClosed
            {
                return HTTPProxyProbeError(kind: .proxyConnectionFailed)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return HTTPProxyProbeError(kind: .timeout)
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                .resourceUnavailable, .notConnectedToInternet, .dnsLookupFailed:
                return HTTPProxyProbeError(kind: .proxyConnectionFailed)
            case .badServerResponse:
                return HTTPProxyProbeError(kind: .invalidHTTPResponse)
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                .clientCertificateRequired:
                return HTTPProxyProbeError(kind: .tlsHandshakeFailed)
            default:
                break
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedText = [message, description]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .lowercased()

        if combinedText.contains("invalid url") || combinedText.contains("unsupported url") {
            return HTTPProxyProbeError(kind: .invalidURL)
        }
        if combinedText.contains("listener is not ready") || combinedText.contains("listener unavailable") {
            return HTTPProxyProbeError(kind: .listenerUnavailable)
        }
        if combinedText.contains("timed out") ||
            combinedText.contains("timeout") ||
            combinedText.contains("deadline exceeded")
        {
            return HTTPProxyProbeError(kind: .timeout)
        }
        if combinedText.contains("tls") ||
            combinedText.contains("ssl") ||
            combinedText.contains("handshake") ||
            combinedText.contains("certificate")
        {
            return HTTPProxyProbeError(kind: .tlsHandshakeFailed)
        }
        if combinedText.contains("bad server response") ||
            combinedText.contains("invalid http") ||
            combinedText.contains("http parser") ||
            combinedText.contains("malformed response")
        {
            return HTTPProxyProbeError(kind: .invalidHTTPResponse)
        }
        if combinedText.contains("connection refused") ||
            combinedText.contains("cannot connect") ||
            combinedText.contains("connect error") ||
            combinedText.contains("connection reset") ||
            combinedText.contains("network is unreachable") ||
            combinedText.contains("host is unreachable") ||
            combinedText.contains("failed to connect")
        {
            return HTTPProxyProbeError(kind: .proxyConnectionFailed)
        }

        let summary = message.isEmpty ? nil : message
        return HTTPProxyProbeError(kind: .requestFailed, summary: summary)
    }

    private static func makeClient(
        proxySettings: OutboundProxySettings,
        timeoutMilliseconds: Int
    ) -> HTTPClient {
        HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: HTTPClient.Configuration(
                timeout: .init(
                    connect: .milliseconds(Int64(timeoutMilliseconds)),
                    read: .milliseconds(Int64(timeoutMilliseconds))
                ),
                proxy: self.proxy(from: proxySettings),
                decompression: .disabled
            )
        )
    }

    private static func proxy(from settings: OutboundProxySettings) -> HTTPClient.Configuration.Proxy? {
        guard settings.isEnabled else { return nil }
        switch settings.scheme {
        case .disabled:
            return nil
        case .http, .https:
            let authorization = settings.username.isEmpty
                ? nil
                : HTTPClient.Authorization.basic(username: settings.username, password: settings.password)
            return .server(host: settings.host, port: settings.port, authorization: authorization)
        case .socks5:
            return .socksServer(host: settings.host, port: settings.port)
        }
    }
}
