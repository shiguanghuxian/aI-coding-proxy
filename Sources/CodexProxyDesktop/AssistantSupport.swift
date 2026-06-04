#if os(macOS)
import Combine
import CodexProxyCore
import Foundation
import SwiftUI
import CryptoKit

@MainActor
protocol AssistantWindowControlling: AnyObject {
    func showWindow()
    func closeWindow()
    func refreshWindow()
}

enum AssistantConversationRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct AssistantMessage: Identifiable, Equatable, Sendable {
    let id = UUID()
    var role: AssistantConversationRole
    var text: String
    var createdAt = Date()
}

enum AssistantQuickAction: String, CaseIterable, Identifiable, Sendable {
    case showAccessInfo
    case copyEndpoint
    case copyAPIKey
    case addManualAccount
    case startOpenAILogin
    case refreshAccounts

    var id: String { self.rawValue }
}

struct AssistantAccountOption: Identifiable, Equatable, Sendable {
    let id: String
    let accountKey: String
    let title: String
    let subtitle: String
}

private struct AssistantProjectRouteUpsertArguments {
    var routeID: String?
    var client: ProjectRouteClient?
    var projectPath: String?
    var targetModel: String?
    var label: String?
    var routeModel: String?
    var proxyAPIKeyID: String?
    var claudeSettingsScope: ClaudeProjectSettingsScope?
    var enabled: Bool?
    var writeProjectConfig: Bool
}

private struct AssistantProjectRouteDeleteArguments {
    var routeID: String
    var clearProjectConfig: Bool
}

@MainActor
final class AssistantChatService: ObservableObject {
    private var modelClient = AssistantModelClient(
        configuration: .init(
            baseURLProvider: { throw AssistantModelError.invalidResponse },
            apiKeyProvider: { throw AssistantModelError.invalidResponse },
            modelProvider: { "gpt-4o-mini" },
            accountKeyProvider: { nil }
        )
    )
    private var configuredModelClient = false
    struct SuccessMessage: Equatable {
        let title: String
        let detail: String?
    }

    private weak var model: DesktopAppModel?
    private var task: Task<Void, Never>?

    @Published var inputText = ""
    @Published var messages: [AssistantMessage] = []
    @Published var isRunning = false
    @Published var lastSuccess: SuccessMessage?

    init(model: DesktopAppModel) {
        self.model = model
    }

    var canSend: Bool {
        !self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.isRunning
    }

    func sendCurrentInput() {
        guard self.canSend, let model else { return }
        let trimmed = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.inputText = ""
        self.send(trimmed, model: model)
    }

    func send(_ text: String, model: DesktopAppModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.task?.cancel()
        self.messages.append(.init(role: .user, text: trimmed))
        self.task = Task { [weak self] in
            guard let self else { return }
            self.isRunning = true
            defer { self.isRunning = false }
            await self.handle(trimmed, model: model)
        }
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
    }

    func configureWelcomeIfNeeded() {
        guard self.messages.isEmpty else { return }
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                👋 你好！我是 AI 助手，通过对话帮你完成所有软件操作。

                你可以直接用自然语言告诉我你想做什么，我会结合当前环境直接执行。

                ━━━ 快速开始 ━━━

                💡 第一次使用？试试这些：
                • "查看当前状态" — 了解服务和账号概况
                • "帮我添加一个账号" — 引导你完成账号配置
                • "查看地址和 Key" — 获取客户端连接信息
                • "查看项目路由" — 查看 Codex / Claude Code 项目路由

                ━━━ 支持的操作 ━━━

                📋 账号管理
                • 查看/刷新账号池和用量
                • 添加账号：手动 Key、OpenAI/Anthropic/Gemini 登录
                • 导入导出账号、启用禁用、冷却管理
                • 编辑/重命名/排序/模型路由/推理强度

                🔗 代理与接入
                • 查看/复制 OpenAI、Anthropic、Gemini 地址和 Key
                • 复制 Claude Code / Gemini CLI 环境变量

                ⚙️ 服务控制
                • 查看状态 / 启动 / 停止服务
                • 查看服务日志

                📄 页面导航
                • 总览、账号、代理、远程管理、客户端配置、设置
                • 帮助、请求日志、代理测试控制台

                🔧 高级功能
                • 管理代理节点、客户端配置、项目路由
                • 创建/编辑/写入/清除/删除 Codex 与 Claude Code 项目路由
                • OCR 模型管理、防休眠、应用更新

                ━━━ 使用技巧 ━━━

                • 你可以用口语化表达，比如 "key 给我看看"、"服务起来了吗"
                • 操作会直接执行，需要确认的会先提示你
                • 如果不确定说什么，直接描述你的目标即可
                """
            )
        )
    }

    private func configureModelClientIfNeeded(model: DesktopAppModel) async {
        guard configuredModelClient == false else { return }
        modelClient = AssistantModelClient(
            configuration: .init(
                session: .shared,
                baseURLProvider: { [weak model] in
                    guard let model else { throw AssistantModelError.invalidResponse }
                    return try Self.endpointURL(from: model.openAICompatibleBaseURL)
                },
                apiKeyProvider: { [weak model] in
                    guard let model else { throw AssistantModelError.invalidResponse }
                    let key = model.localProxyAPIKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard key.isEmpty == false else { throw AssistantModelError.invalidResponse }
                    return key
                },
                modelProvider: { [weak model] in
                    model?.proxyTestDraft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? model!.proxyTestDraft.model
                        : ProxyTestDraft.defaultOpenAIModel
                },
                accountKeyProvider: {
                    nil
                }
            )
        )
        configuredModelClient = true
    }

    private func buildSystemPrompt(model: DesktopAppModel) -> String {
        let pages = model.visiblePages.map { page in
            "\(model.pageTitle(page)) [\(page.rawValue)]"
        }.joined(separator: "、")

        let available = self.availableAccountOptions(model: model)
        var accountsSummary = "无可用账号"
        if available.isEmpty == false {
            accountsSummary = available.prefix(12).map { option in
                "\(option.title) - \(option.subtitle)"
            }.joined(separator: "\n")
            if available.count > 12 {
                accountsSummary += "\n...共 \(available.count) 个可用账号"
            }
        }
        let projectRoutesSummary = self.projectRoutesPromptSummary(model: model)
        let projectRouteKeysSummary = self.projectRouteKeysPromptSummary(model: model)

        return """
        你是 AI Coding Proxy 桌面助手。你的目标是结合当前应用状态，优先给出最短可执行路径。尽量使用中文回答。

        约束：
        1. 优先调用提供的工具完成操作，而不是只给建议。
        2. 如果用户意图明确且工具可完成，直接调用工具。
        3. 如果缺少关键信息或存在风险，先询问或给出最安全的下一步。
        4. 回答保持简洁、结构清晰，必要时用项目符号。
        5. 不要编造当前环境状态。
        6. 输出格式优先使用 Markdown 标题、列表、粗体、行内代码和代码块；避免复杂 Markdown 表格，结构化信息优先用列表展示。

        当前可见页面：\(pages)
        当前服务状态：\(model.localServicePrimaryStatusText)（\(model.localServiceSummaryText)）
        OpenAI Base URL：\(model.openAICompatibleBaseURL)
        Anthropic Base URL：\(model.anthropicBaseURL)
        Gemini Base URL：\(model.geminiBaseURL)
        当前本地 API Key：\(model.localProxyAPIKeyValue)
        可用账号池摘要：
        \(accountsSummary)
        当前项目路由摘要：
        \(projectRoutesSummary)
        可用于项目路由的本地 Key：
        \(projectRouteKeysSummary)

        你支持的全部功能包括：

        1) 账号管理
        - 查看/列出/刷新账号池和用量
        - 添加账号：手动 API Key、OpenAI/Anthropic/Gemini OAuth 登录、Google Gemini 手动 Key
        - 导入账号：JSON 文件导入、当前认证导入、粘贴 JSON
        - 导出账号到 JSON 文件
        - 启用/禁用账号、结束冷却、切换自动冷却策略
        - 编辑账号、重命名账号、配置排序优先级
        - 配置账号模型路由、推理强度

