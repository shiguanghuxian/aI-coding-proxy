import CodexProxyCore
import Foundation
import Hummingbird
import HTTPTypes
import ServiceLifecycle

final class DaemonHTTPService: @unchecked Sendable {
    private struct GeminiRoute: Sendable {
        enum Operation: Sendable {
            case listModels
            case getModel
            case generateContent
            case streamGenerateContent
            case countTokens
        }

        var model: String?
        var operation: Operation
    }

    enum ListenerKind {
        case publicAPI
        case admin
    }

    struct Request: Sendable {
        var method: String
        var target: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        enum Body: Sendable {
            case bytes(Data)
            case stream(AsyncThrowingStream<Data, Error>)
        }

        var statusCode: Int
        var headers: [String: String]
        var body: Body
    }

    private let controller: DaemonController
    private let publicHost: String
    private let publicPort: Int
    private let adminPort: Int
    private let maxRequestBodyBytes = 64 * 1024 * 1024

    init(controller: DaemonController, publicHost: String, publicPort: Int, adminPort: Int) {
        self.controller = controller
        self.publicHost = publicHost
        self.publicPort = publicPort
        self.adminPort = adminPort
    }

    func publicApplication() -> any Service {
        self.makePublicApplication()
    }

    func adminApplication() -> any Service {
        self.makeAdminApplication()
    }

