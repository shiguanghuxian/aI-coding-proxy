import Foundation

public final class OAuthCallbackListener: @unchecked Sendable {
    public let port: Int

    private let socketFD: Int32
    private let stateLock = NSLock()
    private var workerTask: Task<Void, Never>?
    private var stopRequested = false
    private var socketClosed = false

    private init(socketFD: Int32, port: Int) {
        self.socketFD = socketFD
        self.port = port
    }

    deinit {
        self.closeSocketIfNeeded()
    }

    public static func bind(preferredPort: Int = AuthService.defaultOAuthRedirectPort) throws -> OAuthCallbackListener {
        do {
            return try self.bindExact(port: preferredPort)
        } catch {
            let message = error.localizedDescription
            guard preferredPort > 0, message.contains("Address already in use") || message.contains("地址已被占用") else {
                throw error
            }
            return try self.bindExact(port: 0)
        }
    }

    public func start(
        expiresAt: Int64,
        onCallback: @escaping @Sendable (String, OAuthCallbackPageLanguage) async -> OAuthCallbackPageResponse,
        onCancel: @escaping @Sendable () async -> Void = {},
        onTimeout: @escaping @Sendable () async -> Void
    ) {
        guard self.currentWorkerTask() == nil else {
            return
        }
        self.setStopRequested(false)
        let task = Task.detached(priority: .utility) { [self] in
            await self.runLoop(expiresAt: expiresAt, onCallback: onCallback, onCancel: onCancel, onTimeout: onTimeout)
        }
        self.setWorkerTask(task)
    }

    public func stop() async {
        self.setStopRequested(true)
        let task = self.takeWorkerTask()

        self.closeSocketIfNeeded()
        task?.cancel()
        _ = await task?.result
    }

    private static func bindExact(port: Int) throws -> OAuthCallbackListener {
        let fd = POSIXCompat.makeTCPIPv4StreamSocket()
        guard fd >= 0 else {
            throw ProxyError.message("无法创建 OAuth 回调监听 socket: \(self.socketErrorDescription())")
        }

        do {
            try self.configureListeningSocket(fd)
            try self.bindSocket(fd, port: port)
            try self.listenSocket(fd)
            let actualPort = try self.localPort(for: fd)
            return OAuthCallbackListener(socketFD: fd, port: actualPort)
        } catch {
            POSIXCompat.closeDescriptor(fd)
            if port > 0 {
                throw ProxyError.message("无法启动 OAuth 回调监听 127.0.0.1:\(port): \(error.localizedDescription)")
            }
            throw ProxyError.message("无法启动 OAuth 回调监听到本地空闲端口: \(error.localizedDescription)")
        }
    }

    private func runLoop(
        expiresAt: Int64,
        onCallback: @escaping @Sendable (String, OAuthCallbackPageLanguage) async -> OAuthCallbackPageResponse,
        onCancel: @escaping @Sendable () async -> Void,
        onTimeout: @escaping @Sendable () async -> Void
    ) async {
        defer {
            self.clearWorkerTask()
            self.closeSocketIfNeeded()
        }

        while !self.isStopRequested {
            if Helpers.now() >= expiresAt {
                await onTimeout()
                return
            }

            let clientFD = POSIXCompat.accept(self.socketFD)
            if clientFD >= 0 {
                let shouldStop = await self.handleConnection(clientFD, onCallback: onCallback, onCancel: onCancel)
                if shouldStop {
                    return
                }
                continue
            }

            let errorCode = POSIXCompat.lastErrno()
            if errorCode == POSIXCompat.wouldBlockErrorCode || errorCode == POSIXCompat.againErrorCode {
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            if self.isStopRequested && (errorCode == POSIXCompat.badFileDescriptorErrorCode || errorCode == POSIXCompat.invalidArgumentErrorCode) {
                return
            }
            return
        }
    }

    private func handleConnection(
        _ clientFD: Int32,
        onCallback: @escaping @Sendable (String, OAuthCallbackPageLanguage) async -> OAuthCallbackPageResponse,
        onCancel: @escaping @Sendable () async -> Void
    ) async -> Bool {
        POSIXCompat.configureClientSocket(clientFD)
        defer { POSIXCompat.closeDescriptor(clientFD) }

        let response: OAuthCallbackPageResponse
        let shouldStop: Bool

        do {
            let request = try self.readRequest(from: clientFD)
            let preferredLanguage = OAuthCallbackPageRenderer.preferredLanguage(
                fromAcceptLanguage: request.headers["accept-language"]
            )
            guard request.method.uppercased() == "GET" else {
                response = OAuthCallbackPageRenderer.failure(
                    detail: "Unsupported OAuth callback request method: \(request.method)",
                    preferredLanguage: preferredLanguage
                )
                shouldStop = true
                self.writeHTMLResponse(response, to: clientFD)
                return shouldStop
            }

            if request.target == "/cancel" {
                await onCancel()
                response = OAuthCallbackPageRenderer.cancelled(preferredLanguage: preferredLanguage)
                shouldStop = true
            } else if Self.isSupportedCallbackTarget(request.target) {
                let callbackURL = "http://localhost:\(self.port)\(request.target)"
                response = await onCallback(callbackURL, preferredLanguage)
                shouldStop = true
            } else {
                print("[oauth] Ignoring unexpected callback path: \(request.target)")
                response = OAuthCallbackPageRenderer.invalidPath(preferredLanguage: preferredLanguage)
                shouldStop = false
            }
        } catch {
            response = OAuthCallbackPageRenderer.failure(
                detail: error.localizedDescription,
                preferredLanguage: .english
            )
            shouldStop = true
        }

        self.writeHTMLResponse(response, to: clientFD)
        return shouldStop
    }

    private static func isSupportedCallbackTarget(_ target: String) -> Bool {
        let callbackPaths = [
            AuthService.openAIOAuthCallbackPath,
            AuthService.anthropicOAuthCallbackPath,
            AuthService.geminiOAuthCallbackPath,
        ]
        return callbackPaths.contains { target == $0 || target.hasPrefix("\($0)?") }
    }

    private struct IncomingRequest: Sendable, Equatable {
        var method: String
        var target: String
        var headers: [String: String]
    }

    private func readRequest(from clientFD: Int32) throws -> IncomingRequest {
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)

        while requestData.count < 16 * 1024 {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return POSIXCompat.receive(clientFD, buffer: baseAddress, count: rawBuffer.count)
            }
            if bytesRead > 0 {
                requestData.append(buffer, count: Int(bytesRead))
                if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                    break
                }
                continue
            }
            if bytesRead == 0 {
                break
            }

