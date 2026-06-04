#if os(macOS)
import SwiftUI

// MARK: - Main View

struct AssistantView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var service: AssistantChatService
    @State private var scrollPublisher = UUID()
    @State private var showAccessPanel = false
    @State private var isChatPinnedToBottom = true
    @State private var pendingForceScrollToBottom = false
    @State private var isFollowingCurrentTurn = false
    private let chatBottomID = "assistant-chat-bottom"

    init(model: DesktopAppModel) {
        self.model = model
        self.service = model.assistantChatService
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        GeometryReader { proxy in
            ZStack {
                ShellBackground()

                HStack(spacing: 0) {
                    self.sidebar(palette: palette)
                        .frame(width: 300)
                        .background(palette.panel.opacity(self.colorScheme == .dark ? 0.4 : 0.3))

                    Divider()

                    self.chatArea(palette: palette)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .compactOverlayScrollbars()
        .onAppear {
            self.service.configureWelcomeIfNeeded()
            self.requestScrollToBottom(force: true)
        }
    }

    // MARK: - Sidebar

    private func sidebar(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self.sidebarHeader(palette: palette)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    self.statusSection(palette: palette)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    self.quickActionsSection(palette: palette)
                        .padding(.horizontal, 16)

                    self.accessInfoSection(palette: palette)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private func sidebarHeader(palette: AppearancePalette) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(palette.accent.opacity(self.colorScheme == .dark ? 0.2 : 0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(self.model.localized(zh: "AI 助手", en: "Assistant"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Text(self.model.localized(zh: "对话即可操作", en: "Chat to operate"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textMuted)
            }

            Spacer()
        }
    }

    private func statusSection(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.model.localized(zh: "当前状态", en: "Status"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.textMuted)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 8) {
                StatusRow(
                    label: self.model.localized(zh: "服务", en: "Service"),
                    value: self.model.localServicePrimaryStatusText,
                    tone: self.model.localServicePrimaryStatusText.contains("运行") ? .success : .warning,
                    palette: palette
                )

                StatusRow(
                    label: self.model.localized(zh: "可用账号", en: "Accounts"),
                    value: self.service.availableAccountCountText,
                    tone: self.service.availableAccountCount == 0 ? .warning : .success,
                    palette: palette
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.6 : 0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(palette.border.opacity(0.5), lineWidth: 1)
            )
        }
    }

    private func quickActionsSection(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.model.localized(zh: "快捷操作", en: "Quick Actions"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.textMuted)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(spacing: 4) {
                SidebarActionRow(
                    icon: "link",
                    title: self.model.localized(zh: "查看接入信息", en: "Access Info"),
                    palette: palette
                ) {
                    self.sendAndFollow(self.model.localized(zh: "查看地址和 Key", en: "Show endpoint and key"))
                }

                SidebarActionRow(
                    icon: "person.badge.plus",
                    title: self.model.localized(zh: "添加账号", en: "Add Account"),
                    palette: palette
                ) {
                    self.sendAndFollow(self.model.localized(zh: "帮我添加一个账号", en: "Help me add an account"))
                }

                SidebarActionRow(
                    icon: "arrow.clockwise",
                    title: self.model.localized(zh: "刷新账号池", en: "Refresh Accounts"),
                    palette: palette
                ) {
                    Task { await self.service.refreshEnvironment() }
                }

                SidebarActionRow(
                    icon: "play.circle",
                    title: self.model.localized(zh: self.model.localCanStartService ? "启动服务" : "停止服务", en: self.model.localCanStartService ? "Start Service" : "Stop Service"),
                    palette: palette
                ) {
                    if self.model.localCanStartService {
                        self.sendAndFollow(self.model.localized(zh: "启动服务", en: "Start service"))
                    } else if self.model.localCanStopService {
                        self.sendAndFollow(self.model.localized(zh: "停止服务", en: "Stop service"))
                    }
                }

                SidebarActionRow(
                    icon: "doc.text.magnifyingglass",
                    title: self.model.localized(zh: "请求日志", en: "Request Logs"),
                    palette: palette
                ) {
                    self.model.openRequestLogsWindow()
                }

                SidebarActionRow(
                    icon: "wrench.and.screwdriver",
                    title: self.model.localized(zh: "代理测试", en: "Proxy Test"),
                    palette: palette
                ) {
                    self.model.openProxyTestConsole()
                }

                SidebarActionRow(
                    icon: "gearshape.2",
                    title: self.model.localized(zh: "客户端配置", en: "Client Config"),
                    palette: palette
                ) {
                    self.model.openClientConfigManagerWindow()
                }

                SidebarActionRow(
                    icon: "arrow.triangle.branch",
                    title: self.model.localized(zh: "项目路由", en: "Project Routes"),
                    palette: palette
                ) {
                    self.sendAndFollow(self.model.localized(zh: "查看项目路由", en: "Show project routes"))
                }

                SidebarActionRow(
                    icon: "server.rack",
                    title: self.model.localized(zh: "管理代理", en: "Managed Proxy"),
                    palette: palette
                ) {
                    self.model.openManagedProxyManagerWindow()
                }
            }
        }
    }

    private func accessInfoSection(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showAccessPanel.toggle()
                }
            } label: {
                HStack {
                    Text(self.model.localized(zh: "接入信息", en: "Access Info"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.textMuted)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Image(systemName: self.showAccessPanel ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                }
            }
            .buttonStyle(.plain)

            if self.showAccessPanel {
                VStack(alignment: .leading, spacing: 8) {
                    AccessInfoRow(
                        label: "OpenAI",
                        value: self.model.openAICompatibleBaseURL,
                        palette: palette
                    ) {
                        self.model.copyEndpoint()
                        self.service.lastSuccess = .init(title: "已复制 OpenAI 地址", detail: self.model.openAICompatibleBaseURL)
                    }

                    AccessInfoRow(
                        label: "Anthropic",
                        value: self.model.anthropicBaseURL,
                        palette: palette
                    ) {
                        self.model.copyAnthropicBaseURL()
                        self.service.lastSuccess = .init(title: "已复制 Anthropic 地址", detail: self.model.anthropicBaseURL)
                    }

                    AccessInfoRow(
                        label: "Gemini",
                        value: self.model.geminiBaseURL,
                        palette: palette
                    ) {
                        self.model.copyGeminiBaseURL()
                        self.service.lastSuccess = .init(title: "已复制 Gemini 地址", detail: self.model.geminiBaseURL)
                    }

                    AccessInfoRow(
                        label: "API Key",
                        value: self.model.localProxyAPIKeyValue,
                        isSensitive: true,
                        palette: palette
                    ) {
                        self.model.copyAPIKey()
                        self.service.lastSuccess = .init(title: "已复制 API Key", detail: nil)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Chat Area

    private func chatArea(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self.chatHeader(palette: palette)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 16)

            self.chatHistory(palette: palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 16)

            self.chatComposer(palette: palette)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private func chatHeader(palette: AppearancePalette) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.model.localized(zh: "对话", en: "Chat"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Text(self.model.localized(zh: "用自然语言描述需求，AI 会直接执行操作", en: "Describe needs in natural language; AI executes actions directly"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textMuted)
            }

            Spacer()

            if self.service.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(palette.accent)
                    Text(self.model.localized(zh: "处理中...", en: "Processing..."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(palette.accent.opacity(0.1)))
            }

            Button {
                self.service.messages.removeAll()
                self.service.configureWelcomeIfNeeded()
                self.requestScrollToBottom(force: true)
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help(self.model.localized(zh: "清空对话", en: "Clear chat"))
        }
    }

    private func chatHistory(palette: AppearancePalette) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(self.service.messages) { message in
                            AssistantBubbleView(
                                model: self.model,
                                message: message,
                                palette: palette,
                                colorScheme: self.colorScheme
                            )
                            .id(message.id)
                        }

                        if self.service.isRunning {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(palette.accent)
                                Text(self.model.localized(zh: "正在思考...", en: "Thinking..."))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(palette.textMuted)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(self.chatBottomID)
                            .background(
                                GeometryReader { bottomProxy in
                                    Color.clear.preference(
                                        key: AssistantChatBottomOffsetKey.self,
                                        value: bottomProxy.frame(in: .named("assistantChatScroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .coordinateSpace(name: "assistantChatScroll")
                .background(palette.consoleBackground.opacity(self.colorScheme == .dark ? 0.3 : 0.15))
                .onPreferenceChange(AssistantChatBottomOffsetKey.self) { bottomMaxY in
                    let threshold: CGFloat = 80
                    self.isChatPinnedToBottom = bottomMaxY <= viewport.size.height + threshold
                }
                .onChange(of: self.scrollPublisher) { _, _ in
                    self.performScrollToBottomIfNeeded(proxy: proxy)
                }
                .onChange(of: self.service.messages.count) { _, _ in
                    switch self.service.messages.last?.role {
                    case .user:
                        self.isFollowingCurrentTurn = true
                        self.pendingForceScrollToBottom = true
                    case .assistant:
                        if self.isFollowingCurrentTurn {
                            self.pendingForceScrollToBottom = true
                        }
                    case .system, .none:
                        break
                    }
                    self.requestScrollToBottom()
                }
                .onChange(of: self.service.isRunning) { oldValue, newValue in
                    if oldValue == true, newValue == false {
                        self.pendingForceScrollToBottom = self.isFollowingCurrentTurn
                        self.requestScrollToBottom()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            self.isFollowingCurrentTurn = false
                        }
                    } else {
                        self.requestScrollToBottom()
                    }
                }
            }
        }
    }

    private func chatComposer(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            self.suggestionChips(palette: palette)

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.7 : 0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    self.service.inputText.isEmpty
                                        ? palette.border.opacity(0.5)
                                        : palette.accent.opacity(0.4),
                                    lineWidth: 1
                                )
                        )

                    TextEditor(text: $service.inputText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minHeight: 42, maxHeight: 120)
                        .background(Color.clear)

                    if self.service.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(self.model.localized(zh: "输入你的需求，例如 '查看可用账号'", en: "Type your request, e.g. 'show available accounts'"))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(palette.textMuted.opacity(0.6))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 42, maxHeight: 120)

                HStack(spacing: 6) {
                    Button {
                        self.service.sendCurrentInput()
                        self.isFollowingCurrentTurn = true
                        self.requestScrollToBottom(force: true)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(
                                self.service.canSend
                                    ? palette.accent
                                    : palette.textMuted.opacity(0.3)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.service.canSend)
                    .keyboardShortcut(.return, modifiers: .command)

                    if self.service.isRunning {
                        Button {
                            self.service.cancel()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(palette.danger)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func suggestionChips(palette: AppearancePalette) -> some View {
        let suggestions: [(String, String)] = [
            ("查看状态", "查看当前状态"),
            ("添加账号", "帮我添加一个账号"),
            ("复制地址", "查看地址和 Key"),
            ("项目路由", "查看项目路由"),
            ("启动服务", "启动服务"),
            ("查看日志", "打开请求日志"),
            ("环境变量", "复制 Claude Code 环境变量"),
        ]

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.0) { display, query in
                    Button {
                        self.sendAndFollow(query)
                    } label: {
                        Text(display)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(palette.panelMuted.opacity(self.colorScheme == .dark ? 0.8 : 0.9)))
                            .overlay(Capsule().stroke(palette.border.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(self.service.isRunning)
                }
            }
        }
    }

    private func requestScrollToBottom(force: Bool = false) {
        if force {
            self.pendingForceScrollToBottom = true
        }
        self.scrollPublisher = UUID()
    }

    private func performScrollToBottomIfNeeded(proxy: ScrollViewProxy) {
        guard self.pendingForceScrollToBottom || self.isChatPinnedToBottom else { return }
        let shouldForce = self.pendingForceScrollToBottom
        if shouldForce == false {
            self.pendingForceScrollToBottom = false
        }
        self.scrollToBottom(proxy: proxy)
        if shouldForce {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.scrollToBottom(proxy: proxy)
                self.pendingForceScrollToBottom = false
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(self.chatBottomID, anchor: .bottom)
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(self.chatBottomID, anchor: .bottom)
            }
        }
    }

    private func sendAndFollow(_ text: String) {
        self.isFollowingCurrentTurn = true
        self.service.send(text, model: self.model)
        self.requestScrollToBottom(force: true)
    }
}

private struct AssistantChatBottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Bubble View

private struct AssistantBubbleView: View {
    let model: DesktopAppModel
    let message: AssistantMessage
    let palette: AppearancePalette
    let colorScheme: ColorScheme

    var body: some View {
        let isUser = message.role == .user

        HStack(alignment: .top, spacing: 10) {
            if !isUser { assistantAvatar }
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                self.messageContent(isUser: isUser)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground(isUser: isUser))
                    .overlay(bubbleBorder(isUser: isUser))

                Text(timeString)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textMuted.opacity(0.6))
                    .padding(.horizontal, 4)
            }

            if isUser { userAvatar }
            if !isUser { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private func messageContent(isUser: Bool) -> some View {
        if isUser {
            Text(message.text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            AssistantMarkdownView(
                text: message.text,
                palette: palette,
                colorScheme: colorScheme
            )
        }
    }

    private var assistantAvatar: some View {
        ZStack {
            Circle()
                .fill(palette.accent.opacity(colorScheme == .dark ? 0.2 : 0.12))
                .frame(width: 30, height: 30)
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
    }

    private var userAvatar: some View {
        ZStack {
            Circle()
                .fill(palette.success.opacity(colorScheme == .dark ? 0.2 : 0.12))
                .frame(width: 30, height: 30)
            Image(systemName: "person.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.success)
        }
    }

    private func bubbleBackground(isUser: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                isUser
                    ? palette.accent.opacity(colorScheme == .dark ? 0.18 : 0.1)
                    : palette.panel.opacity(colorScheme == .dark ? 0.7 : 0.95)
            )
    }

    private func bubbleBorder(isUser: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isUser
                    ? palette.accent.opacity(colorScheme == .dark ? 0.25 : 0.12)
                    : palette.border.opacity(0.4),
                lineWidth: 1
            )
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.createdAt)
    }
}

// MARK: - Sidebar Components

private struct StatusRow: View {
    let label: String
    let value: String
    let tone: StatusPill.Tone
    let palette: AppearancePalette

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colorForTone)
        }
    }

    private var colorForTone: Color {
        switch tone {
        case .success: return palette.success
        case .warning: return palette.warning
        case .danger: return palette.danger
        case .accent: return palette.accent
        case .neutral: return palette.textSecondary
        }
    }
}

private struct SidebarActionRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let title: String
    let palette: AppearancePalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textMuted.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AccessInfoRow: View {
    let label: String
    let value: String
    var isSensitive: Bool = false
    let palette: AppearancePalette
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
            }

            Text(isSensitive ? maskSensitive(value) : value)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.fieldBackground.opacity(0.5))
        )
    }

    private func maskSensitive(_ value: String) -> String {
        guard value.count > 8 else { return "****" }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)****\(suffix)"
    }
}
#endif
