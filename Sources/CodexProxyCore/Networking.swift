import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public struct SimpleHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var bodyText: String {
        String(decoding: self.body, as: UTF8.self)
    }
}

public struct StreamingHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(statusCode: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum HTTPMethodName: String, Sendable {
    case GET
    case POST
    case PUT
    case PATCH
    case DELETE
}

public enum HTTPClientFactory {
    private static let maxCollectedResponseBytes = 128 * 1024 * 1024

    public static func request(
        config: AppConfig,
        url: String,
        method: HTTPMethodName = .GET,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> SimpleHTTPResponse {
        let client = self.makeClient(config: config)
        do {
            let request = try self.makeRequest(url: url, method: method, headers: headers, body: body)
            let response = try await client.execute(request, timeout: .seconds(1_800))
            let collected = try await response.body.collect(upTo: self.maxCollectedResponseBytes)
            let result = SimpleHTTPResponse(
                statusCode: Int(response.status.code),
                headers: self.responseHeaders(from: response.headers),
                body: self.data(from: collected)
            )
            try await client.shutdown()
            return result
        } catch {
            try? await client.shutdown()
            throw error
        }
    }

    public static func stream(
        config: AppConfig,
        url: String,
        method: HTTPMethodName = .GET,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> StreamingHTTPResponse {
        let clientBox = ManagedHTTPClient(client: self.makeClient(config: config))
        let request = try self.makeRequest(url: url, method: method, headers: headers, body: body)
        let response = try await clientBox.client.execute(request, timeout: .seconds(1_800))

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                let streamError: Error?
                do {
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        let data = self.data(from: chunk)
                        if !data.isEmpty {
                            continuation.yield(data)
                        }
                    }
                    streamError = nil
                } catch {
                    streamError = error
                }

                try? await clientBox.client.shutdown()

                if let streamError {
                    if streamError is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: streamError)
                    }
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return StreamingHTTPResponse(
            statusCode: Int(response.status.code),
            headers: self.responseHeaders(from: response.headers),
            body: stream
        )
    }

    private static func makeRequest(
        url: String,
        method: HTTPMethodName,
        headers: [String: String],
        body: Data?
    ) throws -> HTTPClientRequest {
        guard URL(string: url) != nil else {
            throw ProxyError.message("Invalid URL: \(url)")
        }

        var request = HTTPClientRequest(url: url)
        request.method = self.httpMethod(for: method)

        var httpHeaders = HTTPHeaders()
        for (name, value) in headers {
            httpHeaders.add(name: name, value: value)
        }
        request.headers = httpHeaders

        if let body {
            request.body = .bytes(body)
        }
        return request
    }

    private static func makeClient(config: AppConfig) -> HTTPClient {
        let clientConfig = HTTPClient.Configuration(
            timeout: .init(connect: .seconds(20), read: .seconds(1_800)),
            proxy: self.proxy(from: config.outboundProxy),
            decompression: .disabled
        )
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: clientConfig)
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
            // AsyncHTTPClient currently supports SOCKS5 transport but not username/password auth.
            return .socksServer(host: settings.host, port: settings.port)
        }
    }

    private static func httpMethod(for method: HTTPMethodName) -> HTTPMethod {
        switch method {
        case .GET:
            return .GET
        case .POST:
            return .POST
        case .PUT:
            return .PUT
        case .PATCH:
            return .PATCH
        case .DELETE:
            return .DELETE
        }
    }

    private static func responseHeaders(from headers: HTTPHeaders) -> [String: String] {
        headers.reduce(into: [:]) { partialResult, header in
            partialResult[header.name.lowercased()] = header.value
        }
    }

    private static func data(from buffer: ByteBuffer) -> Data {
        Data(buffer.readableBytesView)
    }
}

private final class ManagedHTTPClient: @unchecked Sendable {
    let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }
}