            let errorCode = POSIXCompat.lastErrno()
            if errorCode == POSIXCompat.interruptedErrorCode {
                continue
            }
            throw ProxyError.message("读取 OAuth 回调请求失败: \(Self.socketErrorDescription(code: errorCode))")
        }

        guard requestData.isEmpty == false else {
            throw ProxyError.message("OAuth 回调请求为空")
        }
        guard let request = String(data: requestData, encoding: .utf8) else {
            throw ProxyError.message("OAuth 回调请求不是有效的 UTF-8 文本")
        }
        let lines = request.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let requestLine = lines.first else {
            throw ProxyError.message("OAuth 回调请求为空")
        }

        let line = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw ProxyError.message("OAuth 回调请求缺少路径")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                break
            }
            guard let separator = trimmed.firstIndex(of: ":") else {
                continue
            }
            let name = trimmed[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty == false {
                headers[name] = value
            }
        }

        return IncomingRequest(
            method: String(parts[0]),
            target: String(parts[1]),
            headers: headers
        )
    }

    private func writeHTMLResponse(_ response: OAuthCallbackPageResponse, to clientFD: Int32) {
        let statusText = Self.httpStatusText(for: response.statusCode)
        let body = OAuthCallbackPageRenderer.renderHTML(response)
        let header = [
            "HTTP/1.1 \(response.statusCode) \(statusText)",
            "Content-Type: text/html; charset=utf-8",
            "Cache-Control: no-store",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        _ = POSIXCompat.sendAll(clientFD, data: Data((header + body).utf8))
    }

    private var isStopRequested: Bool {
        self.withStateLock { self.stopRequested }
    }

    private func closeSocketIfNeeded() {
        let shouldClose = self.withStateLock { () -> Bool in
            let shouldClose = !self.socketClosed
            self.socketClosed = true
            return shouldClose
        }

        guard shouldClose else { return }
        POSIXCompat.shutdownReadWrite(self.socketFD)
        POSIXCompat.closeDescriptor(self.socketFD)
    }

    private static func configureListeningSocket(_ fd: Int32) throws {
        guard POSIXCompat.setReuseAddress(fd) else {
            throw ProxyError.message("设置 OAuth 回调监听复用地址失败: \(self.socketErrorDescription())")
        }

        guard POSIXCompat.setNonBlocking(fd) else {
            throw ProxyError.message("设置 OAuth 回调监听非阻塞模式失败: \(self.socketErrorDescription())")
        }
    }

    private static func bindSocket(_ fd: Int32, port: Int) throws {
        guard POSIXCompat.bindLoopback(fd, port: port) else {
            throw ProxyError.message(self.socketErrorDescription())
        }
    }

    private static func listenSocket(_ fd: Int32) throws {
        guard POSIXCompat.listen(fd, backlog: 8) else {
            throw ProxyError.message("启动 OAuth 回调监听失败: \(self.socketErrorDescription())")
        }
    }

    private static func localPort(for fd: Int32) throws -> Int {
        guard let localPort = POSIXCompat.localPort(for: fd) else {
            throw ProxyError.message("读取 OAuth 回调监听端口失败: \(self.socketErrorDescription())")
        }
        return localPort
    }

    private static func socketErrorDescription(code: Int32 = errno) -> String {
        POSIXCompat.lastErrorMessage(code: code)
    }

    private static func httpStatusText(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        default:
            return "OK"
        }
    }

    private func currentWorkerTask() -> Task<Void, Never>? {
        self.withStateLock { self.workerTask }
    }

    private func takeWorkerTask() -> Task<Void, Never>? {
        self.withStateLock {
            let task = self.workerTask
            self.workerTask = nil
            return task
        }
    }

    private func setWorkerTask(_ task: Task<Void, Never>?) {
        self.withStateLock {
            self.workerTask = task
        }
    }

    private func clearWorkerTask() {
        self.withStateLock {
            self.workerTask = nil
        }
    }

    private func setStopRequested(_ value: Bool) {
        self.withStateLock {
            self.stopRequested = value
        }
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return body()
    }
}
