#if os(macOS)
import Foundation

enum HelpTopicID: String, CaseIterable, Identifiable, Hashable {
    case quickStart
    case overview
    case accounts
    case proxy
    case settings
    case remote
    case tools

    var id: String { self.rawValue }

    var symbolName: String {
        switch self {
        case .quickStart:
            return "sparkles"
        case .overview:
            return "square.grid.2x2.fill"
        case .accounts:
            return "person.2.crop.square.stack.fill"
        case .proxy:
            return "bolt.horizontal.circle.fill"
        case .settings:
            return "slider.horizontal.3"
        case .remote:
            return "server.rack"
        case .tools:
            return "rectangle.3.group.bubble.left.fill"
        }
    }
}

enum HelpActionTarget: Equatable {
    case page(DesktopAppModel.Page)
    case proxyAccess
    case settingsProxy
    case requestLogs
    case proxyTestConsole
    case managedProxyManager
    case onboarding
}

struct HelpDocument: Equatable {
    struct Action: Identifiable, Equatable {
        let id: String
        let title: String
        let target: HelpActionTarget
        var isPrimary = false
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let number: Int
        let title: String
        let detail: String
        let action: Action?
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let summary: String
        let bullets: [String]
        let action: Action?
    }

    struct Topic: Identifiable, Equatable {
        let id: HelpTopicID
        let title: String
        let subtitle: String
        let eyebrow: String
        let overview: String
        let actions: [Action]
        let steps: [Step]
        let sections: [Section]
    }

    let title: String
    let subtitle: String
    let quickActions: [Action]
    let topics: [Topic]

    func topic(for id: HelpTopicID) -> Topic {
        self.topics.first(where: { $0.id == id }) ?? self.topics[0]
    }
}

