#if os(macOS)
import CodexProxyCore
import Foundation

struct AssistantFunctionCall: Sendable, Equatable {
    var name: String
    var argumentsJSON: String
}

struct AssistantModelReply: Sendable, Equatable {
    var message: String
    var functionCall: AssistantFunctionCall?
}

actor AssistantModelClient {
    struct Configuration: Sendable {
        var session: URLSession
        var baseURLProvider: @MainActor @Sendable () async throws -> URL
        var apiKeyProvider: @MainActor @Sendable () async throws -> String
        var modelProvider: @MainActor @Sendable () async -> String
        var accountKeyProvider: @MainActor @Sendable () async -> String?
        var timeoutSeconds: TimeInterval

        init(
            session: URLSession = .shared,
            baseURLProvider: @MainActor @Sendable @escaping () async throws -> URL,
            apiKeyProvider: @MainActor @Sendable @escaping () async throws -> String,
            modelProvider: @MainActor @Sendable @escaping () async -> String,
            accountKeyProvider: @MainActor @Sendable @escaping () async -> String?,
            timeoutSeconds: TimeInterval = 120
        ) {
            self.session = session
            self.baseURLProvider = baseURLProvider
            self.apiKeyProvider = apiKeyProvider
            self.modelProvider = modelProvider
            self.accountKeyProvider = accountKeyProvider
            self.timeoutSeconds = timeoutSeconds
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func reply(systemPrompt: String, messages: [AssistantConversationMessage]) async throws -> AssistantModelReply {
        let baseURL = try await configuration.baseURLProvider()
        let apiKey = try await configuration.apiKeyProvider()
        let model = await configuration.modelProvider()
        let accountKey = await configuration.accountKeyProvider()

        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let accountKey, !accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(accountKey, forHTTPHeaderField: ProxyHeaderName.testAccountKey)
        }

        var payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": Self.encodedMessages(systemPrompt: systemPrompt, messages: messages),
            "tools": Self.toolDefinitions(),
            "tool_choice": "auto",
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let (data, response) = try await configuration.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantModelError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AssistantModelError.httpFailure(statusCode: httpResponse.statusCode, body: text)
        }

        return try Self.parseResponse(from: data)
    }

    private static func encodedMessages(systemPrompt: String, messages: [AssistantConversationMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        result.append([
            "role": "system",
            "content": systemPrompt,
        ])
        for message in messages {
            result.append([
                "role": message.role.rawValue,
                "content": message.text,
            ])
        }
        return result
    }

    private static func toolDefinitions() -> [[String: Any]] {
        func tool(name: String, description: String, parameters: [String: Any]) -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": parameters,
                ] as [String: Any],
            ]
        }

        return [
            tool(
                name: "navigate_to_page",
                description: "Open a main page in the desktop app.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "page": [
                            "type": "string",
                            "enum": ["overview", "accounts", "proxy", "remote", "client_config", "settings", "help", "request_logs", "proxy_test"],
                        ],
                    ] as [String: Any],
                    "required": ["page"],
                ] as [String: Any]
            ),
            tool(
                name: "switch_interface_mode",
                description: "Switch between full and minimal interface mode.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "mode": [
                            "type": "string",
                            "enum": ["full", "minimal"],
                        ],
                    ] as [String: Any],
                    "required": ["mode"],
                ] as [String: Any]
            ),
            tool(
                name: "copy_endpoint",
                description: "Copy the primary OpenAI-compatible endpoint and show it to the user.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "copy_anthropic_endpoint",
                description: "Copy the Anthropic base URL and show it to the user.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "copy_api_key",
                description: "Copy the current primary local proxy API key.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "copy_claude_code_env",
                description: "Copy Claude Code environment snippet if available.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "copy_gemini_cli_env",
                description: "Copy Gemini CLI environment snippet.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "show_account_summary",
                description: "Show a concise account pool summary and navigate the user toward the next best action.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "start_manual_account_creation",
                description: "Open the manual API key account creation sheet.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "start_oauth_login",
                description: "Start an OAuth login flow for a provider family.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "provider": [
                            "type": "string",
                            "enum": ["openai", "anthropic", "gemini"],
                        ],
                    ] as [String: Any],
                    "required": ["provider"],
                ] as [String: Any]
            ),
            tool(
                name: "open_auth_import_sheet",
                description: "Open the import-authentication sheet.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "import_current_auth",
                description: "Import current local authentication into the account pool.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "export_accounts",
                description: "Export accounts to a JSON file.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "refresh_accounts",
                description: "Reload accounts and runtime status.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "refresh_usage",
                description: "Refresh usage information for accounts.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "start_local_service",
                description: "Start the local proxy daemon if it is currently stoppable or startable.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "stop_local_service",
                description: "Stop the local proxy daemon if it is currently running.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "set_account_enabled",
                description: "Enable or disable one account by id.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "account_id": ["type": "string"],
                        "enabled": ["type": "boolean"],
                    ] as [String: Any],
                    "required": ["account_id", "enabled"],
                ] as [String: Any]
            ),
            tool(
                name: "stop_account_cooldown",
                description: "Stop cooldown for a specific account.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "account_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["account_id"],
                ] as [String: Any]
            ),
            tool(
                name: "open_help_window",
                description: "Open the help/documentation window.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_request_logs",
                description: "Open the request logs window to view API request history.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_proxy_test_console",
                description: "Open the proxy test console to test API connections.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_managed_proxy_manager",
                description: "Open the managed proxy node manager window.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_client_config_manager",
                description: "Open the client configuration manager for Codex/Claude/Gemini CLI configs.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_codex_project_routes",
                description: "Open the Codex project routes configuration window.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "show_project_route_summary",
                description: "Show a summary of configured Codex and Claude Code project routes.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "create_project_route",
                description: "Create a Codex or Claude Code project route, save it, and write its project configuration.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "client": [
                            "type": "string",
                            "enum": ["codex", "claude_code"],
                        ],
                        "project_path": ["type": "string"],
                        "target_model": ["type": "string"],
                        "label": ["type": "string"],
                        "route_model": ["type": "string"],
                        "proxy_api_key_id": ["type": "string"],
                        "claude_settings_scope": [
                            "type": "string",
                            "enum": ["local", "shared"],
                        ],
                        "enabled": ["type": "boolean"],
                    ] as [String: Any],
                    "required": ["client", "project_path", "target_model"],
                ] as [String: Any]
            ),
            tool(
                name: "edit_project_route",
                description: "Edit an existing project route. Only provided fields are changed; project config is written only when write_project_config is true.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "route_id": ["type": "string"],
                        "client": [
                            "type": "string",
                            "enum": ["codex", "claude_code"],
                        ],
                        "project_path": ["type": "string"],
                        "target_model": ["type": "string"],
                        "label": ["type": "string"],
                        "route_model": ["type": "string"],
                        "proxy_api_key_id": ["type": "string"],
                        "claude_settings_scope": [
                            "type": "string",
                            "enum": ["local", "shared"],
                        ],
                        "enabled": ["type": "boolean"],
                        "write_project_config": ["type": "boolean"],
                    ] as [String: Any],
                    "required": ["route_id"],
                ] as [String: Any]
            ),
            tool(
                name: "apply_project_route_to_project",
                description: "Write an existing project route into its project config file.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "route_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["route_id"],
                ] as [String: Any]
            ),
            tool(
                name: "clear_project_route_from_project",
                description: "Remove project route settings from the project config file without deleting the route record.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "route_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["route_id"],
                ] as [String: Any]
            ),
            tool(
                name: "delete_project_route",
                description: "Delete an existing project route record. Project config is also cleared only when clear_project_config is true.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "route_id": ["type": "string"],
                        "clear_project_config": ["type": "boolean"],
                    ] as [String: Any],
                    "required": ["route_id"],
                ] as [String: Any]
            ),
            tool(
                name: "open_about_window",
                description: "Open the About window showing app version and credits.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "check_for_updates",
                description: "Check for application updates.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "toggle_account_cooldown_policy",
                description: "Toggle the automatic cooldown policy for a specific account.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "account_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["account_id"],
                ] as [String: Any]
            ),
            tool(
                name: "open_account_model_routing",
                description: "Open the model routing configuration for a specific account.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "account_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["account_id"],
                ] as [String: Any]
            ),
            tool(
                name: "open_account_reasoning_effort",
                description: "Open the reasoning effort configuration for a specific account.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "account_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["account_id"],
                ] as [String: Any]
            ),
            tool(
                name: "open_account_order_sheet",
                description: "Open the account ordering/priority configuration sheet.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "copy_gemini_endpoint",
                description: "Copy the Gemini base URL to clipboard.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "toggle_keep_awake",
                description: "Toggle the keep-awake mode that prevents the system from sleeping.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_remote_admin",
                description: "Navigate to the remote admin page or open the remote admin window.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_google_gemini_manual_key_sheet",
                description: "Open the manual Google Gemini API key entry sheet.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_ocr_model_manager",
                description: "Open the OCR model manager window.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "get_local_daemon_logs",
                description: "Load and display the local proxy daemon logs.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "import_json_files",
                description: "Import accounts from JSON files.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            tool(
                name: "open_account_edit_sheet",
                description: "Open the edit/configuration sheet for a specific account.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "account_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["account_id"],
                ] as [String: Any]
            ),
            tool(
                name: "open_rename_account_sheet",
                description: "Open the rename sheet for a specific account.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "account_id": ["type": "string"],
                    ] as [String: Any],
                    "required": ["account_id"],
                ] as [String: Any]
            ),
            tool(
                name: "toggle_batch_remove_mode",
                description: "Toggle the batch account removal mode in the accounts list.",
                parameters: [
                    "type": "object",
                    "properties": [:],
                    "required": [] as [String],
                ] as [String: Any]
            ),
        ]
    }

    private static func parseResponse(from data: Data) throws -> AssistantModelReply {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw AssistantModelError.invalidPayload
        }

        let content = (message["content"] as? String) ?? ""
        let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        var functionCall: AssistantFunctionCall?
        if let call = toolCalls.first,
           let function = call["function"] as? [String: Any],
           let name = function["name"] as? String
        {
            let arguments = function["arguments"] as? String ?? "{}"
            functionCall = AssistantFunctionCall(name: name, argumentsJSON: arguments)
        }

        return AssistantModelReply(message: content.trimmingCharacters(in: .whitespacesAndNewlines), functionCall: functionCall)
    }
}

struct AssistantConversationMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
        case tool
    }

    let id = UUID()
    var role: Role
    var text: String
}

enum AssistantModelError: Error, LocalizedError {
    case invalidResponse
    case httpFailure(statusCode: Int, body: String)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Assistant model request failed."
        case .httpFailure(let statusCode, let body):
            return "Assistant model returned HTTP \(statusCode). \(body)"
        case .invalidPayload:
            return "Assistant model returned an unexpected payload."
        }
    }
}
#endif
