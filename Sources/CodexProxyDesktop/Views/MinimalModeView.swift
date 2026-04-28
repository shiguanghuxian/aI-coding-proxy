#if os(macOS)
import CodexProxyCore
import SwiftUI

struct MinimalModeView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        GeometryReader { proxy in
            let metrics = MinimalLayoutMetrics(proxy: proxy)

            ZStack {
                ShellBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                        DashboardHeader(
                            title: self.model.minimalModeTitle,
                            subtitle: self.model.minimalModeSubtitle,
                            statusText: self.model.shellServiceStatusText,
                            statusTone: self.model.shellServiceStatusTone,
                            isBusy: self.model.isBusy,
                            showsControls: false,
                            compact: metrics.isCompact,
                            reloadTitle: self.model.text(.commonReload)
                        ) {
                            Task { await self.model.loadAll() }
                        }

                        self.statusBarSection(metrics: metrics)
                        self.primaryCardsSection(metrics: metrics)
                    }
                    .frame(maxWidth: metrics.contentMaxWidth, alignment: .leading)
                    .padding(.top, metrics.outerTopPadding)
                    .padding(.leading, metrics.outerHorizontalPadding)
                    .padding(.trailing, metrics.outerHorizontalPadding)
                    .padding(.bottom, metrics.outerBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .compactOverlayScrollbars()
    }

    @ViewBuilder
    private func primaryCardsSection(metrics: MinimalLayoutMetrics) -> some View {
        switch metrics.primaryCardLayoutMode {
        case .threeColumns:
            HStack(alignment: .top, spacing: metrics.columnSpacing) {
                MinimalAccountsSection(model: self.model, metrics: metrics)
                    .frame(minWidth: metrics.primaryColumnMinimumWidth, maxWidth: .infinity, alignment: .topLeading)

                MinimalAccessSection(model: self.model, metrics: metrics)
                    .frame(minWidth: metrics.primaryColumnMinimumWidth, maxWidth: .infinity, alignment: .topLeading)

                MinimalProxySection(model: self.model, metrics: metrics)
                    .frame(minWidth: metrics.primaryColumnMinimumWidth, maxWidth: .infinity, alignment: .topLeading)
            }

        case .twoPlusOne:
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                HStack(alignment: .top, spacing: metrics.columnSpacing) {
                    MinimalAccountsSection(model: self.model, metrics: metrics)
                        .frame(minWidth: metrics.primaryColumnMinimumWidth, maxWidth: .infinity, alignment: .topLeading)

                    MinimalAccessSection(model: self.model, metrics: metrics)
                        .frame(minWidth: metrics.primaryColumnMinimumWidth, maxWidth: .infinity, alignment: .topLeading)
                }

                MinimalProxySection(model: self.model, metrics: metrics)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

        case .singleColumn:
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                MinimalAccountsSection(model: self.model, metrics: metrics)
                MinimalAccessSection(model: self.model, metrics: metrics)
                MinimalProxySection(model: self.model, metrics: metrics)
            }
        }
    }

    private func statusBarSection(metrics: MinimalLayoutMetrics) -> some View {
        MinimalStatusBarCard(
            model: self.model,
            metrics: metrics,
            onStartDaemon: self.startDaemon,
            onStopDaemon: self.stopDaemon
        )
    }

    private func startDaemon() {
        Task { await self.model.startDaemon() }
    }

    private func stopDaemon() {
        Task { await self.model.stopDaemon() }
    }

}