@MainActor
extension DesktopAppModel {
    var helpDocument: HelpDocument {
        let isChinese = self.localization.resolvedLanguage == .zhHans

        func t(_ zh: String, _ en: String) -> String {
            isChinese ? zh : en
        }

        func action(
            _ id: String,
            _ title: String,
            target: HelpActionTarget,
            isPrimary: Bool = false
        ) -> HelpDocument.Action {
            HelpDocument.Action(id: id, title: title, target: target, isPrimary: isPrimary)
        }

        let accountsAction = action(
            "open-accounts",
            t("打开 \(self.pageTitle(.accounts))", "Open \(self.pageTitle(.accounts))"),
            target: .page(.accounts),
            isPrimary: true
        )
        let overviewAction = action(
            "open-overview",
            t("打开 \(self.pageTitle(.overview))", "Open \(self.pageTitle(.overview))"),
            target: .page(.overview),
            isPrimary: true
        )
        let proxyAction = action(
            "open-proxy",
            t("打开 \(self.pageTitle(.proxy))", "Open \(self.pageTitle(.proxy))"),
            target: .page(.proxy),
            isPrimary: true
        )
        let settingsAction = action(
            "open-settings",
            t("打开 \(self.pageTitle(.settings))", "Open \(self.pageTitle(.settings))"),
            target: .page(.settings),
            isPrimary: true
        )
        let requestLogsAction = action(
            "open-request-logs",
            t("打开 \(self.text(.requestLogsTitle))", "Open \(self.text(.requestLogsTitle))"),
            target: .requestLogs
        )
        let onboardingAction = action(
            "start-onboarding",
            t("开始新手引导", "Start Onboarding"),
            target: .onboarding,
            isPrimary: true
        )
        let proxyAccessAction = action(
            "open-proxy-access",
            t("打开代理接入信息", "Open Proxy Access"),
            target: .proxyAccess,
            isPrimary: true
        )
        let settingsProxyAction = action(
            "open-settings-proxy",
            t("打开出站代理设置", "Open Outbound Proxy"),
            target: .settingsProxy,
            isPrimary: true
        )
        let proxyTestAction = action(
            "open-proxy-test",
            t("打开 \(self.text(.proxyTestTitle))", "Open \(self.text(.proxyTestTitle))"),
            target: .proxyTestConsole
        )
        let managedProxyAction = action(
            "open-managed-proxy",
            t("打开 \(self.managedProxyManagerWindowTitle)", "Open \(self.managedProxyManagerWindowTitle)"),
            target: .managedProxyManager
        )
        let quickStartLayoutSummary = self.isRemoteManagementUnlocked
            ? t("你可以把主界面理解成“总览看状态，账号页管上游账号，代理页发给客户端，设置页调网络，远程页管部署与重部署”。", "Think of the shell as: Overview for health, Accounts for upstream identities, Proxy for client-facing access, Settings for network/runtime behavior, and Remote for deployment and redeployment.")
            : t("你可以把主界面理解成“总览看状态，账号页管上游账号，代理页发给客户端，设置页调网络”。", "Think of the shell as: Overview for health, Accounts for upstream identities, Proxy for client-facing access, and Settings for network/runtime behavior.")
        var quickStartLayoutBullets = [
            t("`总览` 负责启动/停止服务，并用最短路径告诉你现在能不能接入。", "`Overview` starts or stops the service and tells you whether the proxy is ready."),
            t("`账号页` 维护账号池、导入来源、刷新用量与账号启停。", "`Accounts` manages the account pool, import sources, usage refreshes, and account enable/disable."),
            t("`代理页` 提供客户端真正要填写的地址、Key、多 Key 管理、详细日志和测试控制台。", "`Proxy` exposes the actual endpoint and keys your clients use, plus local-key management, detailed logs, and the test console."),
            t("`设置` 负责语言主题、自动启动、关闭行为、出站代理和本地服务诊断。", "`Settings` covers language/theme, auto-start, close behavior, outbound proxying, and service diagnostics."),
        ]
        if self.isRemoteManagementUnlocked {
            quickStartLayoutBullets.append(
                t("`远程` 用于保存远程主机、部署或重新部署服务、查看远程状态和日志。", "`Remote` stores hosts, deploys or redeploys the service, and shows remote runtime state and logs.")
            )
        }

        let quickActions = [
            onboardingAction,
            accountsAction,
            proxyAccessAction,
            settingsProxyAction,
            requestLogsAction,
        ]

        var topics = [
            HelpDocument.Topic(
                id: .quickStart,
                title: t("快速开始", "Quick Start"),
                subtitle: t("帮助页是说明书；如果你想马上完成配置，请直接开始新手引导。", "Help is the reference manual. If you want to finish setup right now, jump straight into onboarding."),
                eyebrow: t("首次上手", "First Run"),
                overview: t("先准备账号，再启动本地服务，最后从代理页复制接入信息；如果当前网络环境容易被上游拦截，再到设置页补充出站代理。", "Start by preparing accounts, then start the local service, then copy the client connection details from the proxy page. If your network path is likely to be blocked, finish by configuring outbound proxying in Settings."),
                actions: [onboardingAction, accountsAction, overviewAction, proxyAccessAction, settingsProxyAction],
                steps: [
                    HelpDocument.Step(
                        id: "quick-start-accounts",
                        number: 1,
                        title: t("创建或导入账号池账号", "Create or import account-pool accounts"),
                        detail: t("进入账号页，优先使用 OAuth 登录、导入当前授权或导入 JSON；如果你手里只有上游根地址和 API Key，就用“手动添加”创建独立账号。", "Open Accounts and start with OAuth Login, Import Current, or Import JSON. If you only have an upstream base URL and API key, use Manual Add to create a separate account."),
                        action: accountsAction
                    ),
                    HelpDocument.Step(
                        id: "quick-start-service",
                        number: 2,
                        title: t("启动本地服务", "Start the local service"),
                        detail: t("回到总览页或代理页启动 daemon。启动成功后，你会看到本地服务状态变为运行，并能读取到公开接入地址和当前生效账号。", "Start the daemon from Overview or Proxy. Once healthy, the app will show a running local service plus the public endpoint and the currently active account."),
                        action: overviewAction
                    ),
                    HelpDocument.Step(
                        id: "quick-start-access",
                        number: 3,
                        title: t("复制 Base URL / API Key 给客户端", "Copy the Base URL and API key into your client"),
                        detail: t("到代理页复制 OpenAI 兼容地址、本地 API Key、Claude Code 环境变量片段，或 Gemini CLI 环境变量片段。以后给不同工具或不同用户分配独立本地 Key，也都在这一页处理。", "Go to Proxy to copy the OpenAI-compatible endpoint, the local proxy API key, the Claude Code environment snippet, or the Gemini CLI environment snippet. This is also where you manage separate local keys for different tools or people."),
                        action: proxyAccessAction
                    ),
                    HelpDocument.Step(
                        id: "quick-start-outbound",
                        number: 4,
                        title: t("网络容易被屏蔽时配置出站代理", "Configure outbound proxying when your network path is blocked"),
                        detail: t("如果上游接口所在区域对当前网络环境有限制，请到设置页的出站代理子页选择直连、手工代理或订阅代理。保存后，daemon 后续发往上游的请求会按这里的规则连出。", "If the upstream region blocks your current network path, open the outbound proxy section in Settings and choose direct, manual, or subscription proxying. After you save, future daemon requests to upstream APIs will use that egress policy."),
                        action: settingsProxyAction
                    ),
                ],
                sections: [
                    HelpDocument.Section(
                        id: "quick-start-layout",
                        title: t("主界面怎么分工", "What each main page is for"),
                        summary: quickStartLayoutSummary,
                        bullets: quickStartLayoutBullets,
                        action: nil
                    ),
                    HelpDocument.Section(
                        id: "quick-start-first-things",
                        title: t("首次使用前先知道", "Important first-run behaviors"),
                        summary: t("AI Coding Proxy 桌面端只是控制台，真正代理流量的是一个本地 daemon 进程。", "The desktop app is the control surface; the actual traffic path is handled by a local daemon process."),
                        bullets: [
                            t("关闭主窗口不一定会停止服务，是否隐藏到菜单栏由设置里的“关闭行为”决定。", "Closing the main window does not always stop the service; the exact behavior is controlled by the Close Action setting."),
                            t("本地接入地址和本地 API Key 会优先显示运行时状态中的值，如果服务未启动则回退到当前设置。", "The app prefers runtime endpoint and API key values when the service is running, and falls back to saved settings when it is not."),
                            t("首次自动弹出的帮助窗口只是参考文档，不会锁住主界面，也不会阻止你直接开始配置。", "This help window is a reference, not a blocking wizard. It never prevents you from configuring the app directly."),
                        ],
                        action: overviewAction
                    ),
                ]
            ),
            HelpDocument.Topic(
                id: .overview,
                title: self.pageTitle(.overview),
                subtitle: self.pageSubtitle(.overview),
                eyebrow: t("运行状态", "Runtime"),
                overview: t("总览页适合先判断服务有没有起来、当前能不能接入，以及最近请求流量是否健康。", "Overview is the fastest place to verify service health, client readiness, and whether recent request traffic looks healthy."),
                actions: [overviewAction],
                steps: [],
                sections: [
                    HelpDocument.Section(
                        id: "overview-service",
                        title: t("启动和停止服务", "Start and stop the service"),
                        summary: t("总览顶部的按钮和状态卡片直接对应本地 daemon 的当前状态。", "The buttons and status cards at the top of Overview map directly to the local daemon state."),
                        bullets: [
                            t("当服务停止时，按钮会显示“启动服务”；运行中则显示“停止服务”。", "When the daemon is stopped you will see Start, and while it is running you will see Stop."),
                            t("状态卡会区分未安装、已停止、启动中、运行正常和运行异常等状态。", "The status tiles distinguish not installed, stopped, starting, healthy running, and degraded running states."),
                            t("如果停止服务，依赖本地代理地址的请求会立即中断，直到你重新启动。", "Stopping the service immediately interrupts requests that rely on the local proxy endpoint until it is started again."),
                        ],
                        action: overviewAction
                    ),
                    HelpDocument.Section(
                        id: "overview-access",
                        title: t("如何判断客户端能不能接入", "How to confirm clients can connect"),
                        summary: t("总览里的接入信息和代理摘要适合在最短时间内排查“地址错了、Key 错了、当前账号不对”等问题。", "Use the access info and proxy summary on Overview to quickly rule out wrong endpoint, wrong key, or unexpected active-account selection."),
                        bullets: [
                            t("接入信息里会显示 OpenAI 兼容地址、Anthropic 根地址、Gemini 根地址和当前本地 API Key。", "The access panel shows the OpenAI-compatible base URL, Anthropic base URL, Gemini base URL, and the current local proxy API key."),
                            t("代理摘要会显示当前生效的账号标签、账号 ID 和最近错误。", "The proxy summary shows the active account label, account ID, and the latest routing/runtime error."),
                            t("更详细的本地日志路径和 launchctl 状态在 设置 > 服务 里查看。", "For detailed log paths and launchctl diagnostics, switch to Settings > Service."),
                        ],
                        action: settingsAction
                    ),
                    HelpDocument.Section(
                        id: "overview-traffic",
                        title: t("流量和最近活动怎么看", "How to read traffic and recent activity"),
                        summary: t("总览的流量与最近活动更适合做高层观察，不替代详细日志。", "The traffic and recent-activity tabs are designed for high-level monitoring and do not replace detailed logs."),
                        bullets: [
                            t("`流量` 会按总输入、总输出、限流次数和额度错误汇总近期数据。", "The Traffic tab summarizes total input, total output, rate limits, and quota errors."),
                            t("`最近活动` 会展示最近时间桶里的 endpoint、模型、请求数、失败数与 tokens。", "Recent Activity shows the latest buckets of endpoints, models, request counts, failures, and token totals."),
                            t("需要看单次请求的 API Key、账号路由、耗时和 HTTP 状态时，请直接打开详细日志窗口。", "When you need per-request API keys, routed accounts, latency, or HTTP status, open the detailed logs window."),
                        ],
                        action: requestLogsAction
                    ),
                ]
            ),
            HelpDocument.Topic(
                id: .accounts,
                title: self.pageTitle(.accounts),
                subtitle: self.pageSubtitle(.accounts),
                eyebrow: t("账号池", "Account Pool"),
                overview: t("账号页负责把不同来源的上游账号统一纳入本地账号池，并给路由层提供可用账号。", "Accounts is where you normalize every upstream identity source into the local account pool that powers proxy routing."),
                actions: [accountsAction],
                steps: [],
                sections: [
                    HelpDocument.Section(
                        id: "accounts-import",
                        title: t("如何创建或导入账号", "How to create or import accounts"),
                        summary: t("你可以在同一个账号池里混合 OAuth 账号、当前本地授权、批量 JSON 导入，以及手动 API Key 账号。", "You can mix OAuth accounts, current local auth imports, batch JSON imports, and manual API key accounts in the same pool."),
                        bullets: [
                            t("`OAuth 登录` 会打开浏览器授权并在回调成功后自动导入账号。", "`OAuth Login` opens the browser flow and imports the account after the callback succeeds."),
                            t("`导入当前` 会读取当前本机的 `~/.codex/auth.json` 并加入账号池。", "`Import Current` reads the local `~/.codex/auth.json` and adds it to the pool."),
                            t("`导入 JSON` 适合批量恢复备份账号；`导出备份` 则会导出当前保存的全部账号。", "`Import JSON` restores backup accounts in bulk, while `Export Backup` writes out every saved account."),
                            t(
                                "`Google / Gemini Login` 用于导入官方 Gemini CLI 支持的个人 Google 账号，包含 AI Pro / Ultra，也兼容个人 free tier 的自动 onboarding；这类账号现在只给 Gemini CLI / 原生 Gemini endpoint 使用。`手动添加` 仍用于兼容 API Key 账号，支持 OpenAI 兼容、Anthropic API 兼容和 Google Gemini 兼容预设。",
                                "`Google / Gemini Login` imports a personal Google account supported by the official Gemini CLI flow, including AI Pro / Ultra and personal free-tier auto-onboarding. These accounts are now reserved for Gemini CLI and the native Gemini endpoint only. `Manual Add` still handles compatible API key accounts, including OpenAI-compatible, Anthropic API-compatible, and Google Gemini-compatible presets."
                            ),
                        ],
                        action: accountsAction
                    ),
                    HelpDocument.Section(
                        id: "accounts-manage",
                        title: t("如何管理现有账号", "How to manage imported accounts"),
                        summary: t("每张账号卡片都对应一个独立可操作账号，可以单独刷新、编辑、启停或删除。", "Each account card is independently actionable and can be refreshed, edited, enabled/disabled, or removed."),
                        bullets: [
                            t("账号页顶部快捷操作里的 `测试代理` 也可以直接打开测试控制台，不必先切到代理页。", "The `Test Proxy` quick action at the top of Accounts can also open the test console directly, so you do not need to switch to Proxy first."),
                            t("`刷新用量` 会更新该账号的额度、计划和可用状态；对 API Key 账号只校验连接，不一定有标准用量数据。", "`Refresh Usage` updates quota, plan, and availability. For API key accounts it validates connectivity, but standard usage metrics may not exist."),
                            t("OAuth 账号支持编辑名称；手动 API Key 账号支持重新编辑上游地址和 Key。", "OAuth accounts can be renamed, and manual API key accounts can be edited with a new upstream base URL or key."),
                            t("停用账号后，这个账号会保留在本地，但不会再被路由层选中；移除授权则会从账号池里删除。", "Disabling an account keeps it locally but removes it from routing. Removing authorization deletes it from the account pool."),
                            t("如果你需要控制请求优先使用哪几个账号，可使用调整使用顺序功能来改变账号池遍历顺序。", "If you need to control which accounts are tried first, use the account-order management flow to change routing order."),
                        ],
                        action: accountsAction
                    ),
                    HelpDocument.Section(
                        id: "accounts-status",
                        title: t("状态徽标和异常提示代表什么", "What the badges and issue text mean"),
                        summary: t("账号卡片上的标签能快速告诉你这个账号是否适合继续用于代理流量。", "The badges on each account card are intended to quickly tell you whether the account is still fit for routing traffic."),
                        bullets: [
                            t("计划标签会区分 `free / plus / pro / api_key`；`Current` 表示它与当前授权源一致。", "Plan badges differentiate `free / plus / pro / api_key`, and `Current` means the card matches the current local auth source."),
                            t("`启用/停用` 表示该账号是否参与路由；`刷新受阻` 通常代表该账号无法正常刷新授权。", "`Enabled/Disabled` tells you whether routing can still use the account. `Refresh Blocked` usually means the auth refresh path is no longer healthy."),
                            t("如果额度被挡住、API Key 冷却中，卡片底部会出现明确的时间或错误说明。", "If quota is blocked or an API key is cooling down, the card shows explicit timing or error text near the bottom."),
                        ],
                        action: nil
                    ),
                ]
            ),
            HelpDocument.Topic(
                id: .proxy,
                title: self.pageTitle(.proxy),
                subtitle: self.pageSubtitle(.proxy),
                eyebrow: t("客户端接入", "Client Access"),
                overview: t("代理页既是客户端真正要接入的地方，也是多 Key 管理、Key 用量统计、详细日志和本地联调工具的总入口。", "Proxy is where clients actually connect, and it is also the hub for local key management, per-key usage analytics, detailed logs, and test tooling."),
                actions: [proxyAction, requestLogsAction, proxyTestAction],
                steps: [],
                sections: [
                    HelpDocument.Section(
                        id: "proxy-access",
                        title: t("如何获取代理 Base URL 和本地 API Key", "How to get the proxy Base URL and local API key"),
                        summary: t("客户端不是直接连账号池里的上游，而是统一连到本地代理页给出的地址和 Key。", "Clients do not connect directly to upstream accounts. They connect to the local proxy endpoint and key shown on this page."),
                        bullets: [
                            t("在 `接入信息` 里复制 `OpenAI 兼容根地址`，常见客户端把它当作 Base URL。", "Copy the `OpenAI Base URL` from Access Info; most clients use it as the Base URL."),
                            t("同一页也会给出 `Anthropic 根地址` 与 `Claude Code 环境变量片段`，以及 `Gemini 根地址` 与 `Gemini CLI 环境变量片段`，方便 Claude / Gemini 兼容场景。", "The same area also exposes the Anthropic root URL and a Claude Code environment snippet, plus the Gemini root URL and a Gemini CLI environment snippet for Claude- and Gemini-compatible clients."),
                            t("页面复制按钮默认使用当前主本地 API Key；如果你在 Key 管理里切换了默认 Key，这里也会同步变化。", "The copy buttons use the current primary local API key. If you change the primary key in key management, the copied values update with it."),
                        ],
                        action: proxyAction
                    ),
                    HelpDocument.Section(
                        id: "proxy-key-management",
                        title: t("如何做多 Key 管理", "How to manage multiple local keys"),
                        summary: t("本地 API Key 是发给客户端或团队成员的访问凭证，不等于上游账号里的真实 Key。", "Local proxy API keys are the credentials you hand to clients or teammates. They are not the same as upstream account keys."),
                        bullets: [
                            t("在 `API Keys` 子标签可以新增、编辑、删除本地 Key，并为不同用户或工具分配不同的访问凭证。", "Use the `API Keys` tab to add, edit, remove, and split local keys across users or tools."),
                            t("每个 Key 都可以单独启用或停用；至少要保留一个启用中的本地 Key，客户端才能继续访问代理。", "Each key can be enabled or disabled independently. At least one enabled local key must remain for clients to keep using the proxy."),
                            t("`设为默认` 会影响复制按钮、环境变量片段和测试控制台默认使用的 Key。", "`Set as Primary` changes what the copy buttons, environment snippets, and test console use by default."),
                            t("`轮换 API Key` 或 `重新生成` 适合在泄漏风险、权限轮换或人员变更时快速替换本地凭证。", "`Rotate API Key` and `Regenerate` are useful when you need to replace local credentials because of leaks, handoffs, or security rotation."),
                        ],
                        action: proxyAction
                    ),
                    HelpDocument.Section(
                        id: "proxy-usage",
                        title: t("如何查看多 Key 用量", "How to inspect multi-key usage"),
                        summary: t("Key 用量视图按本地 API Key 聚合请求量、失败率、token 用量和平均延迟。", "The usage view aggregates request counts, failure rate, total tokens, and latency per local API key."),
                        bullets: [
                            t("支持按今天、本周、本月和自定义时间范围查看；自定义会弹出时间范围选择器。", "Use today, week, month, or a custom time range. Custom ranges open a dedicated date-range picker."),
                            t("你可以快速识别哪个 Key 请求最多、失败率最高、最近是否仍在被使用。", "You can quickly see which key is busiest, which one fails most often, and whether it was used recently."),
                            t("当你需要下钻到单条请求时，直接从这里打开详细日志窗口即可。", "When you need to drill into individual requests, jump straight into the detailed logs window from here."),
                        ],
                        action: requestLogsAction
                    ),
                    HelpDocument.Section(
                        id: "proxy-tools",
                        title: t("日志、测试控制台和高级路由", "Detailed logs, test console, and advanced routing"),
                        summary: t("代理页顶部工具区和高级子标签适合排查“请求到了没有、路由到了谁，以及本地网络设置是否正确”。", "Use the top utility buttons and the advanced tab to answer whether requests arrived, which account they routed to, and whether the local network settings are correct."),
                        bullets: [
                            t("`详细日志` 会按请求显示时间、endpoint、模型、账号标签、API Key、耗时和错误摘要。", "`Detailed Logs` shows request time, endpoint, model, account label, API key, latency, and any error summary."),
                            t("`测试代理` 会打开测试控制台，用当前本地服务和 Key 直接发请求验证结果。", "`Test Proxy` opens the test console so you can send a request through the current local service and key."),
                            t("高级子标签现在只保留 Anthropic 模型映射和本地网络设置，适合 Claude 模型兼容和端口调整。Gemini CLI 的 loop detection 依赖 thought-aware 流协议，代理现在已经按这套语义对齐，并额外保持 Gemini CLI 会话粘性、为工具调用补兼容 thought signature。", "The advanced tab now keeps only Anthropic model mapping and local network settings for Claude compatibility and port tuning. Gemini CLI loop detection depends on thought-aware streaming semantics, and the proxy now aligns with that contract while also keeping Gemini CLI sessions sticky and attaching compatibility thought signatures on tool calls."),
                        ],
                        action: proxyTestAction
                    ),
                ]
            ),
            HelpDocument.Topic(
                id: .settings,
                title: self.pageTitle(.settings),
                subtitle: self.pageSubtitle(.settings),
                eyebrow: t("本地设置", "Local Settings"),
                overview: t("设置页控制桌面端体验、本地 daemon 行为，以及最关键的出站代理模式。", "Settings controls the desktop experience, local daemon behavior, and the most important outbound proxy options."),
                actions: [settingsAction, managedProxyAction],
                steps: [],
                sections: [
                    HelpDocument.Section(
                        id: "settings-general",
                        title: t("外观、通用和服务行为", "Appearance, general options, and service behavior"),
                        summary: t("这些配置不直接改变账号池内容，但会影响桌面端展示、关闭方式和服务启动体验。", "These controls do not change the account pool itself, but they do affect the desktop experience, close behavior, and how the service starts."),
                        bullets: [
                            t("外观子标签里可以切换语言和主题，切换后主界面与独立窗口都会立刻刷新。", "Use the Appearance tab to switch language and theme; both the shell and auxiliary windows refresh immediately."),
                            t("通用子标签里可以调整 ChatGPT 根地址、daemon 二进制覆盖路径、统计保留天数、自动启动和关闭行为。", "The General area covers ChatGPT base URL, daemon binary overrides, stats retention, auto-start, and the close action."),
                            t("服务子标签会显示 launchctl 状态、本地日志路径和最近一次启动错误，适合排查为什么服务没起来。", "The Service tab exposes launchctl state, local log paths, and the most recent startup failure, making it the best place to debug service boot issues."),
                        ],
                        action: settingsAction
                    ),
                    HelpDocument.Section(
                        id: "settings-outbound-modes",
                        title: t("出站代理三种模式怎么选", "How to choose between the outbound proxy modes"),
                        summary: t("这里决定 daemon 发往上游接口时是否直连、走你自己的代理端口，或走订阅节点。", "These settings determine whether daemon requests to upstream APIs connect directly, use your own proxy endpoint, or use subscription-backed nodes."),
                        bullets: [
                            t("`Disabled` 表示 daemon 直接连上游，不使用任何手工代理或订阅代理。", "`Disabled` means the daemon connects directly to upstream APIs with no manual or subscription proxy."),
                            t("`Manual` 适合你已经有稳定可用的 HTTP / HTTPS / SOCKS5 代理端口。", "`Manual` is for situations where you already have a reliable HTTP / HTTPS / SOCKS5 proxy endpoint."),
                            t("`Subscription` 适合通过订阅管理节点、测速与固定出口地区，尤其适合担心地区链路被屏蔽时。", "`Subscription` is best when you want managed nodes, health checks, and a pinned egress region, especially when region-based blocking is a concern."),
                        ],
                        action: settingsAction
                    ),
                    HelpDocument.Section(
                        id: "settings-manual-proxy",
                        title: t("Manual 模式怎么填", "How to fill Manual mode"),
                        summary: t("Manual 模式会让 daemon 用你指定的代理服务作为所有上游请求的出口。", "Manual mode routes daemon egress through the proxy service you specify."),
                        bullets: [
                            t("`scheme` 选择代理协议，支持 `HTTP / HTTPS / SOCKS5`。", "`scheme` selects the proxy protocol and supports `HTTP / HTTPS / SOCKS5`."),
                            t("`host / port` 是代理服务的地址与端口；`username / password` 只在你的代理需要认证时填写。", "`host / port` point to the proxy service, while `username / password` are only needed when that proxy requires authentication."),
                            t("保存后新的出站规则会作用于 daemon 后续请求；如果服务当前未运行，等你启动后同样会按这里的配置连出。", "After saving, future daemon requests use the new egress rule. If the service is currently stopped, the same rule will apply when you start it later."),
                        ],
                        action: settingsAction
                    ),
                    HelpDocument.Section(
                        id: "settings-subscription-proxy",
                        title: t("Subscription 模式和管理订阅窗口", "Subscription mode and the Manage Subscription window"),
                        summary: t("设置页决定默认全局出口是否启用 Subscription 模式；管理订阅窗口则独立负责 mihomo 订阅地址、节点和监听端口。即使全局不在 Subscription，账号页里已设置的自定义出站节点也能单独覆盖。", "Settings decides whether Subscription mode is the default global egress, while Manage Subscription independently handles the mihomo URL, nodes, and listener ports. Even when the global mode is not Subscription, saved account-level outbound nodes can still override it."),
                        bullets: [
                            t("`管理订阅` 按钮固定放在设置页“出站代理”卡片右上角，你不需要先切到 `Subscription` 模式才能打开它。", "The Manage Subscription button stays in the top-right corner of the Outbound Proxy card in Settings, so you do not have to switch to `Subscription` mode before opening it."),
                            t("只要本地 daemon 正在运行，且你已保存订阅地址，mihomo 就会在后台自动就绪；这不会自动改变当前全局生效模式。", "As long as the local daemon is running and a subscription URL is saved, mihomo stays ready in the background without changing the active global mode on its own."),
                            t("管理窗口会显示当前节点、固定默认节点、可用状态、测速结果，以及 mihomo 当前真实代理监听地址和端口；这些节点既可作为全局 Subscription 默认出口，也可供账号页的自定义出站节点单独复用。", "The manager window shows the current node, pinned default node, availability, health-check results, and every live mihomo proxy listener address and port. Those nodes can serve both as the global Subscription default and as account-level outbound overrides."),
                        ],
                        action: managedProxyAction
                    ),
                ]
            ),
            HelpDocument.Topic(
                id: .tools,
                title: t("辅助窗口", "Tools & Windows"),
                subtitle: t("除了主界面，应用还提供几个独立窗口来处理更聚焦的诊断和操作任务。", "In addition to the main shell, the app provides several dedicated windows for focused diagnostics and operations."),
                eyebrow: t("独立窗口", "Auxiliary Windows"),
                overview: t("这些窗口都支持单独打开、独立关闭，并跟随当前桌面主题和语言。", "Each of these windows opens independently, closes independently, and follows the current desktop theme and language."),
                actions: [requestLogsAction, proxyTestAction, managedProxyAction],
                steps: [],
                sections: [
                    HelpDocument.Section(
                        id: "tools-managed-proxy",
                        title: self.managedProxyManagerWindowTitle,
                        summary: t("管理订阅窗口现在是完整的订阅节点控制台，专门处理地址、更新、当前节点、固定默认节点、监听端口和 mihomo 日志。", "The subscription manager window now acts as a full subscription node console for the URL, provider refreshes, current nodes, pinned defaults, listener ports, and mihomo logs."),
                        bullets: [
                            t("这里能保存订阅地址并立即应用，也能手动刷新订阅、切换当前节点、设置或取消固定默认节点。", "You can save the subscription URL and apply it immediately, refresh the provider manually, switch the current node, and set or clear the pinned default node."),
                            t("监听端口区会列出 mihomo 当前真实代理监听地址和端口，并可逐条复制终端代理命令。", "The listener-ports section lists every live mihomo proxy listener address and port and lets you copy a terminal proxy command for each one."),
                            t("当 subscription 行为异常时，优先来这里刷新快照并查看 mihomo 日志；如果本地 daemon 已停止，则去总览或设置页恢复服务。", "When subscription behavior looks wrong, start here by refreshing the snapshot and inspecting the mihomo logs. If the local daemon is offline, restart it from Overview or Settings."),
                        ],
                        action: managedProxyAction
                    ),
                    HelpDocument.Section(
                        id: "tools-request-logs",
                        title: self.text(.requestLogsTitle),
                        summary: t("请求详细日志窗口按请求粒度记录元数据，适合核对路由和性能问题。", "The request-log window stores request metadata at per-request granularity and is ideal for routing and performance investigations."),
                        bullets: [
                            t("它支持按时间范围、本地 API Key、账号标签和模型过滤。", "It supports filtering by time range, local API key, account label, and model."),
                            t("表格里会展示时间、endpoint、模型、账号标签、耗时、HTTP 状态和错误摘要。", "The table shows time, endpoint, model, account label, latency, HTTP status, and error summary."),
                            t("这里不保存 prompt 或响应正文，只保存排查代理问题所需的请求元数据。如果 Gemini CLI 提示 `A potential loop was detected`，那是 Gemini CLI 前端自己的检测，不是代理直接抛出的错误；代理侧会通过会话粘性和工具调用兼容 signature 尽量降低触发概率，这时也可以先回到这里确认代理是否仍在正常路由。", "It does not store prompt or response bodies, only the metadata needed to debug proxy behavior. If Gemini CLI shows `A potential loop was detected`, that warning comes from Gemini CLI itself rather than the proxy. The proxy reduces the chance by keeping sessions sticky and adding compatibility signatures on tool calls; use request logs here to confirm whether routing is still healthy."),
                        ],
                        action: requestLogsAction
                    ),
                    HelpDocument.Section(
                        id: "tools-proxy-test",
                        title: self.text(.proxyTestTitle),
                        summary: t("测试控制台适合在不切换到外部客户端的情况下直接验证当前代理是否工作正常。", "The test console lets you validate the active proxy path without switching to an external client."),
                        bullets: [
                            t("它会先检查本地服务健康，再加载可用模型目录。", "It first checks local daemon health and then loads the available model catalog."),
                            t("你可以直接测试 Chat Completions、Responses、Anthropic Messages 和 Gemini Generate Content 四类接口。", "You can directly test Chat Completions, Responses, Anthropic Messages, and Gemini Generate Content."),
                            t("结果区会给出请求预览、耗时、HTTP 状态、流式转录与原始响应。", "The result area shows the request preview, latency, HTTP status, streaming transcript, and raw response."),
                        ],
                        action: proxyTestAction
                    ),
                ]
            ),
        ]

        if self.isRemoteManagementUnlocked {
            let remoteAction = action(
                "open-remote",
                t("打开 \(self.pageTitle(.remote))", "Open \(self.pageTitle(.remote))"),
                target: .page(.remote),
                isPrimary: true
            )
            topics.insert(
                HelpDocument.Topic(
                    id: .remote,
                    title: self.pageTitle(.remote),
                    subtitle: self.pageSubtitle(.remote),
                    eyebrow: t("远程部署", "Remote Deploy"),
                    overview: t("远程页适合把同一套代理服务部署或重新部署到远端主机，并在桌面端持续查看远程状态和日志。", "Remote is where you deploy or redeploy the same proxy stack to a remote host and keep monitoring its state and logs from the desktop app."),
                    actions: [remoteAction],
                    steps: [],
                    sections: [
                        HelpDocument.Section(
                            id: "remote-host",
                            title: t("先整理主机与连接配置", "Start with host and connection setup"),
                            summary: t("Remote 页现在按四步向导组织：先选主机，再整理连接配置，然后做部署前验证。", "Remote now uses a four-step wizard: choose a host, refine its connection config, then run deployment readiness checks."),
                            bullets: [
                                t("主机管理步骤可以在已保存主机之间切换，也可以新建或删除远程主机配置。", "The host management step lets you switch between saved hosts and create or remove remote host configs."),
                                t("你需要至少填写主机地址、SSH 用户、SSH 端口和认证方式；标签可以为空。", "At a minimum you need a host, SSH user, SSH port, and an authentication method; the label can stay empty."),
                                t("认证支持密码、私钥文件路径和直接粘贴私钥内容三种模式。", "Authentication supports password, SSH key path, and pasted private key content."),
                                t("远端目录、公开端口和管理端口决定远程服务最终安装与对外暴露的位置。", "The remote directory plus public/admin ports determine where the remote service is installed and exposed."),
                            ],
                            action: remoteAction
                        ),
                        HelpDocument.Section(
                            id: "remote-runtime",
                            title: t("先验证，再部署和运维", "Verify before deploy and runtime control"),
                            summary: t("保存主机后，先做 SSH / sudo / systemd / 目录 / 应用内置 Linux 部署包验证。只要 SSH、sudo、systemd 和目录检查通过，就能进入运维步骤；如果当前构建缺少内置部署包，`Deploy` / `重新部署` 会保持禁用。", "Once a host is saved, first verify SSH, sudo, systemd, directory access, and the bundled Linux deployment package inside the app. Runtime operations unlock as soon as the SSH, sudo, systemd, and directory checks pass; if this build lacks bundled Linux artifacts, `Deploy` / `Redeploy` stays disabled."),
                            bullets: [
                                t("验证步骤会直接告诉你远端架构、当前远程用户，以及 systemctl、sudo、目录权限和应用内置部署包是否就绪。", "The verification step shows the remote architecture, remote user, and whether systemctl, sudo, directory access, and the bundled deploy package are ready."),
                                t("`部署` 会直接使用应用内置的完整 Linux 部署包和服务配置推到目标机器；如果远端已经安装过，同一个按钮会切换成 `重新部署`，用于刷新旧的远程代理服务、二进制和 systemd 配置。", "`Deploy` pushes the bundled Linux deployment package and service config directly from the app; once the remote host is already installed, the same button switches to `Redeploy` so you can refresh the existing remote proxy service, binaries, and systemd configuration."),
                                t("如果当前构建缺少这份部署包，你仍可进入最后一步加载状态、查看日志并管理已部署服务。", "If the current build lacks that bundle, you can still move into the final step to load status, inspect logs, and manage an already deployed service."),
                                t("状态卡会告诉你远程服务是否已安装、是否运行中、架构是什么，以及当前 Base URL / API Key。", "The status tiles show whether the service is installed, whether it is running, the remote architecture, and the exposed Base URL / API key."),
                                t("只要远端已经部署完成，最后一步就可以直接启动、停止、刷新状态、拉取当前主机日志，并在服务运行时打开远端管理台。", "Once the remote host is already deployed, the final step lets you start, stop, refresh status, fetch logs for the current host, and open Remote Admin while the service is running."),
                            ],
                            action: remoteAction
                        ),
                    ]
                ),
                at: topics.count - 1
            )
        }

        return HelpDocument(
            title: self.helpWindowTitle,
            subtitle: t(
                "先用帮助页了解结构，再用新手引导一步步完成账号、网络和客户端接入。",
                "Use Help to learn the structure, then use onboarding to complete accounts, networking, and client setup step by step."
            ),
            quickActions: quickActions,
            topics: topics
        )
    }
}
#endif
