#if os(macOS)
import CodexProxyCore
import SwiftUI

struct RemoteAdminWindowView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: RemoteAdminWindowModel

    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ShellBackground()

                VStack(alignment: .leading, spacing: 18) {
                    RemoteAdminHeaderCard(model: self.model, onClose: self.onClose)

                    ZStack {
                        RemoteAdminWorkspaceShell(model: self.model)

                        if self.model.contentIsBlocked {
                            self.blockingOverlay
                                .padding(24)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 18)
            }
            .overlay(alignment: .topTrailing) {
                ToastStackView(
                    banners: self.model.appModel.banners,
                    dismissTitle: self.model.appModel.text(.commonDismiss),
                    topPadding: proxy.safeAreaInsets.top + 18,
                    trailingPadding: self.toastTrailingPadding
                ) { id in
                    self.model.appModel.dismissBanner(id: id)
                }
            }
        }
        .frame(minWidth: 1320, minHeight: 860)
        .compactOverlayScrollbars()
    }

    private var blockingOverlay: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return VStack(alignment: .center, spacing: 12) {
            if self.model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Text(self.blockingTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(palette.textPrimary)

            Text(self.blockingDetail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button(self.model.localized(zh: "立即重连", en: "Reconnect Now")) {
                Task { await self.model.reconnect() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
            .disabled(self.model.isRefreshing)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("remote-admin-blocking-overlay")
    }

    private var blockingTitle: String {
        switch self.model.sessionState.reachabilityStatus {
        case .failed:
            return self.model.localized(zh: "远端管理暂不可用", en: "Remote admin is unavailable")
        case .reconnecting:
            return self.model.localized(zh: "正在重连远端管理", en: "Reconnecting remote admin")
        case .unknown:
            return self.model.localized(zh: "正在建立远端管理会话", en: "Starting the remote admin session")
        case .reachable:
            return ""
        }
    }

    private var blockingDetail: String {
        switch self.model.sessionState.reachabilityStatus {
        case .failed(let detail):
            return detail.isEmpty
                ? self.model.localized(
                    zh: "SSH 隧道或远端 admin 当前不可达，请检查服务状态后重试。",
                    en: "The SSH tunnel or the remote admin is currently unreachable. Verify the service status and try again."
                )
                : detail
        case .reconnecting:
            return self.model.localized(
                zh: "正在重新建立 SSH 隧道并重新读取远端 admin token。",
                en: "Re-establishing the SSH tunnel and reloading the remote admin token."
            )
        case .unknown:
            return self.model.localized(
                zh: "首次打开会读取远端 token，并把主窗口镜像页面切到当前远端主机。",
                en: "The first load reads the remote token and prepares a main-window style workspace for the current host."
            )
        case .reachable:
            return ""
        }
    }

    private var toastTrailingPadding: CGFloat {
        let basePadding: CGFloat = 20
        guard self.isAccountPoolDetailDrawerVisible else {
            return basePadding
        }
        return basePadding + AccountsView.accountPoolDetailDrawerWidth + 18
    }

    private var accountPoolDetailDrawerAccount: AccountSummary? {
        guard self.model.selectedPage == .accounts,
              self.model.appModel.accountPoolDisplayMode == .list,
              self.model.appModel.isAccountPoolDetailDrawerPresented
        else {
            return nil
        }
        return self.model.appModel.selectedAccountPoolAccount
    }

    private var isAccountPoolDetailDrawerVisible: Bool {
        self.accountPoolDetailDrawerAccount != nil
    }
}

private struct RemoteAdminWorkspaceShell: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: RemoteAdminWindowModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: 0) {
            self.sidebar(palette: palette)

            ZStack(alignment: .topTrailing) {
                ShellBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        self.pageContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RemoteAdminWorkspaceDetailFrameProbe())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                .accessibilityIdentifier("remote-admin-workspace-detail")

                if let account = self.accountPoolDetailDrawerAccount {
                    Rectangle()
                        .fill(Color.black.opacity(self.colorScheme == .dark ? 0.26 : 0.14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.model.appModel.dismissAccountPoolDetailDrawer()
                        }
                        .transition(.opacity)
                        .accessibilityIdentifier("remote-admin-account-drawer-backdrop")

                    AccountPoolDetailDrawer(
                        model: self.model.appModel,
                        account: account,
                        width: AccountsView.accountPoolDetailDrawerWidth
                    )
                    .padding(.top, 24)
                    .padding(.trailing, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityIdentifier("remote-admin-account-drawer")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.52 : 0.74))
        )
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.88), value: self.accountPoolDetailDrawerAccount != nil)
        .accessibilityIdentifier("remote-admin-workspace-shell")
    }

    private func sidebar(palette: AppearancePalette) -> some View {
        ZStack {
            LinearGradient(
                colors: [palette.sidebarTop, palette.sidebarBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 14) {
                Text(self.model.localized(zh: "远端工作台", en: "Remote Workspace"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.textMuted)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("remote-admin-sidebar-title")

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(RemoteAdminWindowModel.Page.allCases) { page in
                            SidebarPageButton(
                                icon: page.symbolName,
                                title: self.model.title(for: page),
                                subtitle: self.model.subtitle(for: page),
                                isSelected: self.model.selectedPage == page
                            ) {
                                self.model.selectPage(page)
                            }
                            .accessibilityIdentifier("remote-admin-page-\(page.rawValue)")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(18)
        }
        .frame(minWidth: 268, idealWidth: 286, maxWidth: 314, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("remote-admin-sidebar")
    }

    @ViewBuilder
    private var pageContent: some View {
        switch self.model.selectedPage {
        case .overview:
            OverviewView(model: self.model.appModel)
                .accessibilityIdentifier("remote-admin-page-content-overview")
        case .accounts:
            AccountsView(
                model: self.model.appModel,
                presentationContext: .remoteAdmin,
                onImportLocalAccountsToRemote: {
                    Task { await self.model.importLocalAccountsToRemote() }
                }
            )
                .accessibilityIdentifier("remote-admin-page-content-accounts")
        case .proxy:
            ProxyView(model: self.model.appModel)
                .accessibilityIdentifier("remote-admin-page-content-proxy")
        case .outboundProxy:
            SettingsProxyPanel(model: self.model.appModel)
                .accessibilityIdentifier("remote-admin-page-content-outbound-proxy")
        }
    }

    private var accountPoolDetailDrawerAccount: AccountSummary? {
        guard self.model.selectedPage == .accounts,
              self.model.appModel.accountPoolDisplayMode == .list,
              self.model.appModel.isAccountPoolDetailDrawerPresented
        else {
            return nil
        }
        return self.model.appModel.selectedAccountPoolAccount
    }
}

private struct RemoteAdminWorkspaceDetailFrameProbe: NSViewRepresentable {
    private static let identifier = NSUserInterfaceItemIdentifier("remote-admin-workspace-detail-content")

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = Self.identifier
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = Self.identifier
    }
}

private struct RemoteAdminHeaderCard: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: RemoteAdminWindowModel

    let onClose: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: self.model.isHeaderExpanded ? 14 : 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        self.summaryStrip
                        self.actionsBar
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        self.summaryStrip
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            self.actionsBar
                        }
                    }
                }

                if self.model.isHeaderExpanded {
                    Rectangle()
                        .fill(palette.border.opacity(self.colorScheme == .dark ? 0.95 : 1.0))
                        .frame(height: 1)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            self.hostDetailsBlock
                            self.sessionDetailsBlock
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            self.hostDetailsBlock
                            self.sessionDetailsBlock
                        }
                    }

                    FormFieldPanel(
                        title: self.model.localized(zh: "能力边界", en: "Capability Scope"),
                        compact: true
                    ) {
                        QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            StatusPill(text: self.model.localized(zh: "远端 Overview", en: "Remote Overview"), tone: .success, compact: true)
                            StatusPill(text: self.model.localized(zh: "标准账号页", en: "Standard Accounts"), tone: .accent, compact: true)
                            StatusPill(text: self.model.localized(zh: "标准代理页", en: "Standard Proxy"), tone: .accent, compact: true)
                            StatusPill(text: self.model.localized(zh: "出站代理", en: "Outbound Proxy"), tone: .accent, compact: true)
                            StatusPill(text: self.model.localized(zh: "请求日志窗口", en: "Request Logs Window"), tone: .success, compact: true)
                            StatusPill(text: self.model.localized(zh: "管理订阅窗口", en: "Manage Subscription Window"), tone: .success, compact: true)
                            StatusPill(text: self.model.localized(zh: "OAuth 关闭", en: "OAuth Disabled"), tone: .warning, compact: true)
                            StatusPill(text: self.model.localized(zh: "本地账号一键导入", en: "One-Step Local Import"), tone: .success, compact: true)
                            StatusPill(text: self.model.localized(zh: "Proxy Test 可用", en: "Proxy Test Available"), tone: .success, compact: true)
                        }
                    }
                    .accessibilityIdentifier("remote-admin-header-capability-scope")
                }
            }
            .padding(self.model.isHeaderExpanded ? 16 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.985))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
            .shadow(
                color: palette.shadow.opacity(self.colorScheme == .dark ? 0.16 : 0.06),
                radius: 10,
                x: 0,
                y: 4
            )
            .accessibilityIdentifier("remote-admin-header-card")

            if let notice = self.model.adminPortResolutionNotice {
                RemoteAdminNotePanel(title: notice.title, notes: [notice.detail], tone: notice.tone)
                    .accessibilityIdentifier("remote-admin-header-admin-port-notice")
            }

            if let notice = self.model.summaryNotice {
                RemoteAdminNotePanel(title: notice.title, notes: [notice.detail], tone: notice.tone)
                    .accessibilityIdentifier("remote-admin-header-summary-notice")
            }
        }
    }

    private var summaryStrip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                self.model.isHeaderExpanded.toggle()
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    Text(self.model.localized(zh: "远端管理台", en: "Remote Admin"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(self.model.hostDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    self.summaryStatusPills

                    Spacer(minLength: 0)
                    self.expandCollapseIndicator
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(self.model.localized(zh: "远端管理台", en: "Remote Admin"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)

                        Text(self.model.hostDisplayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                        self.expandCollapseIndicator
                    }

                    self.summaryStatusPills
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interactiveCursor()
        .help(
            self.model.isHeaderExpanded
                ? self.model.localized(zh: "收起远端管理摘要", en: "Collapse the remote admin summary")
                : self.model.localized(zh: "展开远端管理摘要", en: "Expand the remote admin summary")
        )
        .accessibilityIdentifier("remote-admin-header-summary-strip")
    }

    private var summaryStatusPills: some View {
        HStack(spacing: 8) {
            StatusPill(text: self.model.tunnelStatusText, tone: self.model.tunnelStatusTone, compact: true)
            StatusPill(text: self.model.reachabilityText, tone: self.model.reachabilityTone, compact: true)
            StatusPill(text: self.model.daemonStatusText, tone: self.model.daemonStatusTone, compact: true)
        }
    }

    private var expandCollapseIndicator: some View {
        HStack(spacing: 6) {
            Text(
                self.model.isHeaderExpanded
                    ? self.model.localized(zh: "收起", en: "Collapse")
                    : self.model.localized(zh: "展开", en: "Expand")
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)

            Image(systemName: self.model.isHeaderExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var hostDetailsBlock: some View {
        FormFieldPanel(
            title: self.model.localized(zh: "主机身份", en: "Host Identity"),
            compact: true
        ) {
            VStack(alignment: .leading, spacing: 8) {
                CodeValueBlock(
                    label: self.model.localized(zh: "SSH Target", en: "SSH Target"),
                    value: self.model.sshEndpointText,
                    actionTitle: nil,
                    action: nil
                )
                CodeValueBlock(
                    label: self.model.localized(zh: "远端 endpoint", en: "Remote Endpoint"),
                    value: self.model.remoteEndpointText,
                    actionTitle: nil,
                    action: nil
                )
                CodeValueBlock(
                    label: self.model.localized(zh: "代理接入地址", en: "Proxy Endpoint"),
                    value: self.model.publicBaseURLText,
                    actionTitle: nil,
                    action: nil
                )
            }
        }
        .accessibilityIdentifier("remote-admin-header-host-details")
    }

    private var sessionDetailsBlock: some View {
        FormFieldPanel(
            title: self.model.localized(zh: "会话与控制面", en: "Session & Control Plane"),
            compact: true
        ) {
            VStack(alignment: .leading, spacing: 8) {
                CodeValueBlock(
                    label: self.model.localized(zh: "远端 admin 绑定", en: "Remote Admin Bind"),
                    value: self.model.remoteAdminBindText,
                    actionTitle: nil,
                    action: nil
                )
                CodeValueBlock(
                    label: self.model.localized(zh: "本地转发地址", en: "Forwarded Admin URL"),
                    value: self.model.forwardedAdminBaseURLText,
                    actionTitle: nil,
                    action: nil
                )
                CodeValueBlock(
                    label: self.model.localized(zh: "最近成功同步", en: "Last Successful Sync"),
                    value: self.model.lastRefreshText,
                    actionTitle: nil,
                    action: nil
                )
            }
        }
        .accessibilityIdentifier("remote-admin-header-session-details")
    }

    private var actionsBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                self.refreshButton
                self.reconnectButton
                self.closeButton
            }

            VStack(alignment: .trailing, spacing: 8) {
                self.refreshButton
                self.reconnectButton
                self.closeButton
            }
        }
    }

    private var refreshButton: some View {
        Button(self.model.localized(zh: "刷新远端状态", en: "Refresh Remote State")) {
            Task { await self.model.refresh() }
        }
        .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
        .disabled(self.model.isRefreshing)
        .accessibilityIdentifier("remote-admin-header-refresh-button")
    }

    private var reconnectButton: some View {
        Button(self.model.localized(zh: "重建隧道并重连", en: "Reconnect Tunnel")) {
            Task { await self.model.reconnect() }
        }
        .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
        .disabled(self.model.isRefreshing)
        .accessibilityIdentifier("remote-admin-header-reconnect-button")
    }

    private var closeButton: some View {
        Button(self.model.localized(zh: "关闭窗口", en: "Close Window")) {
            self.onClose()
        }
        .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
        .accessibilityIdentifier("remote-admin-header-close-button")
    }
}

private struct RemoteAdminNotePanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String?
    let notes: [String]
    let tone: StatusPill.Tone

    init(title: String? = nil, notes: [String], tone: StatusPill.Tone) {
        self.title = title
        self.notes = notes
        self.tone = tone
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
            }

            ForEach(Array(self.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: self.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.foreground)
                        .padding(.top, 2)

                    Text(note)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
    }

    private var symbolName: String {
        switch self.tone {
        case .accent:
            return "sparkles"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .danger:
            return "xmark.octagon.fill"
        case .neutral:
            return "info.circle.fill"
        }
    }

    private func colors(palette: AppearancePalette) -> (foreground: Color, background: Color, border: Color) {
        switch self.tone {
        case .accent:
            return (
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.16 : 0.12),
                palette.accent.opacity(0.22)
            )
        case .success:
            return (
                palette.success,
                palette.success.opacity(self.colorScheme == .dark ? 0.18 : 0.12),
                palette.success.opacity(0.22)
            )
        case .warning:
            return (
                palette.warning,
                palette.warning.opacity(self.colorScheme == .dark ? 0.18 : 0.12),
                palette.warning.opacity(0.22)
            )
        case .danger:
            return (
                palette.danger,
                palette.danger.opacity(self.colorScheme == .dark ? 0.18 : 0.12),
                palette.danger.opacity(0.22)
            )
        case .neutral:
            return (
                palette.textSecondary,
                palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 0.96),
                palette.border
            )
        }
    }
}
#endif