private struct MinimalStatusBarCard: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let metrics: MinimalLayoutMetrics
    let onStartDaemon: () -> Void
    let onStopDaemon: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Group {
            switch self.metrics.statusBarLayoutMode {
            case .singleLine:
                HStack(alignment: .center, spacing: self.metrics.columnSpacing) {
                    self.statusTrack
                    Spacer(minLength: 0)
                    self.actionBar
                }

            case .stacked:
                VStack(alignment: .leading, spacing: self.metrics.inlinePanelSpacing) {
                    self.statusTrack

                    HStack {
                        Spacer(minLength: 0)
                        self.actionBar
                    }
                }
            }
        }
        .padding(self.metrics.insetPanelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.metrics.insetPanelCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.94),
                            palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.90),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.metrics.insetPanelCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [palette.border, Color.white.opacity(self.colorScheme == .dark ? 0.04 : 0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? 0.16 : 0.05),
            radius: 10,
            x: 0,
            y: 4
        )
    }

    private var statusTrack: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: self.metrics.columnSpacing) {
                self.titleTag
                self.servicePill
                self.accountMetric
                self.proxyMetric
            }

            VStack(alignment: .leading, spacing: self.metrics.actionSpacing) {
                HStack(alignment: .center, spacing: self.metrics.actionSpacing) {
                    self.titleTag
                    self.servicePill
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: self.metrics.columnSpacing) {
                        self.accountMetric
                        self.proxyMetric
                    }

                    VStack(alignment: .leading, spacing: self.metrics.actionSpacing) {
                        self.accountMetric
                        self.proxyMetric
                    }
                }
            }
        }
    }

    private var titleTag: some View {
        Text(self.model.localized(zh: "当前运行状态", en: "Current Status"))
            .font(.system(size: self.metrics.isCompact ? 10 : 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var servicePill: some View {
        StatusPill(
            text: self.model.localServicePrimaryStatusText,
            tone: self.model.localServiceSummaryTone,
            compact: true
        )
    }

    private var accountMetric: some View {
        MinimalStatusInlineMetric(
            label: self.model.text(.labelAccounts),
            value: "\(self.model.accounts.count)",
            tone: self.model.accounts.isEmpty ? .warning : .success,
            compact: self.metrics.isCompact
        )
    }

    private var proxyMetric: some View {
        MinimalStatusInlineMetric(
            label: self.model.localized(zh: "出站代理", en: "Outbound Proxy"),
            value: self.model.label(for: self.model.settings.outboundProxyMode),
            tone: self.proxyTone,
            compact: self.metrics.isCompact
        )
    }

    private var actionBar: some View {
        ServiceActionBar(
            start: .init(
                title: self.model.localStartButtonTitle,
                isEnabled: self.model.localCanStartService,
                isLoading: self.model.localServiceOperation == .starting,
                kind: .primary,
                action: self.onStartDaemon
            ),
            stop: .init(
                title: self.model.localStopButtonTitle,
                isEnabled: self.model.localCanStopService,
                isLoading: self.model.localServiceOperation == .stopping,
                kind: .danger,
                action: self.onStopDaemon
            ),
            compact: true
        )
    }

    private var proxyTone: StatusPill.Tone {
        switch self.model.settings.outboundProxyMode {
        case .disabled:
            return .accent
        case .manual:
            return .warning
        case .subscription:
            return .neutral
        }
    }
}

private struct MinimalStatusInlineMetric: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    let tone: StatusPill.Tone
    let compact: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(alignment: .firstTextBaseline, spacing: self.compact ? 6 : 8) {
            Text(self.label.uppercased())
                .font(.system(size: self.compact ? 9 : 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)

            Text(self.value)
                .font(.system(size: self.compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(self.valueColor(palette: palette))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private func valueColor(palette: AppearancePalette) -> Color {
        switch self.tone {
        case .accent:
            return palette.accent
        case .success:
            return palette.success
        case .warning:
            return palette.warning
        case .danger:
            return palette.danger
        case .neutral:
            return palette.textPrimary
        }
    }
}

private struct MinimalAccountsSection: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let metrics: MinimalLayoutMetrics

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        SectionCard(
            title: self.model.localized(zh: "账号添加", en: "Accounts"),
            subtitle: self.model.localized(
                zh: "先导入一种账号来源，已有账号也可继续补充。",
                en: "Import one account source first, then add more if needed."
            ),
            accessory: StatusPill(
                text: self.model.accounts.isEmpty
                    ? self.model.localized(zh: "未配置", en: "Not Ready")
                    : self.model.localized(zh: "已导入 \(self.model.accounts.count)", en: "\(self.model.accounts.count) Imported"),
                tone: self.model.accounts.isEmpty ? .warning : .success,
                compact: self.metrics.isCompact
            ),
            compact: self.metrics.isCompact
        ) {
            if self.model.accounts.isEmpty {
                MinimalSummaryPanel(
                    title: self.model.localized(zh: "当前状态", en: "Current State"),
                    summary: self.model.localized(
                        zh: "完成任意一种导入后，代理就会开始有可用上游。",
                        en: "The proxy will have an upstream as soon as one import succeeds."
                    ),
                    compact: self.metrics.isCompact
                )
            } else {
                MinimalInsetPanel(
                    title: self.model.localized(zh: "当前账号池", en: "Current Account Pool"),
                    subtitle: self.accountSummaryText,
                    compact: self.metrics.isCompact
                ) {
                    DetailRow(
                        label: self.model.localized(zh: "可用账号", en: "Available Accounts"),
                        value: "\(self.model.accounts.count)",
                        labelWidth: self.metrics.detailLabelWidth,
                        compact: self.metrics.isCompact
                    )
                }
            }

            LazyVGrid(columns: self.actionColumns, alignment: .leading, spacing: self.metrics.actionSpacing) {
                self.accountActionButton(
                    title: self.model.oauthLoginTitle(for: .openAI),
                    helpText: self.model.oauthQuickActionHelp(for: .openAI),
                    symbol: "globe.badge.chevron.backward",
                    tone: .accent
                ) {
                    Task { await self.model.startOAuth(providerFamily: .openAI) }
                }

                self.accountActionButton(
                    title: self.model.oauthLoginTitle(for: .anthropic),
                    helpText: self.model.oauthQuickActionHelp(for: .anthropic),
                    symbol: "person.crop.circle.badge.questionmark",
                    tone: .warning
                ) {
                    Task { await self.model.startOAuth(providerFamily: .anthropic) }
                }

                self.accountActionButton(
                    title: self.model.oauthLoginTitle(for: .gemini),
                    helpText: self.model.oauthQuickActionHelp(for: .gemini),
                    symbol: "sparkle.magnifyingglass",
                    tone: .success
                ) {
                    Task { await self.model.startOAuth(providerFamily: .gemini) }
                }

                self.accountActionButton(
                    title: self.model.text(.actionImportCurrent),
                    helpText: self.model.text(.helperQuickActionImportCurrent),
                    symbol: "person.badge.key.fill",
                    tone: .success
                ) {
                    Task { await self.model.importCurrentAuth() }
                }

                self.accountActionButton(
                    title: self.model.text(.actionManualAddAccount),
                    helpText: self.model.text(.helperQuickActionManualAdd),
                    symbol: "plus.circle.fill",
                    tone: .warning
                ) {
                    self.model.presentMinimalManualAPIKeyDraft()
                }

                self.accountActionButton(
                    title: self.model.text(.actionImportJSON),
                    helpText: self.model.text(.helperQuickActionImportJSON),
                    symbol: "tray.and.arrow.down.fill",
                    tone: .neutral
                ) {
                    Task { await self.model.importJSONFiles() }
                }
            }

            if let draft = self.model.oauthDraft {
                OAuthFlowPanel(model: self.model, draft: draft)
            }

            if self.model.minimalManualAPIKeyDraft != nil {
                VStack(alignment: .leading, spacing: self.metrics.inlinePanelSpacing) {
                    HStack(alignment: .top, spacing: self.metrics.inlinePanelSpacing) {
                        VStack(alignment: .leading, spacing: self.metrics.isCompact ? 4 : 5) {
                            Text(self.model.localized(zh: "手动添加兼容 API Key 账号", en: "Add a compatible API key account"))
                                .font(.system(size: self.metrics.isCompact ? 15 : 16, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                            Text(self.model.text(.helperManualAPIKeyAccount))
                                .font(.system(size: self.metrics.isCompact ? 11 : 12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(self.metrics.isCompact ? 2 : 3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        StatusPill(text: self.model.planText("api_key"), tone: .warning, compact: self.metrics.isCompact)
                    }

                    ManualAPIKeyAccountForm(
                        model: self.model,
                        draft: Binding(
                            get: { self.model.minimalManualAPIKeyDraft ?? DesktopAppModel.ManualAPIKeyDraft() },
                            set: { self.model.updateMinimalManualAPIKeyDraft($0) }
                        ),
                        compact: self.metrics.isCompact
                    )

                    HStack(spacing: self.metrics.actionSpacing) {
                        if self.metrics.isCompact {
                            Button(self.model.text(.commonCancel)) {
                                self.model.dismissMinimalManualAPIKeyDraft()
                            }
                            .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
                            .disabled(self.model.manualAPIKeyIsSubmitting)
                        } else {
                            Button(self.model.text(.commonCancel)) {
                                self.model.dismissMinimalManualAPIKeyDraft()
                            }
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                            .disabled(self.model.manualAPIKeyIsSubmitting)
                        }

                        Spacer(minLength: 0)

                        if self.metrics.isCompact {
                            Button(self.model.text(.actionSaveAccount)) {
                                Task { await self.model.submitMinimalManualAPIKeyAccount() }
                            }
                            .buttonStyle(TopBarCompactActionButtonStyle(kind: .primary))
                            .disabled(self.model.manualAPIKeyIsSubmitting)
                        } else {
                            Button(self.model.text(.actionSaveAccount)) {
                                Task { await self.model.submitMinimalManualAPIKeyAccount() }
                            }
                            .buttonStyle(AppActionButtonStyle(kind: .primary))
                            .disabled(self.model.manualAPIKeyIsSubmitting)
                        }
                    }
                }
                .padding(self.metrics.insetPanelPadding)
                .background(
                    RoundedRectangle(cornerRadius: self.metrics.insetPanelCornerRadius, style: .continuous)
                        .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.96 : 0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: self.metrics.insetPanelCornerRadius, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
            }

            if self.model.accounts.isEmpty == false {
                MinimalAccountListPanel(
                    model: self.model,
                    accounts: self.model.accounts,
                    metrics: self.metrics
                )
            }

            DashboardNavigationHintCard(
                title: self.model.localized(zh: "完整功能", en: "Full View"),
                detail: self.model.localized(
                    zh: "账号启停、排序和额度刷新继续在全功能账号页维护。",
                    en: "Enable or disable actions, ordering, and usage refreshes stay on the full Accounts page."
                ),
                actionTitle: self.model.localized(zh: "打开账号页", en: "Open Accounts"),
                isCompact: true
            ) {
                self.model.switchInterfaceMode(target: .full, destination: .page(.accounts))
            }
        }
    }

    private var accountSummaryText: String {
        if self.model.accounts.isEmpty {
            return self.model.localized(zh: "还没有可用账号。", en: "No accounts are available yet.")
        }

        return self.model.localized(
            zh: "当前已导入 \(self.model.accounts.count) 个账号，可继续补充更多来源。",
            en: "\(self.model.accounts.count) account(s) are imported, and you can add more sources."
        )
    }

    private var actionColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: self.metrics.actionSpacing),
            count: self.metrics.accountActionColumns
        )
    }

    @ViewBuilder
    private func accountActionButton(
        title: String,
        helpText: String,
        symbol: String,
        tone: StatusPill.Tone,
        action: @escaping () -> Void
    ) -> some View {
        CompactActionToolbarButton(
            title: title,
            helpText: helpText,
            symbol: symbol,
            tone: tone,
            action: action,
            compact: self.metrics.isCompact
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MinimalProxySection: View {
    @ObservedObject var model: DesktopAppModel
    let metrics: MinimalLayoutMetrics

    var body: some View {
        SectionCard(
            title: self.model.localized(zh: "出站代理", en: "Outbound Proxy"),
            subtitle: self.model.localized(
                zh: "这里只保留直连和手工代理，订阅代理继续在全功能页管理。",
                en: "Keep direct and manual proxying here. Subscription proxying stays on the full Settings page."
            ),
            accessory: StatusPill(
                text: self.model.label(for: self.model.settings.outboundProxyMode),
                tone: self.proxyTone,
                compact: self.metrics.isCompact
            ),
            compact: self.metrics.isCompact
        ) {
            MinimalSummaryPanel(
                title: self.model.localized(zh: "当前保存状态", en: "Current Saved State"),
                summary: self.model.minimalProxyModeSummary(),
                compact: self.metrics.isCompact
            )

            if self.model.settings.outboundProxyMode == .subscription {
                DashboardNavigationHintCard(
                    title: self.model.localized(zh: "高级模式", en: "Advanced Path"),
                    detail: self.model.localized(
                        zh: "当前正在使用订阅代理。详细配置、节点切换和测速仍在全功能设置页。",
                        en: "Subscription proxying is active. Detailed configuration, node switching, and health checks stay on the full Settings page."
                    ),
                    actionTitle: self.model.localized(zh: "打开出站代理设置", en: "Open Outbound Proxy"),
                    isCompact: true
                ) {
                    self.model.switchInterfaceMode(target: .full, destination: .settingsProxy)
                }
            } else {
                FormFieldPanel(
                    title: self.model.localized(zh: "选择一种方式继续", en: "Choose how to continue"),
                    compact: self.metrics.isCompact
                ) {
                    Picker(
                        self.model.localized(zh: "选择一种方式继续", en: "Choose how to continue"),
                        selection: Binding(
                            get: { self.model.minimalProxyDraft.choice },
                            set: { self.model.updateMinimalProxyChoice($0) }
                        )
                    ) {
                        ForEach(DesktopAppModel.MinimalProxyChoice.allCases, id: \.self) { choice in
                            Text(self.model.minimalProxyChoiceTitle(choice)).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text(self.model.minimalProxyChoiceHelp(self.model.minimalProxyDraft.choice))
                    .font(.system(size: self.metrics.isCompact ? 11 : 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if self.model.minimalProxyDraft.choice == .manual {
                    MinimalInsetPanel(
                        title: self.model.localized(zh: "手工代理", en: "Manual Proxy"),
                        subtitle: self.model.localized(
                            zh: "填写你已有的代理地址；用户名和密码只有需要认证时再填。",
                            en: "Enter the proxy endpoint you already use. Username and password are only needed when that proxy requires authentication."
                        ),
                        compact: self.metrics.isCompact
                    ) {
                        FormFieldPanel(title: self.model.text(.labelScheme), compact: self.metrics.isCompact) {
                            Picker(self.model.text(.labelScheme), selection: self.$model.minimalProxyDraft.scheme) {
                                ForEach([OutboundProxyScheme.http, .https, .socks5], id: \.self) { scheme in
                                    Text(self.model.label(for: scheme)).tag(scheme)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: self.metrics.columnSpacing) {
                                self.hostField
                                self.portField
                            }

                            VStack(alignment: .leading, spacing: self.metrics.inlinePanelSpacing) {
                                self.hostField
                                self.portField
                            }
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: self.metrics.columnSpacing) {
                                self.usernameField
                                self.passwordField
                            }

                            VStack(alignment: .leading, spacing: self.metrics.inlinePanelSpacing) {
                                self.usernameField
                                self.passwordField
                            }
                        }
                    }
                }

                HStack {
                    if self.metrics.isCompact {
                        Button(self.model.text(.actionSaveProxySettings)) {
                            Task { await self.model.saveMinimalProxyConfiguration() }
                        }
                        .buttonStyle(TopBarCompactActionButtonStyle(kind: .primary))
                        .disabled(self.model.isBusy || self.model.minimalProxyNeedsSave == false)
                    } else {
                        Button(self.model.text(.actionSaveProxySettings)) {
                            Task { await self.model.saveMinimalProxyConfiguration() }
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                        .disabled(self.model.isBusy || self.model.minimalProxyNeedsSave == false)
                    }

                    Spacer(minLength: 0)
                }

                DashboardNavigationHintCard(
                    title: self.model.localized(zh: "完整功能", en: "Full View"),
                    detail: self.model.localized(
                        zh: "需要订阅代理、节点切换或更细的网络策略时，切到全功能设置页继续处理。",
                        en: "If you need subscription proxying, node switching, or more advanced network controls later, continue on the full Settings page."
                    ),
                    actionTitle: self.model.localized(zh: "打开出站代理设置", en: "Open Outbound Proxy"),
                    isCompact: true
                ) {
                    self.model.switchInterfaceMode(target: .full, destination: .settingsProxy)
                }
            }
        }
    }

    private var proxyTone: StatusPill.Tone {
        switch self.model.settings.outboundProxyMode {
        case .disabled:
            return .accent
        case .manual:
            return .warning
        case .subscription:
            return .neutral
        }
    }

    private var hostField: some View {
        FormFieldPanel(title: self.model.text(.labelHost), compact: self.metrics.isCompact) {
            TextField(self.model.text(.labelHost), text: self.$model.minimalProxyDraft.host)
                .textFieldStyle(.plain)
                .dashboardFieldChrome(compact: self.metrics.isCompact)
        }
    }

    private var portField: some View {
        FormFieldPanel(title: self.model.text(.labelPublicPort), compact: self.metrics.isCompact) {
            TextField(self.model.text(.labelPublicPort), value: self.$model.minimalProxyDraft.port, formatter: NumberFormatter())
                .textFieldStyle(.plain)
                .dashboardFieldChrome(compact: self.metrics.isCompact)
        }
    }

    private var usernameField: some View {
        FormFieldPanel(title: self.model.text(.labelUsername), compact: self.metrics.isCompact) {
            TextField(self.model.text(.labelUsername), text: self.$model.minimalProxyDraft.username)
                .textFieldStyle(.plain)
                .dashboardFieldChrome(compact: self.metrics.isCompact)
        }
    }

    private var passwordField: some View {
        FormFieldPanel(title: self.model.text(.labelPassword), compact: self.metrics.isCompact) {
            SecureField(self.model.text(.labelPassword), text: self.$model.minimalProxyDraft.password)
                .textFieldStyle(.plain)
                .dashboardFieldChrome(compact: self.metrics.isCompact)
        }
    }
}

private struct MinimalAccessSection: View {
    @ObservedObject var model: DesktopAppModel
    let metrics: MinimalLayoutMetrics

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAccessInfo),
            subtitle: self.model.localized(
                zh: "三套客户端的地址和本地 API Key 都在这里直接复制。",
                en: "Copy the essential endpoints and local API key for all three client styles here."
            ),
            accessory: StatusPill(
                text: self.model.shellServiceStatusText,
                tone: self.model.shellServiceStatusTone,
                compact: self.metrics.isCompact
            ),
            compact: self.metrics.isCompact
        ) {
            VStack(alignment: .leading, spacing: self.metrics.inlinePanelSpacing) {
                MinimalAccessClientGroup(
                    title: self.model.localized(zh: "OpenAI 兼容", en: "OpenAI Compatible"),
                    subtitle: self.model.localized(
                        zh: "Codex 等客户端使用 Base URL。",
                        en: "Use the Base URL for Codex and other OpenAI-compatible clients."
                    ),
                    compact: self.metrics.isCompact
                ) {
                    MinimalAccessValueRow(
                        label: self.model.text(.labelOpenAIBaseURL),
                        value: self.model.openAICompatibleBaseURL,
                        actionTitle: self.model.text(.actionCopyEndpoint),
                        action: { self.model.copyEndpoint() },
                        labelWidth: self.metrics.accessValueLabelWidth,
                        compact: self.metrics.isCompact
                    )

                    MinimalAccessValueRow(
                        label: self.model.text(.labelAPIKey),
                        value: self.model.localProxyAPIKeyValue,
                        actionTitle: self.model.text(.actionCopyAPIKey),
                        action: { self.model.copyAPIKey() },
                        labelWidth: self.metrics.accessValueLabelWidth,
                        compact: self.metrics.isCompact
                    )
                }

                self.groupDivider

                MinimalAccessClientGroup(
                    title: self.model.localized(zh: "Anthropic", en: "Anthropic"),
                    subtitle: self.model.localized(
                        zh: "Claude Code 使用根地址；如果希望 Codex 固定走 Anthropic 账号池，也可以在 OpenAI 兼容 Base URL 上复用这把 Key。",
                        en: "Use the root endpoint for Claude Code. You can also reuse this key with the OpenAI-compatible base URL when you want Codex pinned to the Anthropic account pool."
                    ),
                    compact: self.metrics.isCompact
                ) {
                    MinimalAccessValueRow(
                        label: self.model.text(.labelAnthropicBaseURL),
                        value: self.model.anthropicBaseURL,
                        actionTitle: self.model.text(.actionCopyEndpoint),
                        action: { self.model.copyAnthropicBaseURL() },
                        labelWidth: self.metrics.accessValueLabelWidth,
                        compact: self.metrics.isCompact
                    )

                    MinimalAccessValueRow(
                        label: self.model.text(.labelAnthropicAuthToken),
                        value: self.model.anthropicAccessProxyAPIKeyDisplayValue,
                        actionTitle: self.model.canCopyAnthropicAccessProxyAPIKey ? self.model.text(.actionCopyAPIKey) : nil,
                        action: { self.model.copyAnthropicAccessAPIKey() },
                        labelWidth: self.metrics.accessValueLabelWidth,
                        compact: self.metrics.isCompact
                    )
                }

                self.groupDivider

                MinimalAccessClientGroup(
                    title: self.model.localized(zh: "Gemini", en: "Gemini"),
                    subtitle: self.model.localized(
                        zh: "Gemini CLI 使用 Gemini 根地址。",
                        en: "Use the Gemini root endpoint for Gemini CLI."
                    ),
                    compact: self.metrics.isCompact
                ) {
                    MinimalAccessValueRow(
                        label: self.model.text(.labelGeminiBaseURL),
                        value: self.model.geminiBaseURL,
                        actionTitle: self.model.text(.actionCopyEndpoint),
                        action: { self.model.copyGeminiBaseURL() },
                        labelWidth: self.metrics.accessValueLabelWidth,
                        compact: self.metrics.isCompact
                    )

                    MinimalAccessValueRow(
                        label: self.model.text(.labelAPIKey),
                        value: self.model.localProxyAPIKeyValue,
                        actionTitle: self.model.text(.actionCopyAPIKey),
                        action: { self.model.copyAPIKey() },
                        labelWidth: self.metrics.accessValueLabelWidth,
                        compact: self.metrics.isCompact
                    )
                }
            }

            DashboardNavigationHintCard(
                title: self.model.localized(zh: "完整功能", en: "Full View"),
                detail: self.model.localized(
                    zh: "环境变量片段、多 Key 分配、Usage 和高级设置都继续在全功能代理页里。",
                    en: "Environment snippets, multi-key allocation, usage, and advanced settings continue on the full Proxy page."
                ),
                actionTitle: self.model.localized(zh: "打开代理页接入信息", en: "Open Proxy Access"),
                isCompact: true
            ) {
                self.model.switchInterfaceMode(target: .full, destination: .proxyAccess)
            }
        }
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 1)
    }
}

private struct MinimalInsetPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let compact: Bool
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 10 : 12) {
            VStack(alignment: .leading, spacing: self.compact ? 4 : 5) {
                Text(self.title.uppercased())
                    .font(.system(size: self.compact ? 9 : 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                Text(self.subtitle)
                    .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(self.compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            self.content
        }
        .padding(self.compact ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct MinimalSummaryPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let summary: String
    let compact: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 4 : 5) {
            Text(self.title.uppercased())
                .font(.system(size: self.compact ? 9 : 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            Text(self.summary)
                .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(self.compact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(self.compact ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct MinimalAccountListPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let accounts: [AccountSummary]
    let metrics: MinimalLayoutMetrics

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.metrics.actionSpacing) {
            HStack(alignment: .center, spacing: self.metrics.actionSpacing) {
                Text(self.model.localized(zh: "已导入账号", en: "Imported Accounts").uppercased())
                    .font(.system(size: self.metrics.isCompact ? 9 : 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                Spacer(minLength: 0)

                Text("\(self.accounts.count)")
                    .font(.system(size: self.metrics.isCompact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(self.accounts.enumerated()), id: \.element.id) { index, account in
                        MinimalAccountListRow(
                            account: account,
                            model: self.model,
                            metrics: self.metrics
                        )

                        if index < self.accounts.count - 1 {
                            Divider()
                                .padding(.leading, self.metrics.isCompact ? 4 : 6)
                        }
                    }
                }
            }
            .frame(maxHeight: self.metrics.accountListMaxHeight)
        }
        .padding(self.metrics.isCompact ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: self.metrics.isCompact ? 16 : 18, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.80 : 0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.metrics.isCompact ? 16 : 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct MinimalAccountListRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let account: AccountSummary
    @ObservedObject var model: DesktopAppModel
    let metrics: MinimalLayoutMetrics

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let status = self.model.minimalAccountStatusPresentation(self.account)
        let usageSummary = self.model.minimalAccountUsageSummary(self.account)

        HStack(alignment: .center, spacing: self.metrics.actionSpacing) {
            Text(self.account.label)
                .font(.system(size: self.metrics.isCompact ? 11 : 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(self.account.label)

            Spacer(minLength: self.metrics.actionSpacing)

            Text(usageSummary)
                .font(.system(size: self.metrics.isCompact ? 10 : 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: self.metrics.accountListUsageWidth, alignment: .trailing)
                .help(usageSummary)

            StatusPill(text: status.text, tone: status.tone, compact: true)
        }
        .frame(minHeight: self.metrics.accountListRowMinHeight, alignment: .leading)
    }
}

private struct MinimalAccessClientGroup<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let compact: Bool
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 8 : 10) {
            VStack(alignment: .leading, spacing: self.compact ? 2 : 3) {
                Text(self.title)
                    .font(.system(size: self.compact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                Text(self.subtitle)
                    .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }

            self.content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MinimalAccessValueRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    let actionTitle: String?
    let action: (() -> Void)?
    let labelWidth: CGFloat
    let compact: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: self.compact ? 8 : 10) {
                Text(self.label.uppercased())
                    .font(.system(size: self.compact ? 9 : 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(palette.textMuted)
                    .frame(width: self.labelWidth, alignment: .leading)

                Text(self.value)
                    .font(.system(size: self.compact ? 11 : 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer(minLength: 0)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, compact: self.compact))
                }
            }

            VStack(alignment: .leading, spacing: self.compact ? 6 : 8) {
                HStack(alignment: .firstTextBaseline, spacing: self.compact ? 8 : 10) {
                    Text(self.label.uppercased())
                        .font(.system(size: self.compact ? 9 : 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(palette.textMuted)

                    Spacer(minLength: 0)

                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, compact: self.compact))
                    }
                }

                Text(self.value)
                    .font(.system(size: self.compact ? 11 : 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, self.compact ? 10 : 12)
        .padding(.vertical, self.compact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 12 : 14, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.84 : 0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 12 : 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

enum MinimalPrimaryCardLayoutMode: Equatable {
    case threeColumns
    case twoPlusOne
    case singleColumn
}

enum MinimalStatusBarLayoutMode: Equatable {
    case singleLine
    case stacked
}

struct MinimalLayoutMetrics: Equatable {
    let isCompact: Bool
    let windowWidth: CGFloat
    let windowHeight: CGFloat
    let contentMaxWidth: CGFloat
    let outerHorizontalPadding: CGFloat
    let outerTopPadding: CGFloat
    let outerBottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let columnSpacing: CGFloat
    let summarySpacing: CGFloat
    let summaryGridSpacing: CGFloat
    let summaryGridMinimumWidth: CGFloat
    let summaryGridMaximumWidth: CGFloat
    let primaryColumnMinimumWidth: CGFloat
    let servicePanelMinimumWidth: CGFloat
    let servicePanelMaximumWidth: CGFloat
    let accessCardMinimumWidth: CGFloat
    let accessCardMaximumWidth: CGFloat
    let accessValueLabelWidth: CGFloat
    let accountActionColumns: Int
    let accountListUsageWidth: CGFloat
    let accountListRowMinHeight: CGFloat
    let accountListMaxHeight: CGFloat
    let detailLabelWidth: CGFloat
    let actionSpacing: CGFloat
    let inlinePanelSpacing: CGFloat
    let insetPanelPadding: CGFloat
    let insetPanelCornerRadius: CGFloat
    let primaryCardLayoutMode: MinimalPrimaryCardLayoutMode
    let statusBarLayoutMode: MinimalStatusBarLayoutMode

    init(width: CGFloat, height: CGFloat, safeAreaTop: CGFloat = 0, safeAreaBottom: CGFloat = 0) {
        self.isCompact = width < 1600 || height < 980
        self.windowWidth = width
        self.windowHeight = height
        self.contentMaxWidth = self.isCompact ? 1180 : 1220
        self.outerHorizontalPadding = self.isCompact ? 14 : 18
        self.outerTopPadding = max(self.isCompact ? 12 : 16, safeAreaTop + (self.isCompact ? 6 : 8))
        self.outerBottomPadding = max(self.isCompact ? 14 : 18, safeAreaBottom + (self.isCompact ? 8 : 10))
        self.sectionSpacing = self.isCompact ? 12 : 16
        self.columnSpacing = self.isCompact ? 12 : 16
        self.summarySpacing = self.isCompact ? 10 : 14
        self.summaryGridSpacing = self.isCompact ? 10 : 12
        self.summaryGridMinimumWidth = self.isCompact ? 150 : 160
        self.summaryGridMaximumWidth = self.isCompact ? 208 : 220
        self.primaryColumnMinimumWidth = self.isCompact ? 336 : 360
        self.servicePanelMinimumWidth = self.isCompact ? 248 : 280
        self.servicePanelMaximumWidth = self.isCompact ? 320 : 360
        self.accessCardMinimumWidth = self.isCompact ? 228 : 260
        self.accessCardMaximumWidth = self.isCompact ? 320 : 360
        self.accessValueLabelWidth = self.isCompact ? 86 : 96
        self.accountActionColumns = width < 760 ? 1 : 2
        self.accountListUsageWidth = self.isCompact ? 124 : 136
        self.accountListRowMinHeight = self.isCompact ? 30 : 34
        self.accountListMaxHeight = self.isCompact ? 152 : 168
        self.detailLabelWidth = self.isCompact ? 90 : 118
        self.actionSpacing = self.isCompact ? 6 : 8
        self.inlinePanelSpacing = self.isCompact ? 10 : 14
        self.insetPanelPadding = self.isCompact ? 14 : 18
        self.insetPanelCornerRadius = self.isCompact ? 18 : 22

        if width >= 1400 {
            self.primaryCardLayoutMode = .threeColumns
        } else if width >= 1040 {
            self.primaryCardLayoutMode = .twoPlusOne
        } else {
            self.primaryCardLayoutMode = .singleColumn
        }

        self.statusBarLayoutMode = width >= 1360 ? .singleLine : .stacked
    }

    init(proxy: GeometryProxy) {
        self.init(
            width: proxy.size.width,
            height: proxy.size.height,
            safeAreaTop: proxy.safeAreaInsets.top,
            safeAreaBottom: proxy.safeAreaInsets.bottom
        )
    }
}
#endif