        2) 代理地址与 API Key
        - 查看/复制 OpenAI、Anthropic、Gemini 根地址
        - 查看/复制本地 API Key
        - 复制 Claude Code 环境变量、Gemini CLI 环境变量

        3) 服务控制
        - 查看服务状态、启动/停止本地代理服务
        - 查看本地服务日志

        4) 页面导航
        - 打开总览、账号页、代理页、远程管理、客户端配置、设置页
        - 打开帮助、请求日志、代理测试控制台

        5) 高级功能
        - 管理代理节点、健康检查
        - 客户端配置管理器（Codex/Claude Code/Gemini CLI 配置）
        - Codex / Claude Code 项目路由配置：查看、新建、编辑、写入项目配置、清除项目配置、删除
        - OCR 模型管理
        - 远程管理
        - 防休眠模式切换
        - 应用更新检查

        6) 界面与模式
        - 切换完整/精简界面模式
        - 批量删除模式
        - 打开关于窗口

        项目路由指令：
        - 用户想“让某个项目走某个模型/某个本地 Key”、“配置 Codex 项目路由”、“配置 Claude Code 项目路由”、“写入/清除/删除项目路由”时，优先调用项目路由工具。
        - 如果用户没有指定本地 Key，创建项目路由时可以使用默认可用本地 Key。
        - 删除项目路由默认只删应用内记录；只有用户明确要求同时清理项目配置时，才设置 clear_project_config=true。
        """
    }

    private func buildConversationMessages(excludingLastUser lastUserText: String) -> [AssistantConversationMessage] {
        var messages: [AssistantConversationMessage] = []
        for message in self.messages.suffix(20) {
            switch message.role {
            case .user:
                messages.append(.init(role: .user, text: message.text))
            case .assistant:
                messages.append(.init(role: .assistant, text: message.text))
            case .system:
                messages.append(.init(role: .user, text: "[系统消息] \(message.text)"))
            }
        }
        return messages
    }

    private func executeFunctionCall(_ functionCall: AssistantFunctionCall, model: DesktopAppModel) async {
        switch functionCall.name {
        case "navigate_to_page":
            if let page = Self.pageArgument(from: functionCall.argumentsJSON) {
                self.openPage(page, model: model)
            } else {
                self.messages.append(.init(role: .assistant, text: "我没有拿到有效的页面参数，已保持在当前页面。"))
            }
        case "switch_interface_mode":
            if let mode = Self.interfaceModeArgument(from: functionCall.argumentsJSON) {
                self.switchMode(mode, model: model)
            } else {
                self.messages.append(.init(role: .assistant, text: "切换模式缺少参数，我已经保持当前模式不变。"))
            }
        case "copy_endpoint":
            self.copyEndpointText(model: model)
        case "copy_anthropic_endpoint":
            model.copyAnthropicBaseURL()
            self.messages.append(.init(role: .assistant, text: "已复制 Anthropic 根地址：\(model.anthropicBaseURL)"))
            self.lastSuccess = .init(title: "已复制 Anthropic 地址", detail: model.anthropicBaseURL)
        case "copy_api_key":
            self.copyKeyText(model: model)
        case "copy_claude_code_env":
            self.showClaudeCodeSnippet(model: model)
        case "copy_gemini_cli_env":
            self.showGeminiCLISnippet(model: model)
        case "show_account_summary":
            await self.showAccountSummary(model: model)
        case "start_manual_account_creation":
            self.beginManualAccountCreation(model: model)
        case "start_oauth_login":
            if let provider = Self.providerFamilyArgument(from: functionCall.argumentsJSON) {
                switch provider {
                case .openAI:
                    self.beginOpenAILogin(model: model)
                case .anthropic:
                    self.beginAnthropicLogin(model: model)
                case .gemini:
                    self.beginGeminiLogin(model: model)
                }
            } else {
                self.messages.append(.init(role: .assistant, text: "登录参数不完整，我需要 openai / anthropic / gemini 其中之一。"))
            }
        case "open_auth_import_sheet":
            self.beginImportAccounts(model: model)
        case "import_current_auth":
            await self.importCurrentAuth(model: model)
        case "export_accounts":
            await self.exportAccounts(model: model)
        case "refresh_accounts":
            await self.refreshAccounts(model: model)
        case "refresh_usage":
            await self.refreshUsage(model: model)
        case "start_local_service":
            await self.startDaemon(model: model)
        case "stop_local_service":
            await self.stopDaemon(model: model)
        case "set_account_enabled":
            if let request = Self.setAccountEnabledArguments(from: functionCall.argumentsJSON),
               let account = model.accounts.first(where: { $0.id == request.accountID })
            {
                await self.setAccountEnabled(account: account, enabled: request.enabled, model: model)
            } else {
                self.messages.append(.init(role: .assistant, text: "我没能根据参数找到目标账号，无法直接切换启用状态。"))
            }
        case "stop_account_cooldown":
            if let accountID = Self.accountIDArgument(from: functionCall.argumentsJSON),
               let account = model.accounts.first(where: { $0.id == accountID })
            {
                await self.stopAccountCooldown(account: account, model: model)
            } else {
                self.messages.append(.init(role: .assistant, text: "我没能根据参数找到目标账号，无法直接结束冷却。"))
            }
        case "open_help_window":
            self.openHelpWindow(model: model)
        case "open_request_logs":
            self.openRequestLogs(model: model)
        case "open_proxy_test_console":
            self.openProxyTest(model: model)
        case "open_managed_proxy_manager":
            model.openManagedProxyManagerWindow()
            self.messages.append(.init(role: .assistant, text: "已打开管理代理节点管理窗口。"))
            self.lastSuccess = .init(title: "已打开管理代理管理", detail: nil)
        case "open_client_config_manager":
            model.openClientConfigManagerWindow()
            self.messages.append(.init(role: .assistant, text: "已打开客户端配置管理器。你可以在其中管理 Codex、Claude Code、Gemini CLI 等客户端的配置文件。"))
            self.lastSuccess = .init(title: "已打开客户端配置管理", detail: nil)
        case "open_codex_project_routes":
            model.openCodexProjectRoutesWindow()
            self.messages.append(.init(role: .assistant, text: "已打开 Codex 项目路由配置窗口。"))
            self.lastSuccess = .init(title: "已打开项目路由", detail: nil)
        case "show_project_route_summary":
            self.showProjectRouteSummary(model: model)
        case "create_project_route":
            await self.createProjectRoute(argumentsJSON: functionCall.argumentsJSON, model: model)
        case "edit_project_route":
            await self.editProjectRoute(argumentsJSON: functionCall.argumentsJSON, model: model)
        case "apply_project_route_to_project":
            await self.applyProjectRoute(argumentsJSON: functionCall.argumentsJSON, model: model)
        case "clear_project_route_from_project":
            await self.clearProjectRoute(argumentsJSON: functionCall.argumentsJSON, model: model)
        case "delete_project_route":
            await self.deleteProjectRoute(argumentsJSON: functionCall.argumentsJSON, model: model)
        case "open_about_window":
            model.openAboutWindow()
            self.messages.append(.init(role: .assistant, text: "已打开关于窗口，你可以在其中查看版本信息和开发者信息。"))
            self.lastSuccess = .init(title: "已打开关于窗口", detail: nil)
        case "check_for_updates":
            model.checkForAppUpdates(isAutomatic: false)
            self.messages.append(.init(role: .assistant, text: "已触发应用更新检查。如果有新版本，系统会自动提示你。"))
            self.lastSuccess = .init(title: "已检查更新", detail: nil)
        case "toggle_account_cooldown_policy":
            if let accountID = Self.accountIDArgument(from: functionCall.argumentsJSON),
               let account = model.accounts.first(where: { $0.id == accountID })
            {
                await model.toggleAccountCooldownPolicy(account)
                await model.loadAll()
                let statusText = model.accountRuntimeStatusText(account)
                self.messages.append(.init(role: .assistant, text: "已切换账号 \(account.label) 的自动冷却策略。当前状态：\(statusText)"))
                self.lastSuccess = .init(title: "已切换冷却策略", detail: account.label)
            } else {
                self.messages.append(.init(role: .assistant, text: "未能找到目标账号，无法切换冷却策略。"))
            }
        case "open_account_model_routing":
            if let accountID = Self.accountIDArgument(from: functionCall.argumentsJSON),
               let account = model.accounts.first(where: { $0.id == accountID })
            {
                model.openAccountModelRoutingSheet(account)
                self.messages.append(.init(role: .assistant, text: "已打开账号 \(account.label) 的模型路由配置。"))
                self.lastSuccess = .init(title: "已打开模型路由", detail: account.label)
            } else {
                self.messages.append(.init(role: .assistant, text: "未能找到目标账号，无法打开模型路由配置。"))
            }
        case "open_account_reasoning_effort":
            if let accountID = Self.accountIDArgument(from: functionCall.argumentsJSON),
               let account = model.accounts.first(where: { $0.id == accountID })
            {
                model.openAccountReasoningEffortSheet(account)
                self.messages.append(.init(role: .assistant, text: "已打开账号 \(account.label) 的推理强度配置。"))
                self.lastSuccess = .init(title: "已打开推理强度配置", detail: account.label)
            } else {
                self.messages.append(.init(role: .assistant, text: "未能找到目标账号，无法打开推理强度配置。"))
            }
        case "open_account_order_sheet":
            model.presentAccountOrderSheet()
            self.messages.append(.init(role: .assistant, text: "已打开账号排序配置。你可以拖拽调整账号的优先级顺序。"))
            self.lastSuccess = .init(title: "已打开账号排序", detail: nil)
        case "copy_gemini_endpoint":
            model.copyGeminiBaseURL()
            self.messages.append(.init(role: .assistant, text: "已复制 Gemini 根地址：\(model.geminiBaseURL)"))
            self.lastSuccess = .init(title: "已复制 Gemini 地址", detail: model.geminiBaseURL)
        case "toggle_keep_awake":
            model.toggleKeepAwake()
            let title = model.keepAwakeActionTitle
            self.messages.append(.init(role: .assistant, text: "已切换防休眠模式。当前操作：\(title)"))
            self.lastSuccess = .init(title: "已切换防休眠", detail: nil)
        case "open_remote_admin":
            if model.canOpenPage(.remote) {
                model.openDashboard(.remote)
                self.messages.append(.init(role: .assistant, text: "已打开远程管理页面。"))
                self.lastSuccess = .init(title: "已打开远程管理", detail: nil)
            } else {
                model.openSelectedRemoteAdminWindow()
                self.messages.append(.init(role: .assistant, text: "远程管理页面暂不可用，已尝试打开远程管理窗口。"))
            }
        case "open_google_gemini_manual_key_sheet":
            model.presentGoogleGeminiManualAPIKeySheet()
            self.messages.append(.init(role: .assistant, text: "已打开 Google Gemini 手动添加 API Key 入口。"))
            self.lastSuccess = .init(title: "已打开 Gemini Key 添加", detail: nil)
        case "open_ocr_model_manager":
            model.openOCRModelManagerWindow()
            self.messages.append(.init(role: .assistant, text: "已打开 OCR 模型管理窗口。"))
            self.lastSuccess = .init(title: "已打开 OCR 模型管理", detail: nil)
        case "get_local_daemon_logs":
            await model.loadLocalDaemonLogs()
            self.messages.append(.init(role: .assistant, text: "已加载本地服务日志。你可以在主窗口的日志区域查看详细输出。"))
            self.lastSuccess = .init(title: "已加载服务日志", detail: nil)
        case "import_json_files":
            await model.importJSONFiles()
            await model.loadAll()
            let available = self.availableAccountOptions(model: model)
            self.messages.append(.init(role: .assistant, text: "已从 JSON 文件导入账号。当前可用账号数：\(available.count)"))
            self.lastSuccess = .init(title: "已导入 JSON 文件", detail: "可用账号数：\(available.count)")
        case "open_account_edit_sheet":
            if let accountID = Self.accountIDArgument(from: functionCall.argumentsJSON),
               let account = model.accounts.first(where: { $0.id == accountID })
            {
                await model.openEditAPIKeyAccountSheet(account)
                self.messages.append(.init(role: .assistant, text: "已打开账号 \(account.label) 的编辑页面。"))
                self.lastSuccess = .init(title: "已打开编辑页面", detail: account.label)
            } else {
                self.messages.append(.init(role: .assistant, text: "未能找到目标账号，无法打开编辑页面。"))
            }
        case "open_rename_account_sheet":
            if let accountID = Self.accountIDArgument(from: functionCall.argumentsJSON),
               let account = model.accounts.first(where: { $0.id == accountID })
            {
                model.openRenameAccountSheet(account)
                self.messages.append(.init(role: .assistant, text: "已打开账号 \(account.label) 的重命名入口。"))
                self.lastSuccess = .init(title: "已打开重命名", detail: account.label)
            } else {
                self.messages.append(.init(role: .assistant, text: "未能找到目标账号，无法打开重命名入口。"))
            }
        case "toggle_batch_remove_mode":
            model.toggleAccountBatchRemoveMode()
            self.messages.append(.init(role: .assistant, text: "已切换批量删除模式。你可以在账号页面选择多个账号进行批量操作。"))
            self.lastSuccess = .init(title: "已切换批量删除模式", detail: nil)
        default:
            self.messages.append(.init(role: .assistant, text: "大模型返回了一个我暂时不支持的操作，我已改为给你下一步建议。"))
            await self.respondGeneral(functionCall.name, model: model)
        }
    }

    private static func endpointURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw AssistantModelError.invalidPayload
        }
        return url
    }

    private static func pageArgument(from json: String) -> DesktopAppModel.Page? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["page"] as? String
        else {
            return nil
        }

        switch raw {
        case "overview": return .overview
        case "accounts": return .accounts
        case "proxy": return .proxy
        case "remote": return .remote
        case "client_config": return .clientConfig
        case "settings": return .settings
        case "help": return nil
        case "request_logs": return nil
        case "proxy_test": return nil
        default: return nil
        }
    }

    private static func interfaceModeArgument(from json: String) -> DesktopInterfaceMode? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["mode"] as? String
        else {
            return nil
        }

        switch raw {
        case "full": return .full
        case "minimal": return .minimal
        default: return nil
        }
    }

    private static func providerFamilyArgument(from json: String) -> AccountProviderFamily? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["provider"] as? String
        else {
            return nil
        }

        switch raw {
        case "openai": return .openAI
        case "anthropic": return .anthropic
        case "gemini": return .gemini
        default: return nil
        }
    }

    private static func setAccountEnabledArguments(from json: String) -> (accountID: String, enabled: Bool)? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountID = object["account_id"] as? String,
              let enabled = object["enabled"] as? Bool
        else {
            return nil
        }
        return (accountID, enabled)
    }

    private static func accountIDArgument(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountID = object["account_id"] as? String
        else {
            return nil
        }
        return accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func projectRouteUpsertArguments(from json: String, requiresRouteID: Bool) -> AssistantProjectRouteUpsertArguments? {
        guard let object = Self.jsonObject(from: json) else { return nil }
        let routeID = Self.stringValue(object["route_id"])
        if requiresRouteID, routeID == nil {
            return nil
        }

        return AssistantProjectRouteUpsertArguments(
            routeID: routeID,
            client: Self.projectRouteClient(from: Self.stringValue(object["client"])),
            projectPath: Self.stringValue(object["project_path"]),
            targetModel: Self.stringValue(object["target_model"]),
            label: Self.stringValue(object["label"]),
            routeModel: Self.stringValue(object["route_model"]),
            proxyAPIKeyID: Self.stringValue(object["proxy_api_key_id"]),
            claudeSettingsScope: Self.claudeProjectSettingsScope(from: Self.stringValue(object["claude_settings_scope"])),
            enabled: object["enabled"] as? Bool,
            writeProjectConfig: object["write_project_config"] as? Bool ?? false
        )
    }

    private static func projectRouteIDArgument(from json: String) -> String? {
        guard let object = Self.jsonObject(from: json) else { return nil }
        return Self.stringValue(object["route_id"])
    }

    private static func projectRouteDeleteArguments(from json: String) -> AssistantProjectRouteDeleteArguments? {
        guard let object = Self.jsonObject(from: json),
              let routeID = Self.stringValue(object["route_id"])
        else {
            return nil
        }
        return AssistantProjectRouteDeleteArguments(
            routeID: routeID,
            clearProjectConfig: object["clear_project_config"] as? Bool ?? false
        )
    }

    private static func projectRouteClient(from raw: String?) -> ProjectRouteClient? {
        switch raw?.lowercased() {
        case "codex":
            return .codex
        case "claude_code", "claudecode", "claude-code", "claude":
            return .claudeCode
        default:
            return nil
        }
    }

    private static func claudeProjectSettingsScope(from raw: String?) -> ClaudeProjectSettingsScope? {
        switch raw?.lowercased() {
        case "local", "settings.local", "settings.local.json":
            return .local
        case "shared", "settings", "settings.json":
            return .shared
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func showProjectRouteSummary(model: DesktopAppModel) {
        let routes = model.codexProjectRouteRules
        guard routes.isEmpty == false else {
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    当前还没有项目路由。

                    你可以这样告诉我：
                    • 给 /path/to/project 创建 Codex 项目路由，目标模型 gpt-5
                    • 给 /path/to/project 创建 Claude Code 项目路由，目标模型 claude-sonnet-4-5
                    """
                )
            )
            return
        }

        let enabledCount = routes.filter(\.enabled).count
        var text = "当前项目路由概况：\n"
        text += "\n• 总路由数：\(routes.count)"
        text += "\n• 启用路由数：\(enabledCount)"
        text += "\n\n路由列表："
        for route in routes.prefix(12) {
            text += "\n\(self.projectRouteSummaryLine(route, model: model, includeID: true))"
        }
        if routes.count > 12 {
            text += "\n...共 \(routes.count) 条项目路由"
        }
        self.messages.append(.init(role: .assistant, text: text))
    }

    private func createProjectRoute(argumentsJSON: String, model: DesktopAppModel) async {
        guard let request = Self.projectRouteUpsertArguments(from: argumentsJSON, requiresRouteID: false),
              let client = request.client,
              let rawProjectPath = request.projectPath,
              let targetModel = request.targetModel
        else {
            self.messages.append(.init(role: .assistant, text: "创建项目路由需要 client、project_path 和 target_model。"))
            return
        }

        let projectPath = CodexProjectRouteRule.normalizedProjectPath(rawProjectPath)
        guard projectPath.hasPrefix("/") else {
            self.messages.append(.init(role: .assistant, text: "项目路由需要有效的绝对项目路径。"))
            return
        }

        guard let proxyAPIKeyID = self.resolveProjectRouteProxyAPIKeyID(request.proxyAPIKeyID, model: model) else {
            self.messages.append(.init(role: .assistant, text: "当前没有可用于项目路由的本地 Key，请先创建或启用一个本地 API Key。"))
            return
        }

        let label = request.label ?? URL(fileURLWithPath: projectPath).lastPathComponent
        let routeModel = request.routeModel ?? CodexProjectRouteRule.generatedRouteModel(
            label: label,
            projectPath: projectPath,
            client: client
        )
        guard self.hasDuplicateProjectRoute(client: client, routeModel: routeModel, excludingID: nil, model: model) == false else {
            self.messages.append(.init(role: .assistant, text: "已存在相同客户端和路由模型的项目路由：\(routeModel)。"))
            return
        }

        let rule = CodexProjectRouteRule(
            client: client,
            claudeSettingsScope: request.claudeSettingsScope ?? .local,
            label: label,
            projectPath: projectPath,
            routeModel: routeModel,
            targetModel: targetModel,
            proxyAPIKeyID: proxyAPIKeyID,
            enabled: request.enabled ?? true
        )
        guard rule.isComplete else {
            self.messages.append(.init(role: .assistant, text: "项目路由参数不完整，请补充项目路径、路由模型、目标模型和本地 Key。"))
            return
        }

        let saved = await self.saveProjectRoute(rule, replacingID: nil, model: model)
        guard saved else {
            self.messages.append(.init(role: .assistant, text: "项目路由保存失败，已保持当前配置不变。"))
            return
        }

        let wrote = await self.writeProjectRouteConfiguration(rule, model: model)
        self.messages.append(
            .init(
                role: .assistant,
                text: wrote
                    ? "已创建并写入项目路由：\n\(self.projectRouteSummaryLine(rule, model: model, includeID: true))"
                    : "项目路由已保存，但写入项目配置失败。请检查项目目录权限后重试。\n\(self.projectRouteSummaryLine(rule, model: model, includeID: true))"
            )
        )
        self.lastSuccess = .init(title: "已创建项目路由", detail: label)
    }

    private func editProjectRoute(argumentsJSON: String, model: DesktopAppModel) async {
        guard let request = Self.projectRouteUpsertArguments(from: argumentsJSON, requiresRouteID: true),
              let routeID = request.routeID,
              let existing = self.findProjectRoute(routeID: routeID, model: model)
        else {
            self.messages.append(.init(role: .assistant, text: "未能找到要编辑的项目路由。你可以先说“查看项目路由”获取 route_id。"))
            return
        }

        let client = request.client ?? existing.client
        let projectPath = CodexProjectRouteRule.normalizedProjectPath(request.projectPath ?? existing.projectPath)
        guard projectPath.hasPrefix("/") else {
            self.messages.append(.init(role: .assistant, text: "项目路由需要有效的绝对项目路径。"))
            return
        }

        let proxyAPIKeyID = request.proxyAPIKeyID ?? existing.proxyAPIKeyID
        guard self.projectRouteProxyAPIKeyExists(proxyAPIKeyID, model: model) else {
            self.messages.append(.init(role: .assistant, text: "指定的本地 Key 不存在或不可用，无法保存项目路由。"))
            return
        }

        let updated = CodexProjectRouteRule(
            id: existing.id,
            client: client,
            claudeSettingsScope: request.claudeSettingsScope ?? existing.claudeSettingsScope,
            label: request.label ?? existing.label,
            projectPath: projectPath,
            routeModel: request.routeModel ?? existing.routeModel,
            targetModel: request.targetModel ?? existing.targetModel,
            proxyAPIKeyID: proxyAPIKeyID,
            enabled: request.enabled ?? existing.enabled,
            createdAt: existing.createdAt
        )
        guard updated.isComplete else {
            self.messages.append(.init(role: .assistant, text: "项目路由参数不完整，请补充项目路径、路由模型、目标模型和本地 Key。"))
            return
        }
        guard self.hasDuplicateProjectRoute(client: updated.client, routeModel: updated.routeModel, excludingID: updated.id, model: model) == false else {
            self.messages.append(.init(role: .assistant, text: "已存在相同客户端和路由模型的其他项目路由：\(updated.routeModel)。"))
            return
        }

        let saved = await self.saveProjectRoute(updated, replacingID: existing.id, model: model)
        guard saved else {
            self.messages.append(.init(role: .assistant, text: "项目路由保存失败，已保持当前配置不变。"))
            return
        }

        var detail = "已更新项目路由：\n\(self.projectRouteSummaryLine(updated, model: model, includeID: true))"
        if request.writeProjectConfig {
            let wrote = await self.writeProjectRouteConfiguration(updated, model: model)
            detail += wrote ? "\n\n已同步写入项目配置。" : "\n\n保存成功，但写入项目配置失败。"
        }
        self.messages.append(.init(role: .assistant, text: detail))
        self.lastSuccess = .init(title: "已更新项目路由", detail: self.projectRouteDisplayName(updated))
    }

    private func applyProjectRoute(argumentsJSON: String, model: DesktopAppModel) async {
        guard let routeID = Self.projectRouteIDArgument(from: argumentsJSON),
              let rule = self.findProjectRoute(routeID: routeID, model: model)
        else {
            self.messages.append(.init(role: .assistant, text: "未能找到要写入的项目路由。你可以先说“查看项目路由”获取 route_id。"))
            return
        }

        let wrote = await self.writeProjectRouteConfiguration(rule, model: model)
        self.messages.append(
            .init(
                role: .assistant,
                text: wrote
                    ? "已写入项目配置：\(self.projectRouteWriteDetail(rule, model: model))"
                    : "写入项目配置失败，请检查项目目录权限或配置文件状态。"
            )
        )
        if wrote {
            self.lastSuccess = .init(title: "已写入项目配置", detail: self.projectRouteDisplayName(rule))
        }
    }

    private func clearProjectRoute(argumentsJSON: String, model: DesktopAppModel) async {
        guard let routeID = Self.projectRouteIDArgument(from: argumentsJSON),
              let rule = self.findProjectRoute(routeID: routeID, model: model)
        else {
            self.messages.append(.init(role: .assistant, text: "未能找到要清除项目配置的项目路由。你可以先说“查看项目路由”获取 route_id。"))
            return
        }

        let cleared = await self.clearProjectRouteConfiguration(rule, model: model)
        self.messages.append(
            .init(
                role: .assistant,
                text: cleared
                    ? "已从项目配置中清除路由设置，但保留应用内项目路由记录：\(self.projectRouteDisplayName(rule))"
                    : "清除项目配置失败，请检查项目目录权限或配置文件状态。"
            )
        )
        if cleared {
            self.lastSuccess = .init(title: "已清除项目配置", detail: self.projectRouteDisplayName(rule))
        }
    }

    private func deleteProjectRoute(argumentsJSON: String, model: DesktopAppModel) async {
        guard let request = Self.projectRouteDeleteArguments(from: argumentsJSON),
              let rule = self.findProjectRoute(routeID: request.routeID, model: model)
        else {
            self.messages.append(.init(role: .assistant, text: "未能找到要删除的项目路由。你可以先说“查看项目路由”获取 route_id。"))
            return
        }

        if request.clearProjectConfig {
            let cleared = await self.clearProjectRouteConfiguration(rule, model: model)
            guard cleared else {
                self.messages.append(.init(role: .assistant, text: "项目配置清除失败，因此没有删除应用内项目路由记录。"))
                return
            }
        }

        var updatedSettings = model.settings
        updatedSettings.codexProjectRoutes.removeAll { $0.id == rule.id }
        updatedSettings = updatedSettings.normalizedModelRoutingConfig()
        let saved = await model.persistSettingsUpdate(
            updatedSettings,
            noticeContext: .saveSettings,
            successTitle: "项目路由已删除",
            successDetail: self.projectRouteDisplayName(rule)
        )
        guard saved else {
            self.messages.append(.init(role: .assistant, text: "删除项目路由失败，已保持当前配置不变。"))
            return
        }

        self.messages.append(.init(role: .assistant, text: "已删除项目路由：\(self.projectRouteDisplayName(rule))"))
        self.lastSuccess = .init(title: "已删除项目路由", detail: self.projectRouteDisplayName(rule))
    }

    private func saveProjectRoute(_ rule: CodexProjectRouteRule, replacingID: String?, model: DesktopAppModel) async -> Bool {
        var updatedSettings = model.settings
        if let replacingID,
           let index = updatedSettings.codexProjectRoutes.firstIndex(where: { $0.id == replacingID })
        {
            updatedSettings.codexProjectRoutes[index] = rule
        } else {
            updatedSettings.codexProjectRoutes.append(rule)
        }
        updatedSettings = updatedSettings.normalizedModelRoutingConfig()
        return await model.persistSettingsUpdate(
            updatedSettings,
            noticeContext: .saveSettings,
            successTitle: "项目路由已保存",
            successDetail: self.projectRouteDisplayName(rule)
        )
    }

    private func writeProjectRouteConfiguration(_ rule: CodexProjectRouteRule, model: DesktopAppModel) async -> Bool {
        do {
            _ = try model.clientConfigFileService.applyProjectRouteConfiguration(rule)
            model.publishBanner(.success, title: "已写入项目配置", detail: self.projectRouteWriteDetail(rule, model: model))
            await self.refreshProjectRoutePreview(for: rule, model: model)
            return true
        } catch {
            model.present(error: error, context: .saveSettings)
            return false
        }
    }

    private func clearProjectRouteConfiguration(_ rule: CodexProjectRouteRule, model: DesktopAppModel) async -> Bool {
        do {
            _ = try model.clientConfigFileService.clearProjectRouteConfiguration(rule)
            model.publishBanner(.success, title: "已清空项目路由", detail: self.projectRouteClearDetail(rule, model: model))
            await self.refreshProjectRoutePreview(for: rule, model: model)
            return true
        } catch {
            model.present(error: error, context: .saveSettings)
            return false
        }
    }

    private func refreshProjectRoutePreview(for rule: CodexProjectRouteRule, model: DesktopAppModel) async {
        let target: ClientConfigTarget = rule.client == .codex ? .codex : .claudeCode
        await model.refreshClientConfigManagerState(target: target, force: true)
        await model.loadClientConfigManagerBackupsIfNeeded(target: target, force: true)
    }

    private func resolveProjectRouteProxyAPIKeyID(_ requestedID: String?, model: DesktopAppModel) -> String? {
        if let requestedID {
            return self.projectRouteProxyAPIKeyExists(requestedID, model: model) ? requestedID : nil
        }
        return model.codexProjectRouteAvailableProxyKeys.first?.id
    }

    private func projectRouteProxyAPIKeyExists(_ id: String, model: DesktopAppModel) -> Bool {
        model.codexProjectRouteAvailableProxyKeys.contains { $0.id == id }
    }

    private func findProjectRoute(routeID: String, model: DesktopAppModel) -> CodexProjectRouteRule? {
        model.codexProjectRouteRules.first { $0.id == routeID }
    }

    private func hasDuplicateProjectRoute(client: ProjectRouteClient, routeModel: String, excludingID: String?, model: DesktopAppModel) -> Bool {
        model.codexProjectRouteRules.contains { route in
            route.id != excludingID && route.client == client && route.routeModel == routeModel
        }
    }

    private func projectRouteDisplayName(_ rule: CodexProjectRouteRule) -> String {
        rule.label.isEmpty ? rule.routeModel : rule.label
    }

    private func projectRouteSummaryLine(_ rule: CodexProjectRouteRule, model: DesktopAppModel, includeID: Bool) -> String {
        let idText = includeID ? "\n  ID：\(rule.id)" : ""
        return """
        • \(self.projectRouteDisplayName(rule))\(idText)
          客户端：\(model.codexProjectRouteClientLabel(rule))
          项目：\(rule.projectPath)
          路由模型：\(rule.routeModel)
          目标模型：\(rule.targetModel)
          本地 Key：\(model.codexProjectRouteKeyLabel(rule))
          状态：\(rule.enabled ? "启用" : "禁用")，\(model.codexProjectRouteConfigStatus(rule))
        """
    }

    private func projectRouteWriteDetail(_ rule: CodexProjectRouteRule, model: DesktopAppModel) -> String {
        switch rule.client {
        case .codex:
            return "已把 \(rule.routeModel) 写入 \(rule.projectPath)/.codex/config.toml。"
        case .claudeCode:
            return "已把 \(rule.routeModel) 写入 \(rule.projectPath)/\(model.claudeProjectSettingsScopeLabel(rule.claudeSettingsScope))。请重新启动非 resume 的 Claude Code 会话。"
        }
    }

    private func projectRouteClearDetail(_ rule: CodexProjectRouteRule, model: DesktopAppModel) -> String {
        switch rule.client {
        case .codex:
            return "已移除 \(rule.projectPath)/.codex/config.toml 中的顶层 model 配置。"
        case .claudeCode:
            return "已移除 \(rule.projectPath)/\(model.claudeProjectSettingsScopeLabel(rule.claudeSettingsScope)) 中的顶层 model 和 Claude Code 自定义模型选项。"
        }
    }

    private func projectRoutesPromptSummary(model: DesktopAppModel) -> String {
        let routes = model.codexProjectRouteRules
        guard routes.isEmpty == false else {
            return "无项目路由"
        }
        var lines = routes.prefix(8).map { route in
            "\(self.projectRouteDisplayName(route)) [id=\(route.id), client=\(route.client.rawValue), route_model=\(route.routeModel), target_model=\(route.targetModel), key_id=\(route.proxyAPIKeyID), status=\(route.enabled ? "enabled" : "disabled")]"
        }
        if routes.count > 8 {
            lines.append("...共 \(routes.count) 条项目路由")
        }
        return lines.joined(separator: "\n")
    }

    private func projectRouteKeysPromptSummary(model: DesktopAppModel) -> String {
        let keys = model.codexProjectRouteAvailableProxyKeys
        guard keys.isEmpty == false else {
            return "无可用本地 Key"
        }
        var lines = keys.prefix(8).map { key in
            "\(model.proxyAPIKeyDisplayLabel(key)) [id=\(key.id), source=\(key.dataSource.rawValue)]"
        }
        if keys.count > 8 {
            lines.append("...共 \(keys.count) 个可用本地 Key")
        }
        return lines.joined(separator: "\n")
    }

    private func setAccountEnabled(account: AccountSummary, enabled: Bool, model: DesktopAppModel) async {
        guard account.enabled != enabled else {
            self.messages.append(.init(role: .assistant, text: "账号 \(account.label) 当前已是\(enabled ? "启用" : "禁用")状态，无需重复操作。"))
            return
        }

        do {
            let updated = try await model.admin.setAccountEnabled(id: account.id, enabled: enabled)
            try await model.reloadAccountState()
            let statusText = model.accountRuntimeStatusText(updated)
            self.messages.append(.init(role: .assistant, text: "已将账号 \(updated.label) 设为\(enabled ? "启用" : "禁用")。当前状态：\(statusText)"))
            self.lastSuccess = .init(title: "已更新账号状态", detail: updated.label)
        } catch {
            self.messages.append(.init(role: .assistant, text: "切换账号 \(account.label) 启用状态失败：\(error.localizedDescription)"))
        }
    }

    private func stopAccountCooldown(account: AccountSummary, model: DesktopAppModel) async {
        await model.stopAccountCooldown(account)
        await model.loadAll()
        let statusText = model.accountRuntimeStatusText(account)
        self.messages.append(.init(role: .assistant, text: "已尝试结束账号 \(account.label) 的冷却。当前状态：\(statusText)"))
        self.lastSuccess = .init(title: "已尝试结束冷却", detail: account.label)
    }

    private func handle(_ text: String, model: DesktopAppModel) async {
        do {
            await self.configureModelClientIfNeeded(model: model)
            let systemPrompt = self.buildSystemPrompt(model: model)
            let conversation = self.buildConversationMessages(excludingLastUser: text)
            let reply = try await self.modelClient.reply(systemPrompt: systemPrompt, messages: conversation)

            if let functionCall = reply.functionCall {
                if reply.message.isEmpty == false {
                    self.messages.append(.init(role: .assistant, text: reply.message))
                }
                await self.executeFunctionCall(functionCall, model: model)
            } else if reply.message.isEmpty {
                await self.respondGeneral(text, model: model)
            } else {
                self.messages.append(.init(role: .assistant, text: reply.message))
            }
        } catch {
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    我刚刚调用大模型失败了，先给你一条可直接执行的备选路径：

                    \(error.localizedDescription)

                    你也可以直接说：
                    • 查看地址 / 查看 Key / 添加账号 / 刷新账号池 / 打开代理页
                    """
                )
            )
            await self.respondGeneral(text, model: model)
        }
    }

    private func showAccessSummary(model: DesktopAppModel) {
        let text = """
        当前接入信息：
        • OpenAI 兼容根地址：\(model.openAICompatibleBaseURL)
        • Anthropic 根地址：\(model.anthropicBaseURL)
        • Gemini 根地址：\(model.geminiBaseURL)
        • 当前本地 API Key：\(model.localProxyAPIKeyValue)

        需要的话我可以继续帮你复制地址或 Key。
        """
        self.messages.append(.init(role: .assistant, text: text))
    }

    private func showKeySummary(model: DesktopAppModel) {
        let key = model.localProxyAPIKeyValue
        let text = """
        当前本地 API Key：
        \(key)

        如果你的客户端已经填入上面的根地址，把这把 Key 一起填进去就能完成连接。
        """
        self.messages.append(.init(role: .assistant, text: text))
    }

    private func beginManualAccountCreation(model: DesktopAppModel) {
        model.presentManualAPIKeySheet()
        let text = """
        已经为你打开手动添加 API Key 账号入口。

        接下来在右侧表单里填写：
        1. 备注名
        2. 预设类型
        3. 根地址
        4. API Key

        填完后直接点保存即可。
        """
        self.messages.append(.init(role: .assistant, text: text))
        self.lastSuccess = .init(title: "已打开添加账号入口", detail: "请在右侧表单完成账号录入")
    }

    private func beginOpenAILogin(model: DesktopAppModel) {
        Task { await model.startOAuth(providerFamily: .openAI) }
        let text = """
        已启动 OpenAI 登录流程。

        浏览器会打开授权页，完成授权后系统会自动把账号导入到账号池。
        """
        self.messages.append(.init(role: .assistant, text: text))
        self.lastSuccess = .init(title: "已打开 OpenAI 登录", detail: "在浏览器完成授权即可导入账号")
    }

    private func refreshAccounts(model: DesktopAppModel) async {
        self.messages.append(.init(role: .system, text: "正在刷新账号池和代理状态..."))
        await model.loadAll()
        let available = self.availableAccountOptions(model: model)
        var text = "已刷新当前环境。现在账号池里可用账号有 \(available.count) 个：\n"
        if available.isEmpty {
            text += "\n目前还没有可用账号。要不要先添加一个？"
        } else {
            for option in available.prefix(8) {
                text += "\n• \(option.title)"
            }
            if available.count > 8 {
                text += "\n...还有 \(available.count - 8) 个可用账号"
            }
        }
        self.messages.append(.init(role: .assistant, text: text))
        self.lastSuccess = .init(title: "已刷新环境", detail: "可用账号数：\(available.count)")
    }

    private func matchesHelp(_ text: String) -> Bool {
        text.contains("帮助") || text.contains("指令") || text.contains("怎么用") || text.contains("你会什么") || text.contains("能做什么") || text.contains("help") || text.contains("command")
    }

    private func matchesQuickStatus(_ text: String) -> Bool {
        text.contains("当前状态") || text.contains("现在状态") || text.contains("运行状态") || text.contains("能否启动") || text.contains("能否停止") || text.contains("是否运行") || text.contains("status") || text.contains("running")
    }

    private func matchesAccountSummary(_ text: String) -> Bool {
        text.contains("查看账号") || text.contains("账号列表") || text.contains("账号状态") || text.contains("有多少账号") || text.contains("是否可用") || text.contains("accounts") || text.contains("account list")
    }

    private func matchesOpenAILogin(_ text: String) -> Bool {
        text.contains("openai") && (text.contains("登录") || text.contains("导入") || text.contains("login") || text.contains("oauth"))
    }

    private func matchesAnthropicLogin(_ text: String) -> Bool {
        text.contains("anthropic") && (text.contains("登录") || text.contains("导入") || text.contains("login") || text.contains("oauth"))
    }

    private func matchesGeminiLogin(_ text: String) -> Bool {
        (text.contains("gemini") || text.contains("google")) && (text.contains("登录") || text.contains("导入") || text.contains("login") || text.contains("oauth"))
    }

    private func matchesManualAccount(_ text: String) -> Bool {
        text.contains("手动") || text.contains("新增") || text.contains("添加账号") || text.contains("添加 api key") || text.contains("add account") || text.contains("manual")
    }

    private func matchesImport(_ text: String) -> Bool {
        text.contains("导入账号") || text.contains("导入json") || text.contains("导入 json") || text.contains("import") || text.contains("json导入")
    }

    private func matchesEndpointCopy(_ text: String) -> Bool {
        text.contains("复制地址") || text.contains("复制 endpoint") || text.contains("复制 base url") || text.contains("copy endpoint") || text.contains("copy base url")
    }

    private func matchesKeyCopy(_ text: String) -> Bool {
        text.contains("复制 key") || text.contains("复制 api key") || text.contains("复制密钥") || text.contains("copy key") || text.contains("copy api key")
    }

    private func matchesClaudeCode(_ text: String) -> Bool {
        text.contains("claude code") || text.contains("claudecode") || text.contains("anthropic 环境变量") || text.contains("claude 环境")
    }

    private func matchesGeminiCLI(_ text: String) -> Bool {
        text.contains("gemini cli") || text.contains("gemini环境") || text.contains("gemini 环境变量") || text.contains("google gemini")
    }

    private func matchesRequestLogs(_ text: String) -> Bool {
        text.contains("查看日志") || text.contains("请求日志") || text.contains("详细日志") || text.contains("request logs") || text.contains("logs")
    }

    private func matchesProxyTest(_ text: String) -> Bool {
        text.contains("测试控制台") || text.contains("代理测试") || text.contains("proxy test") || text.contains("test console")
    }

    private func matchesHelpWindow(_ text: String) -> Bool {
        text.contains("打开帮助") || text.contains("帮助页") || text.contains("帮助窗口") || text.contains("open help")
    }

    private func matchesExportAccounts(_ text: String) -> Bool {
        text.contains("导出账号") || text.contains("导出备份") || text.contains("export accounts") || text.contains("backup")
    }

    private func matchesImportCurrent(_ text: String) -> Bool {
        text.contains("导入当前") || text.contains("当前配置导入") || text.contains("import current") || text.contains("导入当前认证")
    }

    private func matchesRefreshAll(_ text: String) -> Bool {
        text.contains("刷新账号池") || text.contains("刷新环境") || text.contains("重新加载账号") || text.contains("refresh accounts") || text.contains("reload accounts")
    }

    private func matchesRefreshUsage(_ text: String) -> Bool {
        text.contains("刷新用量") || text.contains("刷新使用量") || text.contains("refresh usage")
    }

    private func matchesStartDaemon(_ text: String) -> Bool {
        text.contains("启动服务") || text.contains("开启服务") || text.contains("start service") || text.contains("start daemon")
    }

    private func matchesStopDaemon(_ text: String) -> Bool {
        text.contains("停止服务") || text.contains("关闭服务") || text.contains("stop service") || text.contains("stop daemon")
    }

    private func matchesOverview(_ text: String) -> Bool {
        text.contains("总览") || text.contains("打开总览") || text.contains("overview")
    }

    private func matchesAccountsPage(_ text: String) -> Bool {
        text.contains("账号页") || text.contains("打开账号") || text.contains("accounts page")
    }

    private func matchesProxyPage(_ text: String) -> Bool {
        text.contains("代理页") || text.contains("打开代理") || text.contains("proxy page")
    }

    private func matchesSettings(_ text: String) -> Bool {
        text.contains("设置页") || text.contains("打开设置") || text.contains("settings") || text.contains("设置窗口")
    }

    private func matchesFullMode(_ text: String) -> Bool {
        text.contains("完整模式") || text.contains("全功能模式") || text.contains("full mode")
    }

    private func matchesMinimalMode(_ text: String) -> Bool {
        text.contains("精简模式") || text.contains("极简模式") || text.contains("minimal mode")
    }

    private func showHelpGuide(model: DesktopAppModel) {
        let text = """
        我主要负责把常用操作缩短成一句话入口。你可以按下面这些大类来和我对话：

        1) 账号与账号池
        • 查看账号 / 账号列表 / 是否可用
        • 添加账号 / 手动添加 / 导入账号
        • OpenAI 登录 / Anthropic 登录 / Gemini 登录
        • 刷新账号池 / 刷新用量

        2) 代理地址与 API Key
        • 查看地址 / 复制地址
        • 查看 Key / 复制 Key
        • Claude Code 环境变量 / Gemini CLI 环境变量

        3) 服务状态
        • 当前状态 / 能否启动 / 能否停止
        • 启动服务 / 停止服务

        4) 页面导航
        • 打开总览 / 账号页 / 代理页 / 设置页 / 帮助 / 日志 / 代理测试

        5) 设置与管理
        • 出站代理 / 配置代理 / 导出账号 / 导入当前认证

        你可以直接说需求，比如：
        • 查看当前可用账号
        • 帮我打开代理页
        • 查看地址和 Key
        • 停止服务前先告诉我当前状态
        """
        self.messages.append(.init(role: .assistant, text: text))
    }

    private func showQuickStatus(model: DesktopAppModel) {
        let available = self.availableAccountOptions(model: model)
        let text = """
        当前环境速览：
        • 服务状态：\(model.localServicePrimaryStatusText)
        • 状态说明：\(model.localServiceSummaryText)
        • 可用账号数：\(available.count)
        • OpenAI 兼容地址：\(model.openAICompatibleBaseURL)
        • Anthropic 根地址：\(model.anthropicBaseURL)
        • Gemini 根地址：\(model.geminiBaseURL)
        • 当前本地 API Key：\(model.localProxyAPIKeyValue)

        你接下来最常做的通常是：
        • 有账号但不会连接 → 查看地址 / 查看 Key
        • 还没账号 → 添加账号 / OpenAI 登录 / Anthropic 登录
        • 怀疑服务没起来 → 启动服务 / 停止服务 / 再看一次状态
        """
        self.messages.append(.init(role: .assistant, text: text))
    }

    private func showAccountSummary(model: DesktopAppModel) async {
        await model.loadAll()
        let accounts = model.accounts
        let available = self.availableAccountOptions(model: model)
        var text = "当前账号池概况：\n"
        text += "\n• 总账号数：\(accounts.count)"
        text += "\n• 可用账号数：\(available.count)"

        if accounts.isEmpty {
            text += "\n\n现在还没有账号，建议先从这三步之一开始："
            text += "\n1. 手动添加一个 API Key 账号"
            text += "\n2. OpenAI 登录导入"
            text += "\n3. Anthropic 登录导入"
        } else {
            text += "\n\n最近账号（最多 10 个）："
            for account in accounts.prefix(10) {
                let issue = model.accountIssueText(account)
                let status = model.accountRuntimeStatusText(account)
                let suffix = issue ?? status
                text += "\n• \(account.label) — \(suffix)"
            }
        }

        self.messages.append(.init(role: .assistant, text: text))
    }

    private func beginAnthropicLogin(model: DesktopAppModel) {
        Task { await model.startOAuth(providerFamily: .anthropic) }
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已启动 Anthropic 登录流程。

                浏览器会打开 Anthropic 授权页，完成授权后系统会自动把账号导入到账号池。
                """
            )
        )
        self.lastSuccess = .init(title: "已打开 Anthropic 登录", detail: "在浏览器完成授权即可导入账号")
    }

    private func beginGeminiLogin(model: DesktopAppModel) {
        Task { await model.startOAuth(providerFamily: .gemini) }
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已启动 Google / Gemini 登录流程。

                浏览器会打开 Google 授权页，完成授权后系统会自动把账号导入到账号池。
                """
            )
        )
        self.lastSuccess = .init(title: "已打开 Google / Gemini 登录", detail: "在浏览器完成授权即可导入账号")
    }

    private func beginImportAccounts(model: DesktopAppModel) {
        model.presentAuthImportSheet()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已打开导入账号入口。

                你现在可以：
                • 粘贴 JSON
                • 粘贴 ChatGPT Web Session
                • 从文件导入
                """
            )
        )
        self.lastSuccess = .init(title: "已打开导入入口", detail: "可选择粘贴 JSON 或从文件导入账号")
    }

    private func copyEndpointText(model: DesktopAppModel) {
        model.copyEndpoint()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已复制当前 OpenAI 兼容根地址：
                \(model.openAICompatibleBaseURL)

                多数 OpenAI 兼容客户端会把它当作 Base URL。
                """
            )
        )
        self.lastSuccess = .init(title: "已复制地址", detail: model.openAICompatibleBaseURL)
    }

    private func copyKeyText(model: DesktopAppModel) {
        model.copyAPIKey()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已复制当前本地 API Key：
                \(model.localProxyAPIKeyValue)

                如果你已经填好 Base URL，把这把 Key 一起填进去即可完成接入。
                """
            )
        )
        self.lastSuccess = .init(title: "已复制 Key", detail: model.localProxyAPIKeyValue)
    }

    private func showClaudeCodeSnippet(model: DesktopAppModel) {
        if model.canCopyClaudeCodeEnvironmentSnippet {
            model.copyClaudeCodeEnvironment()
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    已复制 Claude Code 环境变量片段：
                    \(model.claudeCodeEnvironmentSnippet)
                    """
                )
            )
            self.lastSuccess = .init(title: "已复制 Claude Code 环境变量", detail: nil)
        } else {
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    当前没有可用的 Anthropic 路由本地 Key，无法生成 Claude Code 环境变量。

                    建议你先：
                    • 新增一把 Anthropic / 全量路由的本地 Key
                    • 或先检查当前账号池是否已经包含可用 Anthropic 账号
                    """
                )
            )
        }
    }

    private func showGeminiCLISnippet(model: DesktopAppModel) {
        model.copyGeminiCLIEnvironment()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已复制 Gemini CLI 环境变量片段：
                \(model.geminiCLIEnvironmentSnippet)
                """
            )
        )
        self.lastSuccess = .init(title: "已复制 Gemini CLI 环境变量", detail: nil)
    }

    private func openRequestLogs(model: DesktopAppModel) {
        model.openRequestLogsWindow()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已打开请求日志窗口。

                你可以在日志页进一步查看请求来源、账号路由、延迟、失败原因等信息。
                """
            )
        )
        self.lastSuccess = .init(title: "已打开请求日志", detail: nil)
    }

    private func openProxyTest(model: DesktopAppModel) {
        model.openProxyTestConsole()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已打开代理测试控制台。

                你可以在里面验证当前地址、Key、账号路由、模型返回是否正常。
                """
            )
        )
        self.lastSuccess = .init(title: "已打开代理测试控制台", detail: nil)
    }

    private func openHelpWindow(model: DesktopAppModel) {
        model.openHelpWindow()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已打开帮助窗口。

                如果你想继续在助手内操作，也可以直接继续问我。
                """
            )
        )
        self.lastSuccess = .init(title: "已打开帮助", detail: nil)
    }

    private func exportAccounts(model: DesktopAppModel) async {
        await model.exportAccounts()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已触发导出账号操作。

                系统会按照主窗口里的导出流程继续完成保存。
                """
            )
        )
        self.lastSuccess = .init(title: "已触发导出账号", detail: nil)
    }

    private func importCurrentAuth(model: DesktopAppModel) async {
        await model.importCurrentAuth()
        await model.loadAll()
        let available = self.availableAccountOptions(model: model)
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已尝试导入当前认证配置，并刷新了当前环境。

                现在可用账号数：\(available.count)
                """
            )
        )
        self.lastSuccess = .init(title: "已导入当前认证", detail: "可用账号数：\(available.count)")
    }

    private func refreshUsage(model: DesktopAppModel) async {
        await model.refreshUsage()
        await model.loadAll()
        self.messages.append(
            .init(
                role: .assistant,
                text: """
                已刷新当前账号使用量。

                你可以在账号页继续查看单账号状态、冷却中、异常或可用情况。
                """
            )
        )
        self.lastSuccess = .init(title: "已刷新用量", detail: nil)
    }

    private func startDaemon(model: DesktopAppModel) async {
        if model.localCanStartService {
            await model.startDaemon()
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    已尝试启动本地服务。

                    当前状态：\(model.localServicePrimaryStatusText)
                    状态说明：\(model.localServiceSummaryText)
                    """
                )
            )
            self.lastSuccess = .init(title: "已尝试启动服务", detail: model.localServicePrimaryStatusText)
        } else {
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    现在不能直接启动服务。

                    当前状态：\(model.localServicePrimaryStatusText)
                    状态说明：\(model.localServiceSummaryText)

                    你可以继续告诉我：
                    • 查看当前状态
                    • 停止服务
                    • 刷新环境
                    """
                )
            )
        }
    }

    private func stopDaemon(model: DesktopAppModel) async {
        if model.localCanStopService {
            await model.stopDaemon()
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    已尝试停止本地服务。

                    当前状态：\(model.localServicePrimaryStatusText)
                    状态说明：\(model.localServiceSummaryText)
                    """
                )
            )
            self.lastSuccess = .init(title: "已尝试停止服务", detail: model.localServicePrimaryStatusText)
        } else {
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    现在不能直接停止服务。

                    当前状态：\(model.localServicePrimaryStatusText)
                    状态说明：\(model.localServiceSummaryText)

                    你可以继续告诉我：
                    • 查看当前状态
                    • 启动服务
                    • 刷新环境
                    """
                )
            )
        }
    }

    private func openPage(_ page: DesktopAppModel.Page, model: DesktopAppModel) {
        guard model.canOpenPage(page) else {
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    当前环境下这个页面还不可用。

                    如果是 Remote 页面，通常需要先解锁远程管理入口。
                    """
                )
            )
            return
        }

        model.openDashboard(page)
        self.messages.append(.init(role: .assistant, text: "已打开 \(model.pageTitle(page))。"))
        self.lastSuccess = .init(title: "已打开页面", detail: model.pageTitle(page))
    }

    private func switchMode(_ target: DesktopInterfaceMode, model: DesktopAppModel) {
        model.switchInterfaceMode(target: target)
        let title = model.label(for: target)
        self.messages.append(.init(role: .assistant, text: "已切换到 \(title)。"))
        self.lastSuccess = .init(title: "已切换模式", detail: title)
    }

    private func matchesEndpointSummary(_ text: String) -> Bool {
        text.contains("查看地址") || text.contains("地址是什么") || text.contains("base url") || text.contains("endpoint") || text.contains("连接地址") || text.contains("代理地址")
    }

    private func matchesKeySummary(_ text: String) -> Bool {
        text.contains("查看 key") || text.contains("key 是什么") || text.contains("api key") || text.contains("密钥") || text.contains("鉴权") || text.contains("本地 key")
    }

    private func respondGeneral(_ text: String, model: DesktopAppModel) async {
        let available = self.availableAccountOptions(model: model)
        if available.isEmpty {
            self.messages.append(
                .init(
                    role: .assistant,
                    text: """
                    现在账号池里还没有可用账号，我先把最相关的操作列出来：
                    • 手动添加一个 API Key 账号
                    • 启动 OpenAI 登录导入账号
                    • 查看当前代理地址和 API Key

                    你要从哪一个开始？
                    """
                )
            )
            return
        }

        var response = "我先基于当前环境给你最相关的入口：\n"
        response += "\n• 可用账号数：\(available.count)"
        response += "\n• OpenAI 兼容地址：\(model.openAICompatibleBaseURL)"
        response += "\n• 当前本地 Key：\(model.localProxyAPIKeyValue)"
        response += "\n\n你也可以直接跟我说："
        response += "\n• 查看地址 / 复制地址"
        response += "\n• 查看 API Key / 复制 API Key"
        response += "\n• 添加账号 / OpenAI 登录 / 刷新账号池"
        self.messages.append(.init(role: .assistant, text: response))
    }

    private func availableAccountOptions(model: DesktopAppModel) -> [AssistantAccountOption] {
        let accounts = model.accounts
        let enabledAccounts = accounts.filter { account in
            guard account.enabled else { return false }
            if let cooldownUntil = account.cooldownUntil, cooldownUntil > Helpers.now() {
                return false
            }
            return true
        }

        guard enabledAccounts.isEmpty == false else {
            return []
        }

        return enabledAccounts
            .sorted { lhs, rhs in
                if lhs.selectionOrder != rhs.selectionOrder {
                    return lhs.selectionOrder < rhs.selectionOrder
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .map { account in
                let issueText = model.accountIssueText(account)
                let subtitle = [model.accountRuntimeStatusText(account), issueText]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return AssistantAccountOption(
                    id: account.id,
                    accountKey: account.accountKey,
                    title: account.label,
                    subtitle: subtitle.isEmpty ? model.accountAuthModeText(account) : subtitle
                )
            }
    }
}
#endif

extension AssistantChatService {
    var availableAccountCount: Int {
        self.availableAccountOptions(model: self.model).count
    }

    var availableAccountCountText: String {
        "\(self.availableAccountCount)"
    }

    func showAccessSummary() {
        guard let model else { return }
        self.showAccessSummary(model: model)
    }

    func beginManualAccountCreation() {
        guard let model else { return }
        self.beginManualAccountCreation(model: model)
    }

    func beginOpenAILogin() {
        guard let model else { return }
        self.beginOpenAILogin(model: model)
    }

    func refreshEnvironment() async {
        guard let model else { return }
        await self.refreshAccounts(model: model)
    }

    private func availableAccountOptions(model: DesktopAppModel?) -> [AssistantAccountOption] {
        guard let model else { return [] }
        return self.availableAccountOptions(model: model)
    }
}

extension DesktopAppModel {
    var assistantChatService: AssistantChatService {
        if let existing = objc_getAssociatedObject(self, &DesktopAppModel.assistantChatServiceKey) as? AssistantChatService {
            return existing
        }
        let service = AssistantChatService(model: self)
        objc_setAssociatedObject(self, &DesktopAppModel.assistantChatServiceKey, service, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return service
    }

    private static var assistantChatServiceKey: UInt8 = 0
    private static var isAssistantPresentedKey: UInt8 = 0

    var isAssistantPresented: Bool {
        get {
            (objc_getAssociatedObject(self, &DesktopAppModel.isAssistantPresentedKey) as? NSNumber)?.boolValue ?? false
        }
        set {
            objc_setAssociatedObject(self, &DesktopAppModel.isAssistantPresentedKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func openAssistantWindow() {
        if self.assistantWindowController == nil {
            self.assistantWindowController = AssistantWindowController(model: self)
        }

        self.isAssistantPresented = true
        self.assistantWindowController?.showWindow()
    }

    func assistantWindowDidClose() {
        self.isAssistantPresented = false
    }

    func publishAssistantSuccess(title: String, detail: String?) {
        self.publishBanner(.success, title: title, detail: detail)
    }

    func dismissAssistantBanner(id: BannerState.ID) {
        self.dismissBanner(id: id)
    }
}