    func makePublicApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        self.registerPublicRoutes(on: router)
        return Application(
            router: router,
            configuration: .init(
                address: .hostname(self.publicHost, port: self.publicPort),
                serverName: RuntimeInfo.daemonServerToken
            )
        )
    }

    func makeAdminApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        self.registerAdminRoutes(on: router)
        return Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: self.adminPort),
                serverName: RuntimeInfo.daemonServerToken
            )
        )
    }

    func handle(_ request: Request, kind: ListenerKind) async -> Response {
        do {
            switch kind {
            case .publicAPI:
                return try await self.handlePublic(request)
            case .admin:
                return try await self.handleAdmin(request)
            }
        } catch {
            return self.jsonError(status: 500, message: error.localizedDescription, type: "server_error")
        }
    }

    private func registerPublicRoutes(on router: Router<BasicRequestContext>) {
        router.get("health") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.get("v1/models") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/chat/completions") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/responses") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/images/generations") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/images/edits") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/images/variations") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/messages") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/messages/count_tokens") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.get("v1/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.put("v1/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.patch("v1/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.delete("v1/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.get("v1beta/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.post("v1beta/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.put("v1beta/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.patch("v1beta/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
        router.delete("v1beta/**") { request, _ in
            try await self.respond(to: request, kind: .publicAPI)
        }
    }

    private func registerAdminRoutes(on router: Router<BasicRequestContext>) {
        router.get("callback") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.get("gemini/callback") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.get("auth/callback") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.get("admin/oauth/callback") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.get("admin/**") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.post("admin/**") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.put("admin/**") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.patch("admin/**") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
        router.delete("admin/**") { request, _ in
            try await self.respond(to: request, kind: .admin)
        }
    }

    private func respond(to request: Hummingbird.Request, kind: ListenerKind) async throws -> Hummingbird.Response {
        let converted = try await self.convert(request)
        let response = await self.handle(converted, kind: kind)
        return self.hummingbirdResponse(from: response)
    }

    private func convert(_ request: Hummingbird.Request) async throws -> Request {
        var request = request
        let buffer = try await request.collectBody(upTo: self.maxRequestBodyBytes)
        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.canonicalName] = field.value
        }
        return Request(
            method: request.method.rawValue.uppercased(),
            target: request.uri.description,
            path: request.uri.path,
            headers: headers,
            body: Data(buffer.readableBytesView)
        )
    }

    private func hummingbirdResponse(from response: Response) -> Hummingbird.Response {
        var headers = HTTPFields()
        for (name, value) in response.headers {
            if let fieldName = HTTPField.Name(name) {
                headers.append(.init(name: fieldName, value: value))
            }
        }

        switch response.body {
        case .bytes(let data):
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            return .init(
                status: .init(code: response.statusCode),
                headers: headers,
                body: .init(byteBuffer: buffer)
            )
        case .stream(let stream):
            let safeStream = Self.transportSafeStream(stream)
            return .init(
                status: .init(code: response.statusCode),
                headers: headers,
                body: .init { writer in
                    var writer = writer
                    var wroteAnyChunk = false
                    do {
                        for try await chunk in safeStream {
                            var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                            buffer.writeBytes(chunk)
                            try await writer.write(buffer)
                            wroteAnyChunk = true
                        }
                        try await writer.finish(nil)
                    } catch {
                        if wroteAnyChunk {
                            try? await writer.finish(nil)
                            return
                        }
                        throw error
                    }
                }
            )
        }
    }

    private func handlePublic(_ request: Request) async throws -> Response {
        if request.method == "GET", request.path == "/health" {
            let payload: [String: Any] = [
                "status": "ok",
                "service": "codex-proxyd",
                "version": RuntimeInfo.displayVersion,
                "public_base_url": "http://\(self.publicHost):\(self.publicPort)/v1",
                "anthropic_base_url": "http://\(self.publicHost):\(self.publicPort)",
                "gemini_base_url": "http://\(self.publicHost):\(self.publicPort)",
            ]
            return try self.jsonResponse(status: 200, object: payload)
        }

        if let geminiRoute = self.geminiRoute(from: request) {
            let apiKey = self.extractProxyKey(from: request, allowGeminiCompatibleKey: true)
            guard let apiKey else {
                return self.geminiError(
                    status: 401,
                    message: "Missing proxy api key.",
                    statusText: "UNAUTHENTICATED"
                )
            }

            let proxyKey: AuthenticatedProxyKeyContext
            do {
                proxyKey = try await self.controller.authenticateProxyAPIKey(apiKey)
            } catch {
                return self.geminiError(
                    status: 401,
                    message: error.localizedDescription,
                    statusText: "UNAUTHENTICATED"
                )
            }

            let selectedAccountKey = self.extractSelectedTestAccountKey(from: request.headers)
            do {
                switch (request.method, geminiRoute.operation) {
                case ("GET", .listModels):
                    return Response(
                        statusCode: 200,
                        headers: ["content-type": "application/json; charset=utf-8"],
                        body: .bytes(try await self.controller.geminiModelsResponse())
                    )
                case ("GET", .getModel):
                    guard let model = geminiRoute.model else {
                        return self.geminiError(
                            status: 404,
                            message: "Gemini model not found.",
                            statusText: "NOT_FOUND"
                        )
                    }
                    return Response(
                        statusCode: 200,
                        headers: ["content-type": "application/json; charset=utf-8"],
                        body: .bytes(try await self.controller.geminiModelResponse(model: model))
                    )
                case ("POST", .generateContent):
                    guard let model = geminiRoute.model else {
                        return self.geminiError(
                            status: 404,
                            message: "Gemini model not found.",
                            statusText: "NOT_FOUND"
                        )
                    }
                    let proxy = try await self.controller.proxyGeminiGenerateContent(
                        body: request.body,
                        proxyKey: proxyKey,
                        apiKeyValue: apiKey,
                        headers: request.headers,
                        selectedAccountKey: selectedAccountKey,
                        model: model,
                        downstreamStream: false
                    )
                    return self.fromProxyResponse(proxy)
                case ("POST", .streamGenerateContent):
                    guard let model = geminiRoute.model else {
                        return self.geminiError(
                            status: 404,
                            message: "Gemini model not found.",
                            statusText: "NOT_FOUND"
                        )
                    }
                    let proxy = try await self.controller.proxyGeminiGenerateContent(
                        body: request.body,
                        proxyKey: proxyKey,
                        apiKeyValue: apiKey,
                        headers: request.headers,
                        selectedAccountKey: selectedAccountKey,
                        model: model,
                        downstreamStream: true
                    )
                    return self.fromProxyResponse(proxy)
                case ("POST", .countTokens):
                    guard let model = geminiRoute.model else {
                        return self.geminiError(
                            status: 404,
                            message: "Gemini model not found.",
                            statusText: "NOT_FOUND"
                        )
                    }
                    let proxy = try await self.controller.countGeminiTokens(
                        body: request.body,
                        proxyKey: proxyKey,
                        apiKeyValue: apiKey,
                        headers: request.headers,
                        selectedAccountKey: selectedAccountKey,
                        model: model
                    )
                    return self.fromProxyResponse(proxy)
                default:
                    return self.geminiError(
                        status: 404,
                        message: "Unsupported Gemini-compatible endpoint \(request.path)",
                        statusText: "NOT_FOUND"
                    )
                }
            } catch {
                return self.geminiErrorResponse(for: error)
            }
        }

        guard request.path.hasPrefix("/v1") else {
            return self.jsonError(status: 404, message: "Unsupported path \(request.path)")
        }

        let apiKey = self.extractProxyKey(from: request.headers)
        guard let apiKey else {
            if request.path == "/v1/messages" || request.path == "/v1/messages/count_tokens" || request.path.hasPrefix("/v1/messages/") {
                return self.anthropicError(status: 401, message: "Missing proxy api key.", type: "authentication_error")
            }
            return self.jsonError(status: 401, message: "Missing proxy api key.", type: "authentication_error")
        }

        let proxyKey: AuthenticatedProxyKeyContext
        do {
            proxyKey = try await self.controller.authenticateProxyAPIKey(apiKey)
        } catch {
            if request.path == "/v1/messages" || request.path == "/v1/messages/count_tokens" || request.path.hasPrefix("/v1/messages/") {
                return self.anthropicError(status: 401, message: error.localizedDescription, type: "authentication_error")
            }
            return self.jsonError(status: 401, message: error.localizedDescription, type: "authentication_error")
        }

        if request.method == "GET", request.path == "/v1/models" {
            let selectedAccountKey = self.extractSelectedTestAccountKey(from: request.headers)
            return Response(
                statusCode: 200,
                headers: ["content-type": "application/json; charset=utf-8"],
                body: .bytes(
                    try await self.controller.modelsResponse(
                        proxyKey: proxyKey,
                        selectedAccountKey: selectedAccountKey
                    )
                )
            )
        }

        let selectedAccountKey = self.extractSelectedTestAccountKey(from: request.headers)

        if request.method == "POST", request.path == "/v1/chat/completions" {
            let proxy = try await self.controller.proxyChatCompletions(
                body: request.body,
                proxyKey: proxyKey,
                apiKeyValue: apiKey,
                headers: request.headers,
                selectedAccountKey: selectedAccountKey
            )
            return self.fromProxyResponse(proxy)
        }

        if request.method == "POST", request.path == "/v1/responses" {
            let proxy = try await self.controller.proxyResponses(
                body: request.body,
                proxyKey: proxyKey,
                apiKeyValue: apiKey,
                headers: request.headers,
                selectedAccountKey: selectedAccountKey
            )
            return self.fromProxyResponse(proxy)
        }

        if request.method == "POST", let imagesEndpoint = OpenAIImagesEndpoint(path: request.path) {
            let proxy = try await self.controller.proxyImages(
                body: request.body,
                endpoint: imagesEndpoint,
                proxyKey: proxyKey,
                apiKeyValue: apiKey,
                headers: request.headers,
                selectedAccountKey: selectedAccountKey
            )
            return self.fromProxyResponse(proxy)
        }

        if request.method == "POST", request.path == "/v1/messages" {
            do {
                let proxy = try await self.controller.proxyAnthropicMessages(
                    body: request.body,
                    proxyKey: proxyKey,
                    apiKeyValue: apiKey,
                    headers: request.headers,
                    selectedAccountKey: selectedAccountKey,
                    anthropicVersion: self.anthropicVersion(from: request.headers),
                    anthropicBeta: request.headers["anthropic-beta"]
                )
                return self.fromProxyResponse(proxy)
            } catch {
                return self.anthropicErrorResponse(for: error)
            }
        }

        if request.method == "POST", request.path == "/v1/messages/count_tokens" {
            do {
                let proxy = try await self.controller.countAnthropicTokens(
                    body: request.body,
                    proxyKey: proxyKey,
                    apiKeyValue: apiKey,
                    headers: request.headers,
                    selectedAccountKey: selectedAccountKey,
                    anthropicVersion: self.anthropicVersion(from: request.headers),
                    anthropicBeta: request.headers["anthropic-beta"]
                )
                return self.fromProxyResponse(proxy)
            } catch {
                return self.anthropicErrorResponse(for: error)
            }
        }

        if request.path.hasPrefix("/v1/messages/") {
            return self.anthropicError(
                status: 404,
                message: "Unsupported Anthropic-compatible endpoint \(request.path)",
                type: "not_found_error"
            )
        }

        return self.jsonError(status: 404, message: "Unsupported OpenAI-compatible endpoint \(request.path)")
    }

    private func handleAdmin(_ request: Request) async throws -> Response {
        if request.method == "GET", request.path == "/callback" {
            return try await self.handleOAuthCallback(request)
        }

        if request.method == "GET", request.path == "/gemini/callback" {
            return try await self.handleOAuthCallback(request)
        }

        if request.method == "GET", request.path == "/auth/callback" {
            return try await self.handleOAuthCallback(request)
        }

        if request.method == "GET", request.path == "/admin/oauth/callback" {
            return try await self.handleOAuthCallback(request)
        }

        guard let token = self.extractAdminToken(from: request.headers) else {
            return self.jsonError(status: 401, message: "Missing admin token.", type: "authentication_error")
        }

        do {
            try await self.controller.authenticateAdminToken(token)
        } catch {
            return self.jsonError(status: 401, message: error.localizedDescription, type: "authentication_error")
        }

        switch (request.method, request.path) {
        case ("GET", "/admin/status"):
            return try self.codableResponse(try await self.controller.status())
        case ("GET", "/admin/accounts"):
            return try self.codableResponse(try await self.controller.listAccounts())
        case ("POST", "/admin/accounts/manual-api-key"):
            let payload = try self.decode(ManualAPIKeyAccountInput.self, from: request.body)
            return try self.codableResponse(try await self.controller.manualAddAPIKeyAccount(payload))
        case ("POST", "/admin/accounts/import-current"):
            let payload = try self.decode(ImportCurrentPayload.self, from: request.body)
            return try self.codableResponse(try await self.controller.importCurrentAuth(label: payload.label))
        case ("POST", "/admin/accounts/import"):
            let items = try self.decode([AuthJsonImportInput].self, from: request.body)
            return try self.codableResponse(try await self.controller.importAuthJSONAccounts(items))
        case ("GET", "/admin/accounts/export"):
            return Response(
                statusCode: 200,
                headers: [
                    "content-type": "application/json; charset=utf-8",
                    "content-disposition": "attachment; filename=\"codex-proxy-accounts.json\"",
                ],
                body: .bytes(try await self.controller.exportAccounts())
            )
        case ("POST", "/admin/usage/refresh"):
            return try self.codableResponse(try await self.controller.refreshAllUsage())
        case ("GET", "/admin/settings"):
            return try self.codableResponse(try await self.controller.loadConfig())
        case ("PUT", "/admin/settings"):
            let config = try self.decode(AppConfig.self, from: request.body)
            return try self.codableResponse(try await self.controller.saveConfig(config))
        case ("GET", "/admin/proxy/subscription"):
            return try self.codableResponse(try await self.controller.managedProxySnapshot())
        case ("PUT", "/admin/proxy/subscription"):
            let payload = try self.decode(ManagedProxyConfigPayload.self, from: request.body)
            return try self.codableResponse(try await self.controller.saveManagedProxyConfig(payload))
        case ("PUT", "/admin/proxy/subscription/healthcheck-url"):
            let payload = try self.decode(ManagedProxyHealthcheckConfigPayload.self, from: request.body)
            return try self.codableResponse(try await self.controller.saveManagedProxyHealthcheckConfig(payload))
        case ("POST", "/admin/proxy/subscription/update"):
            return try self.codableResponse(try await self.controller.updateManagedProxySubscription())
        case ("POST", "/admin/proxy/subscription/select"):
            let payload = try self.decode(ManagedProxySelectRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.selectManagedProxyNode(name: payload.name))
        case ("POST", "/admin/proxy/subscription/current-node"):
            let payload = try self.decode(ManagedProxySwitchCurrentRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.switchManagedProxyCurrentNode(name: payload.name))
        case ("PATCH", "/admin/proxy/subscription/pinned-node"):
            let payload = try self.decode(ManagedProxyPinnedNodeRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.updateManagedProxyPinnedNode(name: payload.name))
        case ("POST", "/admin/proxy/subscription/healthcheck"):
            let payload = try self.decode(ManagedProxyHealthcheckRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.healthcheckManagedProxy(nodeName: payload.nodeName))
        case ("POST", "/admin/proxy/key/rotate"):
            return try self.codableResponse(try await self.controller.rotateProxyAPIKey())
        case ("POST", "/admin/oauth/prepare"):
            return try self.codableResponse(try await self.controller.prepareOAuthLogin(providerFamily: .openAI))
        case ("POST", "/admin/oauth/complete"):
            let payload = try self.decode(CompleteOAuthPayload.self, from: request.body)
            return try self.codableResponse(try await self.controller.completeOAuthCallback(providerFamily: .openAI, url: payload.callbackURL))
        case ("POST", "/admin/oauth/openai/prepare"):
            return try self.codableResponse(try await self.controller.prepareOAuthLogin(providerFamily: .openAI))
        case ("POST", "/admin/oauth/openai/complete"):
            let payload = try self.decode(CompleteOAuthPayload.self, from: request.body)
            return try self.codableResponse(try await self.controller.completeOAuthCallback(providerFamily: .openAI, url: payload.callbackURL))
        case ("POST", "/admin/oauth/anthropic/prepare"):
            return try self.codableResponse(try await self.controller.prepareOAuthLogin(providerFamily: .anthropic))
        case ("POST", "/admin/oauth/anthropic/complete"):
            let payload = try self.decode(CompleteOAuthPayload.self, from: request.body)
            return try self.codableResponse(try await self.controller.completeOAuthCallback(providerFamily: .anthropic, url: payload.callbackURL))
        case ("POST", "/admin/oauth/gemini/prepare"):
            return try self.codableResponse(try await self.controller.prepareOAuthLogin(providerFamily: .gemini))
        case ("POST", "/admin/oauth/gemini/complete"):
            let payload = try self.decode(CompleteOAuthPayload.self, from: request.body)
            return try self.codableResponse(try await self.controller.completeOAuthCallback(providerFamily: .gemini, url: payload.callbackURL))
        case ("GET", "/admin/proxy-test/models"):
            return try self.codableResponse(
                try await self.controller.proxyTestModelsCatalog(
                    selectedAccountKey: self.queryItems(from: request.target)["selected_account_key"]
                )
            )
        case ("POST", "/admin/proxy-test/run"):
            let payload = try self.decode(AdminProxyTestRunRequest.self, from: request.body)
            return self.fromProxyResponse(try await self.controller.adminProxyTestRun(payload))
        case ("GET", "/admin/stats/summary"):
            return try self.codableResponse(try await self.controller.statsSummary())
        case ("GET", "/admin/stats/api-key-usage"):
            return try self.codableResponse(try await self.controller.proxyAPIKeyUsage(query: self.requestLogQuery(from: request)))
        case ("GET", "/admin/stats/requests"):
            return try self.codableResponse(try await self.controller.requestLogs(query: self.requestLogQuery(from: request)))
        case ("GET", "/admin/stats/requests/export"):
            return Response(
                statusCode: 200,
                headers: [
                    "content-type": "text/csv; charset=utf-8",
                    "content-disposition": "attachment; filename=\"request-logs.csv\"",
                ],
                body: .bytes(try await self.controller.exportRequestLogs(query: self.requestLogQuery(from: request)))
            )
        case ("GET", "/admin/stats/request-filters"):
            return try self.codableResponse(try await self.controller.requestLogFilters(query: self.requestLogQuery(from: request)))
        case ("GET", "/admin/reasoning-cache/summary"):
            return try self.codableResponse(try await self.controller.reasoningCacheSummary())
        case ("POST", "/admin/reasoning-cache/clear"):
            let payload = try self.decode(ClearReasoningCacheRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.clearReasoningCache(payload))
        default:
            if let response = try await self.handleAccountManagementRoute(request) {
                return response
            }
            return self.jsonError(status: 404, message: "Unsupported admin endpoint \(request.path)")
        }
    }

    private func handleAccountManagementRoute(_ request: Request) async throws -> Response? {
        guard request.path.hasPrefix("/admin/accounts/") else {
            return nil
        }

        let components = request.path.split(separator: "/").map(String.init)
        guard components.count >= 3 else {
            return nil
        }

        if request.method == "PUT", components.count == 3, components[0] == "admin", components[1] == "accounts", components[2] == "order" {
            let payload = try self.decode(UpdateAccountOrderRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.reorderAccounts(ids: payload.orderedAccountIDs))
        }

        if request.method == "POST", components.count == 4, components[0] == "admin", components[1] == "accounts", components[2] == "managed-proxy-node", components[3] == "clear" {
            return try self.codableResponse(try await self.controller.clearAccountManagedProxyNodes())
        }

        if request.method == "PATCH", components.count == 4, components[0] == "admin", components[1] == "accounts", components[3] == "enabled" {
            let id = components[2].removingPercentEncoding ?? components[2]
            let payload = try self.decode(UpdateAccountEnabledRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.setAccountEnabled(id: id, enabled: payload.enabled))
        }

        if request.method == "PATCH", components.count == 4, components[0] == "admin", components[1] == "accounts", components[3] == "label" {
            let id = components[2].removingPercentEncoding ?? components[2]
            let payload = try self.decode(UpdateAccountLabelRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.updateAccountLabel(id: id, input: payload))
        }

        if request.method == "PATCH", components.count == 4, components[0] == "admin", components[1] == "accounts", components[3] == "managed-proxy-node" {
            let id = components[2].removingPercentEncoding ?? components[2]
            let payload = try self.decode(UpdateAccountManagedProxyNodeRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.updateAccountManagedProxyNode(id: id, input: payload))
        }

        if request.method == "PATCH", components.count == 4, components[0] == "admin", components[1] == "accounts", components[3] == "model-routing" {
            let id = components[2].removingPercentEncoding ?? components[2]
            let payload = try self.decode(UpdateAccountModelRoutingRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.updateAccountModelRouting(id: id, input: payload))
        }

        if request.method == "GET", components.count == 4, components[0] == "admin", components[1] == "accounts", components[3] == "manual-api-key" {
            let id = components[2].removingPercentEncoding ?? components[2]
            return try self.codableResponse(try await self.controller.manualAPIKeyAccountDetails(id: id))
        }

        if request.method == "PUT", components.count == 4, components[0] == "admin", components[1] == "accounts", components[3] == "manual-api-key" {
            let id = components[2].removingPercentEncoding ?? components[2]
            let payload = try self.decode(UpdateManualAPIKeyAccountRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.updateManualAPIKeyAccount(id: id, input: payload))
        }

        if request.method == "PATCH", components.count == 5, components[0] == "admin", components[1] == "accounts", components[3] == "cooldown", components[4] == "policy" {
            let id = components[2].removingPercentEncoding ?? components[2]
            let payload = try self.decode(UpdateAccountCooldownPolicyRequest.self, from: request.body)
            return try self.codableResponse(try await self.controller.updateAccountCooldownPolicy(id: id, input: payload))
        }

        if request.method == "POST", components.count == 5, components[0] == "admin", components[1] == "accounts", components[3] == "usage", components[4] == "refresh" {
            let id = components[2].removingPercentEncoding ?? components[2]
            return try self.codableResponse(try await self.controller.refreshAccountUsage(id: id))
        }

        if request.method == "POST", components.count == 5, components[0] == "admin", components[1] == "accounts", components[3] == "cooldown", components[4] == "stop" {
            let id = components[2].removingPercentEncoding ?? components[2]
            return try self.codableResponse(try await self.controller.stopAccountCooldown(id: id))
        }

        if request.method == "DELETE", components.count == 3, components[0] == "admin", components[1] == "accounts" {
            let id = components[2].removingPercentEncoding ?? components[2]
            return try self.codableResponse(try await self.controller.removeAccount(id: id))
        }

        return nil
    }

    private func handleOAuthCallback(_ request: Request) async throws -> Response {
        let fullURL = "http://localhost:\(self.adminPort)\(request.target)"
        let preferredLanguage = OAuthCallbackPageRenderer.preferredLanguage(
            fromAcceptLanguage: request.headers["accept-language"]
        )
        let page: OAuthCallbackPageResponse
        do {
            let account = try await self.controller.completeOAuthCallback(url: fullURL)
            page = OAuthCallbackPageRenderer.success(
                accountLabel: account.label,
                preferredLanguage: preferredLanguage
            )
        } catch {
            page = OAuthCallbackPageRenderer.failure(
                detail: error.localizedDescription,
                preferredLanguage: preferredLanguage
            )
        }

        return Response(
            statusCode: page.statusCode,
            headers: ["content-type": "text/html; charset=utf-8"],
            body: .bytes(Data(OAuthCallbackPageRenderer.renderHTML(page).utf8))
        )
    }

    private func fromProxyResponse(_ proxy: ProxyHTTPResponse) -> Response {
        switch proxy.body {
        case .bytes(let data):
            return Response(statusCode: proxy.statusCode, headers: proxy.headers, body: .bytes(data))
        case .stream(let stream):
            return Response(
                statusCode: proxy.statusCode,
                headers: proxy.headers,
                body: .stream(Self.transportSafeStream(stream))
            )
        }
    }

    static func transportSafeStream(
        _ stream: AsyncThrowingStream<Data, Error>
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var yieldedAnyChunk = false
                do {
                    for try await chunk in stream {
                        if chunk.isEmpty == false {
                            yieldedAnyChunk = true
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if yieldedAnyChunk {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func extractProxyKey(from headers: [String: String]) -> String? {
        if let apiKey = headers["x-api-key"], !apiKey.isEmpty {
            return apiKey
        }

        let bearerHeaders = [
            headers["proxy-authorization"],
            headers["authorization"],
        ]
        for header in bearerHeaders.compactMap({ $0 }) {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            if trimmed.lowercased().hasPrefix("bearer ") {
                return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
        return nil
    }

    private func extractProxyKey(from request: Request, allowGeminiCompatibleKey: Bool) -> String? {
        if allowGeminiCompatibleKey {
            if let apiKey = request.headers["x-goog-api-key"], !apiKey.isEmpty {
                return apiKey
            }
            if let apiKey = self.queryItems(from: request.target)["key"],
               !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return apiKey
            }
        }
        return self.extractProxyKey(from: request.headers)
    }

    private func extractSelectedTestAccountKey(from headers: [String: String]) -> String? {
        let selectedAccountKey = headers[ProxyHeaderName.testAccountKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selectedAccountKey.isEmpty ? nil : selectedAccountKey
    }

    private func extractAdminToken(from headers: [String: String]) -> String? {
        if let header = headers["authorization"], header.lowercased().hasPrefix("bearer ") {
            return String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        if let header = headers["x-admin-token"], !header.isEmpty {
            return header
        }
        return nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        if body.isEmpty {
            return try Helpers.readJSON(T.self, from: Data("{}".utf8))
        }
        return try Helpers.readJSON(T.self, from: body)
    }

    private func requestLogQuery(from request: Request) -> RequestLogQuery {
        let items = self.queryItems(from: request.target)
        let timePreset = RequestLogTimePreset(rawValue: items["time_preset"] ?? "") ?? .last24Hours
        let from = items["from"].flatMap(Int64.init)
        let to = items["to"].flatMap(Int64.init)
        let apiKey = items["api_key"]
        let accountKey = items["account_key"]
        let clientSource = items["client_source"].flatMap(RequestLogClientSource.init(rawValue:))
        let model = items["model"]
        let sortBy = RequestLogSortField(rawValue: items["sort_by"] ?? "") ?? .time
        let sortDirection = RequestLogSortDirection(rawValue: items["sort_direction"] ?? "") ?? .descending
        let page = items["page"].flatMap(Int.init) ?? 1
        let pageSize = items["page_size"].flatMap(Int.init) ?? 50
        return RequestLogQuery(
            timePreset: timePreset,
            from: from,
            to: to,
            apiKey: apiKey,
            accountKey: accountKey,
            clientSource: clientSource,
            model: model,
            sortBy: sortBy,
            sortDirection: sortDirection,
            page: page,
            pageSize: pageSize
        )
    }

    private func queryItems(from target: String) -> [String: String] {
        let urlString = target.hasPrefix("http") ? target : "http://localhost\(target)"
        guard let components = URLComponents(string: urlString) else {
            return [:]
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    private func codableResponse<T: Encodable>(_ value: T) throws -> Response {
        let data = try Helpers.encodeJSON(value, pretty: false)
        return Response(
            statusCode: 200,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: .bytes(data)
        )
    }

    private func jsonResponse(status: Int, object: [String: Any]) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: object)
        return Response(
            statusCode: status,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: .bytes(data)
        )
    }

    private func jsonError(status: Int, message: String, type: String = "invalid_request_error") -> Response {
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": type,
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)
        return Response(
            statusCode: status,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: .bytes(data)
        )
    }

    private func geminiError(status: Int, message: String, statusText: String) -> Response {
        let payload: [String: Any] = [
            "error": [
                "code": status,
                "message": message,
                "status": statusText,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)
        return Response(
            statusCode: status,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: .bytes(data)
        )
    }

    private func anthropicError(status: Int, message: String, type: String) -> Response {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": type,
                "message": message,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"type\":\"error\"}".utf8)
        return Response(
            statusCode: status,
            headers: [
                "content-type": "application/json; charset=utf-8",
                "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
            ],
            body: .bytes(data)
        )
    }

    private func anthropicErrorResponse(for error: Error) -> Response {
        let message = error.localizedDescription
        let lower = message.lowercased()

        if HTTPErrorClassifier.containsAuthSignal(message) || lower.contains("missing proxy api key") {
            return self.anthropicError(status: 401, message: message, type: "authentication_error")
        }
        if HTTPErrorClassifier.containsRateLimitSignal(message) {
            return self.anthropicError(status: 429, message: message, type: "rate_limit_error")
        }
        if HTTPErrorClassifier.containsQuotaSignal(message) || lower.contains("unsupported_country_region_territory") {
            return self.anthropicError(status: 403, message: message, type: "permission_error")
        }
        if lower.contains("unsupported anthropic")
            || lower.contains("missing `")
            || lower.contains("missing anthropic")
            || lower.contains("tool_choice")
            || lower.contains("$.")
        {
            return self.anthropicError(status: 400, message: message, type: "invalid_request_error")
        }
        return self.anthropicError(status: 500, message: message, type: "api_error")
    }

    private func geminiErrorResponse(for error: Error) -> Response {
        if let geminiError = error as? GeminiUpstreamError {
            return Response(
                statusCode: geminiError.httpStatus,
                headers: ["content-type": "application/json; charset=utf-8"],
                body: .bytes(geminiError.responseData)
            )
        }

        let message = error.localizedDescription
        let lower = message.lowercased()

        if HTTPErrorClassifier.containsAuthSignal(message) || lower.contains("missing proxy api key") {
            return self.geminiError(status: 401, message: message, statusText: "UNAUTHENTICATED")
        }
        if HTTPErrorClassifier.containsRateLimitSignal(message) {
            return self.geminiError(status: 429, message: message, statusText: "RESOURCE_EXHAUSTED")
        }
        if HTTPErrorClassifier.containsQuotaSignal(message) || lower.contains("unsupported_country_region_territory") {
            return self.geminiError(status: 403, message: message, statusText: "PERMISSION_DENIED")
        }
        if lower.contains("unsupported gemini")
            || lower.contains("official gemini cli sessions only")
            || lower.contains("google / gemini login")
            || lower.contains("missing `")
            || lower.contains("$.")
            || lower.contains("gemini request")
            || lower.contains("candidatecount")
        {
            return self.geminiError(status: 400, message: message, statusText: "INVALID_ARGUMENT")
        }
        return self.geminiError(status: 500, message: message, statusText: "INTERNAL")
    }

    private func geminiRoute(from request: Request) -> GeminiRoute? {
        let components = request.path.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            return nil
        }
        guard components[0] == "v1" || components[0] == "v1beta" else {
            return nil
        }
        guard components[1] == "models" else {
            return nil
        }

        if components.count == 2 {
            guard components[0] == "v1beta" || self.hasGeminiAuthHint(in: request) else {
                return nil
            }
            return GeminiRoute(model: nil, operation: .listModels)
        }

        guard components.count == 3 else {
            return nil
        }

        let rawValue = components[2].removingPercentEncoding ?? components[2]
        if let separator = rawValue.firstIndex(of: ":") {
            let model = String(rawValue[..<separator])
            let operation = String(rawValue[rawValue.index(after: separator)...])
            guard !model.isEmpty else { return nil }
            switch operation {
            case "generateContent":
                return GeminiRoute(model: model, operation: .generateContent)
            case "streamGenerateContent":
                return GeminiRoute(model: model, operation: .streamGenerateContent)
            case "countTokens":
                return GeminiRoute(model: model, operation: .countTokens)
            default:
                return nil
            }
        }

        return GeminiRoute(model: rawValue, operation: .getModel)
    }

    private func hasGeminiAuthHint(in request: Request) -> Bool {
        let googAPIKey = request.headers["x-goog-api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !googAPIKey.isEmpty {
            return true
        }
        let queryKey = self.queryItems(from: request.target)["key"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !queryKey.isEmpty
    }

    private func anthropicVersion(from headers: [String: String]) -> String {
        let version = headers["anthropic-version"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? AnthropicTranscoder.defaultAnthropicVersion : version
    }

    private struct ImportCurrentPayload: Codable {
        var label: String?
    }

    private struct CompleteOAuthPayload: Codable {
        var callbackURL: String
    }
}
