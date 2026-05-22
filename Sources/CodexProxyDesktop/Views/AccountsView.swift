#if os(macOS)
import CodexProxyCore
import SwiftUI

enum AccountsQuickActionID: String, CaseIterable, Identifiable {
    case openAILogin
    case anthropicLogin
    case geminiLogin
    case importCurrent
    case importLocalToRemote
    case manualAdd
    case importJSON
    case exportBackup
    case testProxy
    case refreshUsage

    var id: String { self.rawValue }
}

enum AccountsQuickActionLayoutGroups {
    static let login: [AccountsQuickActionID] = [
        .openAILogin,
        .anthropicLogin,
        .geminiLogin,
    ]

    static let addImport: [AccountsQuickActionID] = [
        .importCurrent,
        .importLocalToRemote,
        .manualAdd,
        .importJSON,
    ]

    static let overflow: [AccountsQuickActionID] = [
        .exportBackup,
        .testProxy,
        .refreshUsage,
    ]

    static let all: [AccountsQuickActionID] = login + addImport + overflow
}

struct AccountsView: View {
    enum PresentationContext {
        case standard
        case remoteAdmin
    }

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    var presentationContext: PresentationContext = .standard
    var onImportLocalAccountsToRemote: (() -> Void)? = nil

    static let accountPoolDetailDrawerWidth: CGFloat = 404

    private let accountCardWidth: CGFloat = 400

    private var accountColumns: [GridItem] {
        [GridItem(.adaptive(minimum: self.accountCardWidth, maximum: self.accountCardWidth), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if self.showsQuickActionToolbar {
                self.quickActionToolbar
                    .accessibilityIdentifier("accounts-quick-actions-toolbar")
            }

            SectionCard(
                title: self.model.text(.sectionAccountPool),
                subtitle: self.model.text(.helperSelectionPolicy),
                accessory: AccountPoolHeaderAccessory(model: self.model)
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if self.model.accounts.isEmpty {
                        AccountsOnboardingCallout(model: self.model)
                    } else {
                        AccountPoolToolbar(model: self.model)

                        if self.model.isAccountBatchRemoveModeEnabled {
                            AccountBatchRemoveBar(model: self.model)
                        }

                        if self.model.visibleAccountPoolAccounts.isEmpty {
                            EmptyStatePanel(
                                title: self.model.text(.placeholderNoMatchingAccounts),
                                detail: self.model.text(.helperNoMatchingAccounts)
                            )
                        } else {
                            self.accountPoolContent
                        }
                    }
                }
            }
        }
        .sheet(item: self.$model.manualAPIKeyDraft) { presentedDraft in
            ManualAPIKeyAccountSheet(
                model: self.model,
                presentedDraft: presentedDraft
            )
                .interactiveDismissDisabled(self.model.manualAPIKeyIsSubmitting)
        }
        .sheet(
            item: Binding(
                get: { self.model.authImportDraft },
                set: { newValue in self.model.authImportDraft = newValue }
            )
        ) { presentedDraft in
            AuthImportSheet(model: self.model, presentedDraft: presentedDraft)
                .interactiveDismissDisabled(self.model.authImportIsSubmitting)
        }
        .sheet(
            item: Binding(
                get: { self.model.accountLabelDraft },
                set: { newValue in self.model.accountLabelDraft = newValue }
            )
        ) { _ in
            AccountLabelSheet(model: self.model)
                .interactiveDismissDisabled(self.model.accountLabelIsSubmitting)
        }
        .sheet(
            item: Binding(
                get: { self.model.accountOrderDraft },
                set: { newValue in self.model.accountOrderDraft = newValue }
            )
        ) { _ in
            AccountOrderSheet(model: self.model)
                .interactiveDismissDisabled(self.model.accountOrderIsSubmitting)
        }
        .sheet(
            item: Binding(
                get: { self.model.accountManagedProxyNodeDraft },
                set: { newValue in self.model.accountManagedProxyNodeDraft = newValue }
            )
        ) { _ in
            AccountManagedProxyNodeSheet(model: self.model)
                .interactiveDismissDisabled(self.model.accountManagedProxyNodeIsSubmitting)
        }
        .sheet(
            item: Binding(
                get: { self.model.accountModelRoutingDraft },
                set: { newValue in self.model.accountModelRoutingDraft = newValue }
            )
        ) { _ in
            AccountModelRoutingSheet(model: self.model)
                .interactiveDismissDisabled(self.model.accountModelRoutingIsSubmitting)
        }
    }

    @ViewBuilder
    private var accountPoolContent: some View {
        switch self.model.accountPoolDisplayMode {
        case .cards:
            LazyVGrid(columns: self.accountColumns, alignment: .leading, spacing: 12) {
                ForEach(self.model.visibleAccountPoolAccounts) { account in
                    AccountCard(
                        account: account,
                        model: self.model,
                        width: self.accountCardWidth,
                        isBatchRemovalMode: self.model.isAccountBatchRemoveModeEnabled,
                        isBatchSelected: self.model.isSelectedForBatchRemove(account)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .list:
            AccountPoolListPane(model: self.model)
                .frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var quickActionToolbar: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            Text(self.model.text(.sectionQuickActions))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.textMuted)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    self.quickActionGroup(
                        title: self.model.text(.labelQuickActionLoginGroup),
                        actions: self.loginQuickActions,
                        palette: palette
                    )
                    self.quickActionGroup(
                        title: self.model.text(.labelQuickActionImportGroup),
                        actions: self.addImportQuickActions,
                        palette: palette
                    )
                    self.moreQuickActionsGroup(palette: palette)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    self.quickActionGroup(
                        title: self.model.text(.labelQuickActionLoginGroup),
                        actions: self.loginQuickActions,
                        palette: palette
                    )
                    self.quickActionGroup(
                        title: self.model.text(.labelQuickActionImportGroup),
                        actions: self.addImportQuickActions,
                        palette: palette
                    )
                    self.moreQuickActionsGroup(palette: palette)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let draft = self.model.oauthDraft {
                OAuthFlowPanel(model: self.model, draft: draft)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.94 : 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .shadow(color: palette.shadow.opacity(self.colorScheme == .dark ? 0.14 : 0.06), radius: 8, x: 0, y: 4)
    }

    @ViewBuilder
    private func quickActionGroup(
        title: String,
        actions: [AccountsQuickActionID],
        palette: AppearancePalette
    ) -> some View {
        if actions.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                QuickActionWrapLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    self.quickActionRow(actions)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.70 : 0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.border.opacity(0.86), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func quickActionRow(_ actions: [AccountsQuickActionID]) -> some View {
        ForEach(actions.filter(self.supportsQuickAction)) { action in
            self.quickActionButton(for: action)
        }
    }

    @ViewBuilder
    private func moreQuickActionsMenu(palette: AppearancePalette) -> some View {
        let actions = self.overflowQuickActions
        if actions.isEmpty == false {
            Menu {
                ForEach(actions) { action in
                    self.quickActionMenuButton(for: action)
                }
            } label: {
                self.moreQuickActionsMenuLabel(palette: palette)
            }
            .menuStyle(.borderlessButton)
            .help(self.model.text(.helperMoreQuickActions))
            .accessibilityIdentifier("accounts-more-quick-actions-menu")
            .fixedSize()
        }
    }

    private func moreQuickActionsMenuLabel(palette: AppearancePalette) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.textSecondary)

            Text(self.model.text(.actionMoreQuickActions))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(palette.textMuted)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(Capsule())
        .background(
            Capsule(style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 1.0))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .shadow(color: palette.shadow.opacity(self.colorScheme == .dark ? 0.06 : 0.0048), radius: 4, x: 0, y: 1.5)
    }

    @ViewBuilder
    private func moreQuickActionsGroup(palette: AppearancePalette) -> some View {
        let actions = self.overflowQuickActions
        if actions.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                Text(self.model.text(.labelQuickActionMaintenanceGroup).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                self.moreQuickActionsMenu(palette: palette)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.70 : 0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.border.opacity(0.86), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func quickActionMenuButton(for action: AccountsQuickActionID) -> some View {
        switch action {
        case .exportBackup:
            Button {
                self.exportAccounts()
            } label: {
                Label(self.model.text(.actionExportBackup), systemImage: "archivebox.fill")
            }
        case .testProxy:
            Button {
                self.openTestProxy()
            } label: {
                Label(self.model.text(.actionTestProxy), systemImage: "bolt.badge.checkmark")
            }
            .accessibilityIdentifier("accounts-test-proxy-button")
        case .refreshUsage:
            Button {
                self.refreshUsage()
            } label: {
                Label(self.model.text(.actionRefreshUsage), systemImage: "arrow.clockwise.circle.fill")
            }
        case .openAILogin, .anthropicLogin, .geminiLogin, .importCurrent, .importLocalToRemote, .manualAdd, .importJSON:
            self.quickActionButton(for: action)
        }
    }

    @ViewBuilder
    private func quickActionButton(for action: AccountsQuickActionID) -> some View {
        switch action {
        case .openAILogin:
            self.openAILoginButton
        case .anthropicLogin:
            self.anthropicLoginButton
        case .geminiLogin:
            self.geminiLoginButton
        case .importCurrent:
            self.importCurrentButton
        case .importLocalToRemote:
            self.importLocalToRemoteButton
        case .manualAdd:
            self.manualAddButton
        case .importJSON:
            self.importJSONButton
        case .exportBackup:
            self.exportBackupButton
        case .testProxy:
            self.testProxyButton
        case .refreshUsage:
            self.refreshUsageButton
        }
    }

    private var openAILoginButton: some View {
        CompactActionToolbarButton(
            title: self.model.oauthLoginTitle(for: .openAI),
            helpText: self.model.oauthQuickActionHelp(for: .openAI),
            symbol: "globe.badge.chevron.backward",
            tone: .accent,
            action: self.startOpenAIOAuth
        )
    }

    private var anthropicLoginButton: some View {
        CompactActionToolbarButton(
            title: self.model.oauthLoginTitle(for: .anthropic),
            helpText: self.model.oauthQuickActionHelp(for: .anthropic),
            symbol: "person.crop.circle.badge.questionmark",
            tone: .warning,
            action: self.startAnthropicOAuth
        )
    }

    private var geminiLoginButton: some View {
        CompactActionToolbarButton(
            title: self.model.oauthLoginTitle(for: .gemini),
            helpText: self.model.oauthQuickActionHelp(for: .gemini),
            symbol: "sparkle.magnifyingglass",
            tone: .success,
            action: self.startGeminiOAuth
        )
    }

    private var importCurrentButton: some View {
        CompactActionToolbarButton(
            title: self.model.text(.actionImportCurrent),
            helpText: self.model.text(.helperQuickActionImportCurrent),
            symbol: "person.badge.key.fill",
            tone: .success,
            action: self.importCurrent
        )
    }

    private var importLocalToRemoteButton: some View {
        CompactActionToolbarButton(
            title: self.model.text(.actionImportLocalAccountsToRemote),
            helpText: self.model.text(.helperQuickActionImportLocalAccountsToRemote),
            symbol: "rectangle.2.swap",
            tone: .accent,
            action: self.importLocalAccountsToRemote
        )
        .accessibilityIdentifier("accounts-import-local-to-remote-button")
    }

    private var manualAddButton: some View {
        CompactActionToolbarButton(
            title: self.model.text(.actionManualAddAccount),
            helpText: self.model.text(.helperQuickActionManualAdd),
            symbol: "plus.circle.fill",
            tone: .warning,
            action: self.openManualAddSheet
        )
    }

    private var importJSONButton: some View {
        CompactActionToolbarButton(
            title: self.model.text(.actionImportJSON),
            helpText: self.model.text(.helperQuickActionImportJSON),
            symbol: "tray.and.arrow.down.fill",
            tone: .neutral,
            action: self.importJSON
        )
    }

    private var exportBackupButton: some View {
        CompactActionToolbarButton(
            title: self.model.text(.actionExportBackup),
            helpText: self.model.text(.helperQuickActionExportBackup),
            symbol: "archivebox.fill",
            tone: .neutral,
            action: self.exportAccounts
        )
    }

    private var refreshUsageButton: some View {
        CompactActionToolbarButton(
            title: self.model.text(.actionRefreshUsage),
            helpText: self.model.text(.helperQuickActionRefreshUsage),
            symbol: "arrow.clockwise.circle.fill",
            tone: .warning,
            action: self.refreshUsage
        )
    }

    private var testProxyButton: some View {
        CompactActionToolbarButton(
            title: self.model.text(.actionTestProxy),
            helpText: self.model.text(.helperQuickActionTestProxy),
            symbol: "bolt.badge.checkmark",
            tone: .accent,
            action: self.openTestProxy
        )
        .accessibilityIdentifier("accounts-test-proxy-button")
    }

    private func startOpenAIOAuth() {
        Task { await self.model.startOAuth(providerFamily: .openAI) }
    }

    private func startAnthropicOAuth() {
        Task { await self.model.startOAuth(providerFamily: .anthropic) }
    }

    private func startGeminiOAuth() {
        Task { await self.model.startOAuth(providerFamily: .gemini) }
    }

    private func importCurrent() {
        Task { await self.model.importCurrentAuth() }
    }

    private func importLocalAccountsToRemote() {
        self.onImportLocalAccountsToRemote?()
    }

    private func importJSON() {
        self.model.presentAuthImportSheet()
    }

    private func exportAccounts() {
        Task { await self.model.exportAccounts() }
    }

    private func refreshUsage() {
        Task { await self.model.refreshUsage() }
    }

    private func openTestProxy() {
        self.model.openProxyTestConsole()
    }

    private func openManualAddSheet() {
        self.model.presentManualAPIKeySheet()
    }

    private func supportsQuickAction(_ action: AccountsQuickActionID) -> Bool {
        switch action {
        case .openAILogin, .anthropicLogin, .geminiLogin:
            return self.presentationContext == .standard && self.model.adminSupportsOAuth
        case .importCurrent:
            return self.presentationContext == .standard && self.model.adminSupportsImportCurrent
        case .importLocalToRemote:
            return self.presentationContext == .remoteAdmin && self.onImportLocalAccountsToRemote != nil
        case .testProxy:
            return self.model.adminSupportsProxyTesting
        case .manualAdd, .importJSON, .exportBackup, .refreshUsage:
            return true
        }
    }

    private var showsQuickActionToolbar: Bool {
        true
    }

    private var loginQuickActions: [AccountsQuickActionID] {
        AccountsQuickActionLayoutGroups.login.filter(self.supportsQuickAction)
    }

    private var addImportQuickActions: [AccountsQuickActionID] {
        AccountsQuickActionLayoutGroups.addImport.filter(self.supportsQuickAction)
    }

    private var overflowQuickActions: [AccountsQuickActionID] {
        AccountsQuickActionLayoutGroups.overflow.filter(self.supportsQuickAction)
    }
}

private struct AccountsOnboardingCallout: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.accent.opacity(0.94), palette.accent.opacity(0.70)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 6) {
                    Text(self.model.localized(zh: "从新手引导开始会更顺", en: "Starting with the onboarding guide is easier"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(
                        self.model.localized(
                            zh: "还没有导入任何账号时，先走一遍新手引导会把账号池、出站代理和客户端接入串起来。你也可以直接使用下面这些常见入口。",
                            en: "When no accounts are imported yet, the onboarding flow walks through account setup, outbound proxying, and client access in order. You can also jump straight into the common actions below."
                        )
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                if self.model.adminSupportsOnboarding {
                    Button(self.model.localized(zh: "开始新手引导", en: "Start Onboarding")) {
                        self.model.startOnboarding()
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .primary))
                }

                if self.model.adminSupportsImportCurrent {
                    Button(self.model.text(.actionImportCurrent)) {
                        Task { await self.model.importCurrentAuth() }
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .secondary))
                }

                Spacer(minLength: 0)
            }

            QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                if self.model.adminSupportsOAuth {
                    CompactActionToolbarButton(
                        title: self.model.oauthLoginTitle(for: .openAI),
                        helpText: self.model.oauthQuickActionHelp(for: .openAI),
                        symbol: "globe.badge.chevron.backward",
                        tone: .accent
                    ) {
                        Task { await self.model.startOAuth(providerFamily: .openAI) }
                    }

                    CompactActionToolbarButton(
                        title: self.model.oauthLoginTitle(for: .anthropic),
                        helpText: self.model.oauthQuickActionHelp(for: .anthropic),
                        symbol: "person.crop.circle.badge.questionmark",
                        tone: .warning
                    ) {
                        Task { await self.model.startOAuth(providerFamily: .anthropic) }
                    }

                    CompactActionToolbarButton(
                        title: self.model.oauthLoginTitle(for: .gemini),
                        helpText: self.model.oauthQuickActionHelp(for: .gemini),
                        symbol: "sparkle.magnifyingglass",
                        tone: .success
                    ) {
                        Task { await self.model.startOAuth(providerFamily: .gemini) }
                    }
                }

                CompactActionToolbarButton(
                    title: self.model.text(.actionManualAddAccount),
                    helpText: self.model.text(.helperQuickActionManualAdd),
                    symbol: "plus.circle.fill",
                    tone: .warning
                ) {
                    self.model.presentManualAPIKeySheet()
                }

                CompactActionToolbarButton(
                    title: self.model.text(.actionImportJSON),
                    helpText: self.model.text(.helperQuickActionImportJSON),
                    symbol: "tray.and.arrow.down.fill",
                    tone: .neutral
                ) {
                    self.model.presentAuthImportSheet()
                }
            }

            Text(
                self.model.localized(
                    zh: "后续管理：账号页 > 账号池。这里可以继续刷新额度、调整调用顺序、启停账号和移除本地授权。",
                    en: "Later management: Accounts > Account Pool. Return here to refresh usage, reorder routing, enable or disable accounts, and remove local authorizations."
                )
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.panelRaised.opacity(0.98), palette.panel.opacity(0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct AccountPoolToolbar: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ViewThatFits(in: .horizontal) {
            self.fullWidthToolbarLayout(palette: palette)
            self.twoLinePreferredToolbarLayout(palette: palette)
            self.narrowToolbarLayout(palette: palette)
        }
    }

    private func fullWidthToolbarLayout(palette: AppearancePalette) -> some View {
        HStack(alignment: .center, spacing: 10) {
            self.searchField(palette: palette)
            self.filterMenusRow
            Spacer(minLength: 0)
            self.toolbarActionButtonsRow

            if self.model.accountPoolHasActiveFilters {
                self.resultChip
            }
        }
    }

    private func twoLinePreferredToolbarLayout(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            self.searchField(palette: palette)

            HStack(alignment: .center, spacing: 10) {
                self.filterMenusRow
                Spacer(minLength: 0)
                self.toolbarActionButtonsRow
            }

            if self.model.accountPoolHasActiveFilters {
                self.resultChip
            }
        }
    }

    private func narrowToolbarLayout(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            self.searchField(palette: palette)
            self.adaptiveFilterMenusSection
            self.toolbarActionSection
        }
    }

    private func searchField(palette: AppearancePalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textMuted)

            TextField(self.model.text(.placeholderSearchAccounts), text: self.binding(for: \.searchQuery))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.86 : 0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private var statusMenu: some View {
        AccountPoolFilterMenu(
            title: self.model.text(.labelStatus),
            selectionText: self.model.label(for: self.model.accountPoolFilters.status),
            systemImage: "switch.2",
            options: AccountPoolStatusFilter.allCases,
            selected: self.model.accountPoolFilters.status,
            labelForOption: { self.model.label(for: $0) }
        ) { selection in
            self.binding(for: \.status).wrappedValue = selection
        }
    }

    private var planMenu: some View {
        AccountPoolFilterMenu(
            title: self.model.text(.labelPlan),
            selectionText: self.model.label(for: self.model.accountPoolFilters.plan),
            systemImage: "tag",
            options: AccountPoolPlanFilter.allCases,
            selected: self.model.accountPoolFilters.plan,
            labelForOption: { self.model.label(for: $0) }
        ) { selection in
            self.binding(for: \.plan).wrappedValue = selection
        }
    }

    private var issueMenu: some View {
        AccountPoolFilterMenu(
            title: self.model.text(.labelIssue),
            selectionText: self.model.label(for: self.model.accountPoolFilters.issue),
            systemImage: "line.3.horizontal.decrease.circle",
            options: AccountPoolIssueFilter.allCases,
            selected: self.model.accountPoolFilters.issue,
            labelForOption: { self.model.label(for: $0) }
        ) { selection in
            self.binding(for: \.issue).wrappedValue = selection
        }
    }

    private var filterMenusRow: some View {
        HStack(spacing: 10) {
            self.statusMenu
            self.planMenu
            self.issueMenu
        }
    }

    private var adaptiveFilterMenusSection: some View {
        ViewThatFits(in: .horizontal) {
            self.filterMenusRow

            VStack(alignment: .leading, spacing: 10) {
                self.statusMenu
                self.planMenu
                self.issueMenu
            }
        }
    }

    private var toolbarActionButtonsRow: some View {
        HStack(spacing: 10) {
            self.refreshAccountListButton
            self.batchRemoveButton
            self.manageOrderButton
            self.clearOutboundNodesButton
            self.clearFiltersButton
        }
    }

    private var toolbarActionSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                self.toolbarActionButtonsRow

                if self.model.accountPoolHasActiveFilters {
                    self.resultChip
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                self.toolbarActionButtonsRow

                if self.model.accountPoolHasActiveFilters {
                    self.resultChip
                }
            }
        }
    }

    private var manageOrderButton: some View {
        Button(self.model.text(.actionManageAccountOrder)) {
            self.model.presentAccountOrderSheet()
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(self.model.accounts.count <= 1)
    }

    private var batchRemoveButton: some View {
        Button {
            self.model.toggleAccountBatchRemoveMode()
        } label: {
            Label(self.model.text(.actionBatchRemoveAccounts), systemImage: "checklist")
        }
        .buttonStyle(AppActionButtonStyle(kind: self.model.isAccountBatchRemoveModeEnabled ? .primary : .secondary))
        .disabled(self.model.accounts.isEmpty || self.model.isBatchRemovingAccounts)
        .help(self.model.text(.helperBatchRemoveAccounts))
        .accessibilityIdentifier("account-pool-batch-remove-button")
    }

    private var refreshAccountListButton: some View {
        Button {
            Task { await self.model.refreshAccountList() }
        } label: {
            Label(self.model.refreshAccountListButtonText, systemImage: "arrow.clockwise")
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(self.model.isRefreshingAccountList)
        .help(self.model.text(.helperRefreshAccountList))
        .accessibilityIdentifier("account-pool-refresh-list-button")
    }

    private var clearFiltersButton: some View {
        Button(self.model.text(.actionClearFilters)) {
            self.model.resetAccountPoolFilters()
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: .primary))
        .disabled(!self.model.accountPoolHasActiveFilters)
    }

    private var clearOutboundNodesButton: some View {
        Button(self.model.text(.actionClearAccountManagedProxyNodes)) {
            Task { await self.model.clearAllAccountManagedProxyNodes() }
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: .primary))
        .disabled(!self.model.hasAccountManagedProxyNodeOverrides)
        .help(
            self.model.localized(
                zh: "清空全部账号的自定义出站节点，不受当前搜索或筛选结果限制。",
                en: "Clear custom outbound node overrides for every account, not just the currently visible results."
            )
        )
    }

    private var resultChip: some View {
        AccountPoolResultChip(
            title: self.model.text(.labelFilteredResults),
            value: self.model.accountPoolFilterSummaryText
        )
    }

    private func binding<Value>(for keyPath: WritableKeyPath<AccountPoolFilterState, Value>) -> Binding<Value> {
        Binding(
            get: { self.model.accountPoolFilters[keyPath: keyPath] },
            set: { newValue in
                var filters = self.model.accountPoolFilters
                filters[keyPath: keyPath] = newValue
                self.model.accountPoolFilters = filters
            }
        )
    }
}

private struct AccountPoolFilterMenu<Option: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let selectionText: String
    let systemImage: String
    let options: [Option]
    let selected: Option
    let labelForOption: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Menu {
            ForEach(self.options, id: \.self) { option in
                Button {
                    self.onSelect(option)
                } label: {
                    if option == self.selected {
                        Label(self.labelForOption(option), systemImage: "checkmark")
                    } else {
                        Text(self.labelForOption(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: self.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(palette.textMuted)
                    Text(self.selectionText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.84 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .interactiveCursor(isEnabled: self.isEnabled)
        .fixedSize()
    }
}

private struct AccountBatchRemoveBar: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                self.summary(palette: palette)
                Spacer(minLength: 0)
                self.actions
            }

            VStack(alignment: .leading, spacing: 10) {
                self.summary(palette: palette)
                self.actions
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.56))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.warning.opacity(0.20), lineWidth: 1)
        )
        .accessibilityIdentifier("account-pool-batch-remove-bar")
    }

    private func summary(palette: AppearancePalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.warning)
            Text(self.model.batchRemoveSelectedCountText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.accountPoolFilterSummaryText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
        }
        .lineLimit(1)
    }

    private var actions: some View {
        QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            Button(self.model.text(.actionSelectVisibleAccounts)) {
                self.model.selectVisibleAccountsForBatchRemove()
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
            .disabled(self.model.visibleAccountPoolAccounts.isEmpty || self.model.isBatchRemovingAccounts)

            Button(self.model.text(.actionClearBatchSelection)) {
                self.model.clearBatchRemoveSelection()
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
            .disabled(self.model.selectedBatchRemoveAccountIDs.isEmpty || self.model.isBatchRemovingAccounts)

            Button(self.model.text(.actionDoneBatchRemoveAccounts)) {
                self.model.exitAccountBatchRemoveMode()
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
            .disabled(self.model.isBatchRemovingAccounts)

            Button(role: .destructive) {
                Task { await self.model.removeSelectedBatchAccounts() }
            } label: {
                HStack(spacing: 6) {
                    if self.model.isBatchRemovingAccounts {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(self.model.text(.actionRemoveSelectedAccounts))
                }
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .danger))
            .disabled(!self.model.canRemoveSelectedBatchAccounts)
        }
    }
}

private struct AccountPoolResultChip: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: 8) {
            Text(self.title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            Text(self.value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(palette.accentSoft.opacity(self.colorScheme == .dark ? 0.92 : 0.98))
        )
        .overlay(
            Capsule()
                .stroke(palette.accent.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct AccountPoolHeaderAccessory: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                self.countPill
                AccountPoolDisplayModePicker(model: self.model, compact: true)
            }

            VStack(alignment: .trailing, spacing: 6) {
                self.countPill
                AccountPoolDisplayModePicker(model: self.model, compact: true)
            }
        }
    }

    private var countPill: some View {
        StatusPill(text: self.model.accountPoolTotalCountText, tone: .accent, compact: true)
    }
}

private struct AccountPoolDisplayModePicker: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let compact: Bool

    private var selection: Binding<DesktopAccountPoolDisplayMode> {
        Binding(
            get: { self.model.accountPoolDisplayMode },
            set: { self.model.updateAccountPoolDisplayMode($0) }
        )
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Group {
            if self.compact {
                self.segmentedControl
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.model.text(.labelDisplay).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(palette.textMuted)

                    self.segmentedControl
                }
            }
        }
    }

    private var segmentedControl: some View {
        Picker(self.model.text(.labelDisplay), selection: self.selection) {
            Text(self.model.label(for: .cards)).tag(DesktopAccountPoolDisplayMode.cards)
            Text(self.model.label(for: .list)).tag(DesktopAccountPoolDisplayMode.list)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(self.compact ? .small : .regular)
        .frame(width: self.compact ? 148 : 186)
        .accessibilityLabel(self.model.text(.labelDisplay))
    }
}

private struct AccountBatchSelectionMark: View {
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Image(systemName: self.isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(self.isSelected ? palette.warning : palette.textMuted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

private struct AccountPoolListPane: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(self.model.visibleAccountPoolAccounts.enumerated()), id: \.element.id) { index, account in
                AccountPoolListRow(
                    account: account,
                    model: self.model,
                    isSelected: self.model.selectedAccountPoolAccountID == account.id,
                    isBatchRemovalMode: self.model.isAccountBatchRemoveModeEnabled,
                    isBatchSelected: self.model.isSelectedForBatchRemove(account),
                    usesAlternateBackground: index.isMultiple(of: 2) == false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panel.opacity(self.colorScheme == .dark ? 0.98 : 0.96),
                            palette.panelRaised.opacity(self.colorScheme == .dark ? 0.95 : 0.92),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct AccountPoolListRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let account: AccountSummary
    @ObservedObject var model: DesktopAppModel
    let isSelected: Bool
    let isBatchRemovalMode: Bool
    let isBatchSelected: Bool
    let usesAlternateBackground: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let status = self.model.minimalAccountStatusPresentation(self.account)
        let usageSummary = self.model.minimalAccountUsageSummary(self.account)
        let rowBackground = self.isSelected
            ? palette.accentSoft.opacity(self.colorScheme == .dark ? 0.34 : 0.92)
            : self.idleRowBackground(palette: palette)
        let rowBorder = self.isSelected ? palette.accent.opacity(0.32) : palette.border

        Button {
            if self.isBatchRemovalMode {
                self.model.toggleBatchRemoveSelection(for: self.account)
            } else {
                self.model.presentAccountPoolDetailDrawer(for: self.account)
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 10) {
                    if self.isBatchRemovalMode {
                        AccountBatchSelectionMark(isSelected: self.isBatchSelected)
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(self.account.isCurrent ? palette.successSoft : palette.panelMuted)
                        Image(systemName: self.account.isCurrent ? "checkmark.seal.fill" : "person.crop.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(self.account.isCurrent ? palette.success : palette.accent)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.account.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                            .help(self.account.label)

                        Text(self.identityText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                            .help(self.identityText)
                    }

                    Spacer(minLength: 8)

                    Text(usageSummary)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 84, idealWidth: 92, maxWidth: 104, alignment: .trailing)
                        .help(usageSummary)

                    StatusPill(text: status.text, tone: status.tone, compact: true)
                }

                HStack(spacing: 6) {
                    self.pills
                }

                if let issueText = self.model.accountIssueText(self.account) {
                    Text(issueText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(issueText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(rowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(rowBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .interactiveCursor()
    }

    private func idleRowBackground(palette: AppearancePalette) -> Color {
        if self.usesAlternateBackground {
            return palette.panelMuted.opacity(self.colorScheme == .dark ? 0.78 : 0.72)
        }
        return palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.78 : 0.88)
    }

    private var identityText: String {
        let email = self.account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? self.account.accountID : email
    }

    private var pills: some View {
        Group {
            StatusPill(text: self.model.planText(self.account.effectivePlanType), tone: self.planTone, compact: true)
            StatusPill(
                text: self.model.accountAuthModeText(self.account),
                tone: self.account.authMode.isManualAPIKey ? .warning : .accent,
                compact: true
            )
            if self.account.isCurrent {
                StatusPill(text: self.model.text(.statusCurrent), tone: .success, compact: true)
            }
        }
    }

    private var planTone: StatusPill.Tone {
        switch AccountPoolListHelper.normalizedPlan(for: self.account) {
        case .free:
            return .success
        case .plus, .pro:
            return .accent
        case .apiKey:
            return .warning
        case .all, .other:
            return .neutral
        }
    }
}

struct AccountPoolDetailDrawer: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let account: AccountSummary
    let width: CGFloat

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        AccountPoolDetailSidebar(
            model: self.model,
            account: self.account,
            width: self.width
        )
        .overlay(alignment: .topTrailing) {
            Button {
                self.model.dismissAccountPoolDetailDrawer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
            .padding(12)
            .accessibilityIdentifier("account-pool-detail-drawer-close")
        }
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? 0.32 : 0.12),
            radius: 20,
            x: -8,
            y: 12
        )
        .accessibilityIdentifier("account-pool-detail-drawer")
    }
}

struct AccountPoolDetailSidebar: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let account: AccountSummary?
    let width: CGFloat

    private let usageColumns = [
        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 8, alignment: .top),
    ]

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            Text(self.model.localized(zh: "账号详情", en: "Account Details").uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            if let account {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        self.header(for: account, palette: palette)

                        AccountPoolSidebarPanel {
                            LazyVGrid(columns: self.usageColumns, alignment: .leading, spacing: 8) {
                                ForEach(self.model.accountUsageTiles(for: account)) { tile in
                                    AccountUsageMiniTile(
                                        title: tile.title,
                                        value: tile.value,
                                        subtitle: tile.subtitle,
                                        helpText: tile.helpText,
                                        tone: tile.tone,
                                        symbol: tile.symbol
                                    )
                                }
                            }
                        }

                        AccountPoolSidebarPanel(title: self.model.localized(zh: "详情", en: "Details")) {
                            VStack(alignment: .leading, spacing: 10) {
                                AccountMetaRow(
                                    label: self.model.text(.labelActiveAccount),
                                    value: account.accountID,
                                    lineLimit: 3,
                                    monospaced: true,
                                    selectable: true
                                )
                                if let upstreamBaseURL = account.upstreamBaseURL, upstreamBaseURL.isEmpty == false {
                                    AccountMetaRow(
                                        label: self.model.text(.labelAccountBaseURL),
                                        value: upstreamBaseURL,
                                        lineLimit: 3,
                                        monospaced: true,
                                        selectable: true
                                    )
                                }
                                if let providerPreset = self.model.accountProviderPresetText(account) {
                                    AccountMetaRow(
                                        label: self.model.text(.labelProviderPreset),
                                        value: providerPreset
                                    )
                                }
                                AccountMetaRow(
                                    label: self.model.text(.labelOutboundNode),
                                    value: self.model.accountManagedProxyNodeStatusText(account)
                                )
                                AccountMetaRow(
                                    label: self.model.text(.labelModelRouting),
                                    value: self.model.accountModelRoutingStatusText(account)
                                )
                                AccountMetaRow(
                                    label: self.model.text(.labelEnabled),
                                    value: account.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled)
                                )
                                if account.authMode.isManualAPIKey {
                                    AccountMetaRow(
                                        label: self.model.text(.labelAutomaticCooldown),
                                        value: self.model.accountCooldownPolicyText(account)
                                    )
                                }
                                AccountMetaRow(
                                    label: self.model.text(.labelStatus),
                                    value: self.model.accountRuntimeStatusText(account)
                                )
                            }
                        }

                        if let clientAccess = self.model.anthropicAPICompatibleClientAccessPresentation(for: account) {
                            AccountClientAccessPanel(model: self.model, presentation: clientAccess)
                        }

                        if let issueText = self.model.accountIssueText(account) {
                            self.issuePanel(issueText, palette: palette)
                        }

                        AccountPoolSidebarPanel(title: self.model.localized(zh: "操作", en: "Actions")) {
                            QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                self.refreshUsageButton(for: account)
                                self.editActionButton(for: account)
                                self.outboundNodeButton(for: account)
                                self.modelRoutingButton(for: account)
                                self.cooldownPolicyButton(for: account)
                                self.stopCooldownButton(for: account)
                                self.enableToggleButton(for: account)
                                self.removeButton(for: account)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
                EmptyStatePanel(
                    title: self.model.localized(zh: "选择一个账号查看详情", en: "Select an account to view details"),
                    detail: self.model.localized(
                        zh: "点击左侧任意账号行后，这里会显示完整状态、配置和可执行操作。",
                        en: "Click any account row on the left to inspect its status, configuration, and available actions."
                    )
                )
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: self.width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panel.opacity(self.colorScheme == .dark ? 0.98 : 0.96),
                            palette.panelRaised.opacity(self.colorScheme == .dark ? 0.95 : 0.92),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func header(for account: AccountSummary, palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(account.isCurrent ? palette.successSoft : palette.accentSoft)
                    Image(systemName: account.isCurrent ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(account.isCurrent ? palette.success : palette.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(account.label)

                    Text(self.identityText(for: account))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(self.identityText(for: account))
                }

                Spacer(minLength: 0)
            }

            QuickActionWrapLayout(horizontalSpacing: 7, verticalSpacing: 7) {
                StatusPill(text: self.model.planText(account.effectivePlanType), tone: self.planTone(for: account))
                StatusPill(
                    text: self.model.accountAuthModeText(account),
                    tone: account.authMode.isManualAPIKey ? .warning : .accent
                )
                StatusPill(
                    text: account.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled),
                    tone: account.enabled ? .success : .warning
                )
                StatusPill(
                    text: self.model.accountRuntimeStatusText(account),
                    tone: self.model.minimalAccountStatusPresentation(account).tone
                )
                if account.isCurrent {
                    StatusPill(text: self.model.text(.statusCurrent), tone: .success)
                }
            }
        }
    }

    private func issuePanel(_ issueText: String, palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.warning)
                Text(self.model.text(.labelLastError))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }

            Text(issueText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(issueText)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.56))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(palette.warning.opacity(0.18), lineWidth: 1)
        )
    }

    private func refreshUsageButton(for account: AccountSummary) -> some View {
        Button {
            Task { await self.model.refreshUsage(for: account) }
        } label: {
            HStack(spacing: 6) {
                if self.model.isRefreshingUsage(for: account.id) {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(self.model.accountCardRefreshActionTitle(for: account.id))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        .disabled(self.model.isRefreshingUsage(for: account.id))
    }

    @ViewBuilder
    private func editActionButton(for account: AccountSummary) -> some View {
        if let title = self.model.accountCardEditActionTitle(for: account) {
            Button(title) {
                Task { await self.model.performAccountCardEditAction(for: account) }
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        }
    }

    private func outboundNodeButton(for account: AccountSummary) -> some View {
        Button(self.model.accountCardNodeActionTitle) {
            self.model.openAccountManagedProxyNodeSheet(account)
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
    }

    private func modelRoutingButton(for account: AccountSummary) -> some View {
        Button(self.model.text(.actionEditModelRouting)) {
            self.model.openAccountModelRoutingSheet(account)
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
    }

    private func enableToggleButton(for account: AccountSummary) -> some View {
        Button(account.enabled ? self.model.text(.actionDisableAccount) : self.model.text(.actionEnableAccount)) {
            Task { await self.model.toggleAccountEnabled(account) }
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
    }

    @ViewBuilder
    private func stopCooldownButton(for account: AccountSummary) -> some View {
        if self.model.canStopAccountCooldown(account) {
            Button(self.model.text(.actionStopAccountCooldown)) {
                Task { await self.model.stopAccountCooldown(account) }
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        }
    }

    @ViewBuilder
    private func cooldownPolicyButton(for account: AccountSummary) -> some View {
        if self.model.canUpdateAccountCooldownPolicy(account) {
            Button(self.model.accountCooldownPolicyActionTitle(account)) {
                Task { await self.model.toggleAccountCooldownPolicy(account) }
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        }
    }

    private func removeButton(for account: AccountSummary) -> some View {
        Button(self.model.text(.actionRemoveAuthorization)) {
            Task { await self.model.removeAccount(account) }
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .danger))
    }

    private func identityText(for account: AccountSummary) -> String {
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? account.accountID : email
    }

    private func planTone(for account: AccountSummary) -> StatusPill.Tone {
        switch AccountPoolListHelper.normalizedPlan(for: account) {
        case .free:
            return .success
        case .plus, .pro:
            return .accent
        case .apiKey:
            return .warning
        case .all, .other:
            return .neutral
        }
    }
}

private struct AccountPoolSidebarPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)
            }

            self.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.80 : 0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

struct OAuthFlowPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let draft: DesktopAppModel.OAuthDraft

    private var callbackBinding: Binding<String> {
        Binding(
            get: { self.model.oauthDraft?.callbackURL ?? "" },
            set: { newValue in
                guard var draft = self.model.oauthDraft else { return }
                draft.callbackURL = newValue
                self.model.oauthDraft = draft
            }
        )
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(self.model.oauthFlowTitle(for: self.draft.providerFamily))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.model.oauthManualHint(for: self.draft.providerFamily))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    StatusPill(
                        text: self.model.label(for: self.draft.providerFamily),
                        tone: self.model.providerFamilyTone(self.draft.providerFamily)
                    )
                    StatusPill(text: self.model.text(.oauthListening), tone: .accent)
                }
            }

            FormFieldPanel(title: self.model.text(.oauthLinkLabel), footer: self.model.text(.oauthAutoImportHint)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(self.draft.prepared.authURL)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(palette.panelMuted.opacity(0.92))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(palette.border, lineWidth: 1)
                        )

                    DetailRow(label: self.model.text(.labelRedirectURI), value: self.draft.prepared.redirectURI)

                    HStack(spacing: 10) {
                        Button(self.model.text(.oauthOpenBrowser)) {
                            self.model.openOAuthAuthorizationPage()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))

                        Button(self.model.text(.commonCopy)) {
                            self.model.copyOAuthAuthorizationLink()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }
                }
            }

            FormFieldPanel(title: self.model.text(.oauthCallbackLabel), footer: self.model.text(.oauthCallbackHint)) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(self.model.text(.oauthCallbackPlaceholder), text: self.callbackBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(palette.panelMuted.opacity(0.92))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(palette.border, lineWidth: 1)
                        )

                    HStack(spacing: 10) {
                        Button(self.model.text(.oauthParseCallback)) {
                            Task { await self.model.completeOAuth() }
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))

                        Button(self.model.text(.commonDismiss)) {
                            self.model.dismissOAuthDraft()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.panelRaised.opacity(0.98), palette.panel.opacity(0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(palette.accent.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct ManualAPIKeyAccountSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let presentedDraft: DesktopAppModel.ManualAPIKeyDraft

    private var draftBinding: Binding<DesktopAppModel.ManualAPIKeyDraft> {
        Binding(
            get: { self.model.resolvedManualAPIKeyDraft(for: self.presentedDraft) },
            set: { newValue in
                self.model.updateManualAPIKeyDraft(newValue, for: self.presentedDraft)
            }
        )
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(self.model.manualAPIKeySheetTitle(for: self.presentedDraft))
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                            Text(self.model.text(.helperManualAPIKeyAccount))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        StatusPill(text: self.model.planText("api_key"), tone: .warning)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ManualAPIKeyAccountForm(
                            model: self.model,
                            draft: self.draftBinding
                        )
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: 10) {
                Button(self.model.text(.commonCancel)) {
                    self.model.dismissManualAPIKeySheet()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                .disabled(self.model.manualAPIKeyIsSubmitting)

                Spacer(minLength: 0)

                Button(self.model.text(.actionSaveAccount)) {
                    Task { await self.model.submitManualAPIKeyAccount() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(self.model.manualAPIKeyIsSubmitting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
        }
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 560, minHeight: 420, idealHeight: 500, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
        .compactOverlayScrollbars()
    }
}

private struct AccountLabelSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(self.model.accountLabelSheetTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                FormFieldPanel(title: self.model.text(.labelLabel)) {
                    TextField(
                        self.model.text(.labelAccountLabel),
                        text: self.binding(for: \.label)
                    )
                    .dashboardFieldChrome()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: 10) {
                Button(self.model.text(.commonCancel)) {
                    self.model.dismissAccountLabelSheet()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                .disabled(self.model.accountLabelIsSubmitting)

                Spacer(minLength: 0)

                Button(self.model.text(.actionSaveAccount)) {
                    Task { await self.model.submitAccountLabelUpdate() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(self.model.accountLabelIsSubmitting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
        }
        .frame(minWidth: 420, idealWidth: 440, maxWidth: 480, minHeight: 220, idealHeight: 240, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
        .compactOverlayScrollbars()
    }

    private func binding<Value>(for keyPath: WritableKeyPath<DesktopAppModel.AccountLabelDraft, Value>) -> Binding<Value> {
        Binding(
            get: {
                self.model.accountLabelDraft?[keyPath: keyPath]
                    ?? DesktopAppModel.AccountLabelDraft(accountID: "", accountKey: "", label: "")[keyPath: keyPath]
            },
            set: { newValue in
                guard var draft = self.model.accountLabelDraft else { return }
                draft[keyPath: keyPath] = newValue
                self.model.accountLabelDraft = draft
            }
        )
    }
}

private struct AccountManagedProxyNodeSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    private var draftBinding: Binding<DesktopAppModel.AccountManagedProxyNodeDraft> {
        Binding(
            get: {
                self.model.accountManagedProxyNodeDraft
                    ?? DesktopAppModel.AccountManagedProxyNodeDraft(
                        accountID: "",
                        accountKey: "",
                        label: "",
                        managedProxyNodeName: nil
                    )
            },
            set: { newValue in
                self.model.accountManagedProxyNodeDraft = newValue
            }
        )
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let draft = self.draftBinding.wrappedValue

        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(self.model.accountManagedProxyNodeSheetTitle)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                            Text(draft.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        StatusPill(text: self.selectionSummary(for: draft), tone: self.selectionTone(for: draft))
                    }

                    FormFieldPanel(
                        title: self.model.text(.labelOutboundNode),
                        footer: self.model.accountManagedProxyNodePickerHint()
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            AccountManagedProxyNodeOptionRow(
                                title: self.model.localized(zh: "不自定义 / 跟随全局", en: "Use Global"),
                                subtitle: self.model.localized(
                                    zh: "继续跟随设置页当前的全局出站模式；留空时，这个账号不会单独覆盖出口。",
                                    en: "Keep following the current global outbound mode from Settings. Leaving this empty means the account does not override egress on its own."
                                ),
                                isSelected: AccountSummary.normalizedManagedProxyNodeName(draft.managedProxyNodeName) == nil,
                                isDisabled: false
                            ) {
                                var updated = draft
                                updated.managedProxyNodeName = nil
                                self.draftBinding.wrappedValue = updated
                            }

                            if let warning = self.model.accountManagedProxyNodeUnavailableWarning(for: draft) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(palette.warning)
                                    Text(warning)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(palette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.56))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(palette.warning.opacity(0.18), lineWidth: 1)
                                )
                            }

                            ForEach(self.model.managedProxySnapshot.nodes) { node in
                                AccountManagedProxyNodeOptionRow(
                                    title: node.name,
                                    subtitle: self.nodeSubtitle(node),
                                    isSelected: AccountSummary.normalizedManagedProxyNodeName(draft.managedProxyNodeName) == node.name,
                                    isDisabled: self.model.canSelectAccountManagedProxyNodeOptions == false
                                ) {
                                    guard self.model.canSelectAccountManagedProxyNodeOptions else { return }
                                    var updated = draft
                                    updated.managedProxyNodeName = node.name
                                    self.draftBinding.wrappedValue = updated
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack(spacing: 10) {
                Button(self.model.text(.commonCancel)) {
                    self.model.dismissAccountManagedProxyNodeSheet()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                .disabled(self.model.accountManagedProxyNodeIsSubmitting)

                Spacer(minLength: 0)

                Button(self.model.text(.actionSaveAccount)) {
                    Task { await self.model.submitAccountManagedProxyNodeUpdate() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(self.model.accountManagedProxyNodeIsSubmitting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
        }
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 620, minHeight: 360, idealHeight: 440, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
        .compactOverlayScrollbars()
    }

    private func selectionSummary(for draft: DesktopAppModel.AccountManagedProxyNodeDraft) -> String {
        guard let nodeName = AccountSummary.normalizedManagedProxyNodeName(draft.managedProxyNodeName) else {
            return self.model.localized(zh: "跟随全局", en: "Use Global")
        }
        if !self.model.availableManagedProxyNodeNames.isEmpty,
           self.model.availableManagedProxyNodeNames.contains(nodeName) == false
        {
            return self.model.localized(zh: "节点不可用", en: "Node Unavailable")
        }
        if self.model.accountManagedProxyNodeUnavailableWarning(for: draft) != nil {
            return self.model.localized(zh: "需要处理", en: "Needs Attention")
        }
        return nodeName
    }

    private func selectionTone(for draft: DesktopAppModel.AccountManagedProxyNodeDraft) -> StatusPill.Tone {
        if AccountSummary.normalizedManagedProxyNodeName(draft.managedProxyNodeName) == nil {
            return .neutral
        }
        if self.model.accountManagedProxyNodeUnavailableWarning(for: draft) != nil {
            return .warning
        }
        return .accent
    }

    private func nodeSubtitle(_ node: ManagedProxyNode) -> String? {
        var parts: [String] = []
        if node.isCurrent {
            parts.append(self.model.localized(zh: "当前节点", en: "Current Node"))
        }
        if let alive = node.alive, alive == false {
            parts.append(self.model.localized(zh: "连接异常", en: "Unavailable"))
        }
        if let delay = node.lastDelayMS {
            parts.append("\(delay) ms")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct AccountManagedProxyNodeOptionRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Button(action: self.action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: self.isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(self.isSelected ? palette.accent : palette.textMuted)

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    if let subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        self.isSelected
                            ? palette.accentSoft.opacity(self.colorScheme == .dark ? 0.92 : 0.98)
                            : palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.84 : 0.90)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        self.isSelected ? palette.accent.opacity(0.20) : palette.border,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(self.isDisabled)
        .opacity(self.isDisabled ? 0.55 : 1)
    }
}

private struct AccountOrderSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let visibleEntries = self.model.accountOrderVisibleEntries

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(self.model.accountOrderSheetTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                Text(self.model.text(.helperSelectionPolicy))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                self.searchBar(palette: palette)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(self.model.accountOrderVisibleCountText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textMuted)

                    Spacer(minLength: 0)

                    Text(self.model.text(.helperAccountOrderSearch))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            List {
                if visibleEntries.isEmpty {
                    Text(self.model.text(.placeholderNoMatchingAccountOrder))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                        .listRowSeparator(.hidden)
                } else if self.model.accountOrderIsSearching {
                    ForEach(visibleEntries) { entry in
                        self.row(for: entry)
                    }
                } else {
                    ForEach(visibleEntries) { entry in
                        self.row(for: entry)
                    }
                    .onMove { indices, newOffset in
                        self.model.moveAccountOrderDraft(fromOffsets: indices, toOffset: newOffset)
                    }
                }
            }
            .frame(minHeight: 440, idealHeight: 520)

            Divider()

            HStack(spacing: 10) {
                Button(self.model.text(.commonCancel)) {
                    self.model.dismissAccountOrderSheet()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                .disabled(self.model.accountOrderIsSubmitting)

                Spacer(minLength: 0)

                Button(self.model.text(.actionSaveAccountOrder)) {
                    Task { await self.model.submitAccountOrderUpdate() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(self.model.accountOrderIsSubmitting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
        }
        .frame(minWidth: 720, idealWidth: 780, maxWidth: 920, minHeight: 640, idealHeight: 720, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
        .compactOverlayScrollbars()
    }

    private var searchText: Binding<String> {
        Binding(
            get: { self.model.accountOrderDraft?.searchQuery ?? "" },
            set: { self.model.accountOrderDraft?.searchQuery = $0 }
        )
    }

    private func searchBar(palette: AppearancePalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textMuted)

            TextField(self.model.text(.placeholderSearchAccountOrder), text: self.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.86 : 0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func row(for entry: DesktopAppModel.AccountOrderVisibleEntry) -> some View {
        AccountOrderRow(
            model: self.model,
            index: entry.position,
            account: entry.account
        )
    }
}

private struct AccountModelRoutingSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    private var draftBinding: Binding<DesktopAppModel.AccountModelRoutingDraft> {
        Binding(
            get: {
                self.model.accountModelRoutingDraft
                    ?? DesktopAppModel.AccountModelRoutingDraft(
                        accountID: "",
                        accountKey: "",
                        label: "",
                        defaultTargetModel: "",
                        mappings: []
                    )
            },
            set: { newValue in
                self.model.accountModelRoutingDraft = newValue
            }
        )
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let draft = self.draftBinding.wrappedValue

        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(self.model.accountModelRoutingSheetTitle)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                            Text(draft.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        StatusPill(text: self.selectionSummary(for: draft), tone: self.selectionTone(for: draft))
                    }

                    FormFieldPanel(
                        title: self.model.text(.labelAnthropicDefaultTargetModel),
                        footer: self.model.accountModelRoutingHint()
                    ) {
                        TextField(
                            self.model.text(.labelAnthropicDefaultTargetModel),
                            text: self.binding(for: \.defaultTargetModel)
                        )
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(draft.mappings.indices), id: \.self) { index in
                            self.mappingRow(index: index)
                        }

                        Button(self.model.text(.actionAddAnthropicMapping), action: self.addMapping)
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(self.model.accountModelRoutingTargetHint())
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack(spacing: 10) {
                Button(self.model.text(.commonCancel)) {
                    self.model.dismissAccountModelRoutingSheet()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                .disabled(self.model.accountModelRoutingIsSubmitting)

                Spacer(minLength: 0)

                Button(self.model.text(.actionSaveAccount)) {
                    Task { await self.model.submitAccountModelRoutingUpdate() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(self.model.accountModelRoutingIsSubmitting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 700, minHeight: 420, idealHeight: 520, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
        .compactOverlayScrollbars()
    }

    @ViewBuilder
    private func mappingRow(index: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                self.sourceModelField(index: index)
                self.targetModelField(index: index)
                self.removeButton(index: index)
            }

            VStack(alignment: .leading, spacing: 10) {
                self.sourceModelField(index: index)
                HStack(alignment: .top, spacing: 12) {
                    self.targetModelField(index: index)
                    self.removeButton(index: index)
                }
            }
        }
    }

    private func sourceModelField(index: Int) -> some View {
        FormFieldPanel(title: self.model.text(.labelAnthropicSourceModel)) {
            TextField(
                self.model.text(.labelAnthropicSourceModel),
                text: self.mappingBinding(index: index, keyPath: \.sourceModel)
            )
            .textFieldStyle(.plain)
            .dashboardFieldChrome()
        }
    }

    private func targetModelField(index: Int) -> some View {
        FormFieldPanel(title: self.model.text(.labelAnthropicTargetModel)) {
            TextField(
                self.model.text(.labelAnthropicTargetModel),
                text: self.mappingBinding(index: index, keyPath: \.targetModel)
            )
            .textFieldStyle(.plain)
            .dashboardFieldChrome()
        }
    }

    private func removeButton(index: Int) -> some View {
        Button(self.model.text(.actionRemoveAnthropicMapping)) {
            self.removeMapping(index: index)
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
    }

    private func binding(
        for keyPath: WritableKeyPath<DesktopAppModel.AccountModelRoutingDraft, String>
    ) -> Binding<String> {
        Binding(
            get: {
                self.model.accountModelRoutingDraft?[keyPath: keyPath]
                    ?? DesktopAppModel.AccountModelRoutingDraft(
                        accountID: "",
                        accountKey: "",
                        label: "",
                        defaultTargetModel: "",
                        mappings: []
                    )[keyPath: keyPath]
            },
            set: { newValue in
                guard var draft = self.model.accountModelRoutingDraft else { return }
                draft[keyPath: keyPath] = newValue
                self.model.accountModelRoutingDraft = draft
            }
        )
    }

    private func mappingBinding(
        index: Int,
        keyPath: WritableKeyPath<AccountModelMapping, String>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let draft = self.model.accountModelRoutingDraft,
                      draft.mappings.indices.contains(index)
                else {
                    return ""
                }
                return draft.mappings[index][keyPath: keyPath]
            },
            set: { newValue in
                guard var draft = self.model.accountModelRoutingDraft,
                      draft.mappings.indices.contains(index)
                else {
                    return
                }
                draft.mappings[index][keyPath: keyPath] = newValue
                self.model.accountModelRoutingDraft = draft
            }
        )
    }

    private func addMapping() {
        guard var draft = self.model.accountModelRoutingDraft else { return }
        draft.mappings.append(AccountModelMapping())
        self.model.accountModelRoutingDraft = draft
    }

    private func removeMapping(index: Int) {
        guard var draft = self.model.accountModelRoutingDraft,
              draft.mappings.indices.contains(index)
        else {
            return
        }
        draft.mappings.remove(at: index)
        self.model.accountModelRoutingDraft = draft
    }

    private func selectionSummary(for draft: DesktopAppModel.AccountModelRoutingDraft) -> String {
        let normalized = self.model.normalizedAccountModelRouting(for: draft)
        let mappingCount = normalized?.mappings.count ?? 0
        let defaultTargetModel = normalized?.defaultTargetModel

        if defaultTargetModel != nil, mappingCount > 0 {
            return self.model.localized(
                zh: "默认 + \(mappingCount) 条映射",
                en: "Default + \(mappingCount) mappings"
            )
        }
        if defaultTargetModel != nil {
            return self.model.localized(zh: "仅默认目标", en: "Default Only")
        }
        if mappingCount > 0 {
            return self.model.localized(
                zh: "\(mappingCount) 条映射",
                en: "\(mappingCount) mappings"
            )
        }
        return self.model.localized(zh: "未配置", en: "Not Configured")
    }

    private func selectionTone(for draft: DesktopAppModel.AccountModelRoutingDraft) -> StatusPill.Tone {
        self.model.normalizedAccountModelRouting(for: draft) == nil ? .neutral : .accent
    }
}

private struct AccountOrderRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var targetPosition = ""

    @ObservedObject var model: DesktopAppModel
    let index: Int
    let account: AccountSummary

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(alignment: .top, spacing: 12) {
            Text("\(self.index)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.accent)
                .frame(width: 28, alignment: .leading)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(self.account.label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(2)

                            Text(self.account.email?.isEmpty == false ? self.account.email! : self.account.accountID)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(palette.textMuted)
                            .help(self.model.localized(zh: "未搜索时仍可拖拽排序", en: "Drag to reorder when search is empty"))
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            self.pills
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            self.pills
                        }
                    }

                    if let issue = self.model.accountRuntimeIssueText(self.account) {
                        Text(issue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                self.orderActions(palette: palette)
            }
        }
        .padding(.vertical, 4)
    }

    private var pills: some View {
        Group {
            StatusPill(text: self.model.accountAuthModeText(self.account), tone: self.account.authMode.isManualAPIKey ? .warning : .accent)
            StatusPill(
                text: self.account.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled),
                tone: self.account.enabled ? .success : .warning
            )
            if self.account.isCoolingDown() {
                StatusPill(text: self.model.text(.statusCoolingDown), tone: .warning)
            }
        }
    }

    private func orderActions(palette: AppearancePalette) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                self.iconButton(
                    systemName: "arrow.up.to.line.compact",
                    title: self.model.text(.actionAccountOrderMoveToTop),
                    disabled: !self.model.canMoveAccountOrderDraftUp(accountID: self.account.id)
                ) {
                    self.model.moveAccountOrderDraftToTop(accountID: self.account.id)
                }

                self.iconButton(
                    systemName: "chevron.up",
                    title: self.model.text(.actionAccountOrderMoveUp),
                    disabled: !self.model.canMoveAccountOrderDraftUp(accountID: self.account.id)
                ) {
                    self.model.moveAccountOrderDraftUp(accountID: self.account.id)
                }

                self.iconButton(
                    systemName: "chevron.down",
                    title: self.model.text(.actionAccountOrderMoveDown),
                    disabled: !self.model.canMoveAccountOrderDraftDown(accountID: self.account.id)
                ) {
                    self.model.moveAccountOrderDraftDown(accountID: self.account.id)
                }

                self.iconButton(
                    systemName: "arrow.down.to.line.compact",
                    title: self.model.text(.actionAccountOrderMoveToBottom),
                    disabled: !self.model.canMoveAccountOrderDraftDown(accountID: self.account.id)
                ) {
                    self.model.moveAccountOrderDraftToBottom(accountID: self.account.id)
                }
            }

            HStack(spacing: 6) {
                TextField(self.model.text(.placeholderAccountOrderPosition), text: self.$targetPosition)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 64)
                    .disabled(self.model.accountOrderIsSubmitting)
                    .onSubmit {
                        self.applyTargetPosition()
                    }

                self.iconButton(
                    systemName: "arrow.turn.down.left",
                    title: self.model.text(.actionAccountOrderMoveToPosition),
                    disabled: self.targetPosition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    self.applyTargetPosition()
                }
            }
        }
        .frame(minWidth: 170, alignment: .trailing)
    }

    private func applyTargetPosition() {
        if self.model.moveAccountOrderDraft(accountID: self.account.id, toOneBasedPosition: self.targetPosition) {
            self.targetPosition = ""
        }
    }

    private func iconButton(
        systemName: String,
        title: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(disabled || self.model.accountOrderIsSubmitting)
        .opacity((disabled || self.model.accountOrderIsSubmitting) ? 0.38 : 1)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct AccountCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let account: AccountSummary
    @ObservedObject var model: DesktopAppModel
    let width: CGFloat
    let isBatchRemovalMode: Bool
    let isBatchSelected: Bool

    @State private var isLastErrorPopoverPresented = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 13) {
                if self.isBatchRemovalMode {
                    Button {
                        self.model.toggleBatchRemoveSelection(for: self.account)
                    } label: {
                        AccountBatchSelectionMark(isSelected: self.isBatchSelected)
                    }
                    .buttonStyle(.plain)
                    .interactiveCursor()
                    .accessibilityIdentifier("account-card-batch-select-\(self.account.id)")
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(self.account.isCurrent ? palette.successSoft : palette.accentSoft)
                    Image(systemName: self.account.isCurrent ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(self.account.isCurrent ? palette.success : palette.accent)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    Text(self.account.label)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(self.account.label)

                    if let email = self.account.email, !email.isEmpty {
                        Text(email)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(email)
                    }
                }

                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    self.badgesRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(self.model.accountUsageTiles(for: self.account)) { tile in
                    AccountUsageMiniTile(
                        title: tile.title,
                        value: tile.value,
                        subtitle: tile.subtitle,
                        helpText: tile.helpText,
                        tone: tile.tone,
                        symbol: tile.symbol
                    )
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                AccountMetaRow(
                    label: self.model.text(.labelActiveAccount),
                    value: self.account.accountID,
                    lineLimit: 3,
                    monospaced: true,
                    selectable: true
                )
                if let upstreamBaseURL = self.account.upstreamBaseURL, upstreamBaseURL.isEmpty == false {
                    AccountMetaRow(
                        label: self.model.text(.labelAccountBaseURL),
                        value: upstreamBaseURL,
                        lineLimit: 3,
                        monospaced: true,
                        selectable: true
                    )
                }
                if let providerPreset = self.model.accountProviderPresetText(self.account) {
                    AccountMetaRow(
                        label: self.model.text(.labelProviderPreset),
                        value: providerPreset
                    )
                }
                AccountMetaRow(
                    label: self.model.text(.labelOutboundNode),
                    value: self.model.accountManagedProxyNodeStatusText(self.account)
                )
                AccountMetaRow(
                    label: self.model.text(.labelModelRouting),
                    value: self.model.accountModelRoutingStatusText(self.account)
                )
                AccountMetaRow(
                    label: self.model.text(.labelEnabled),
                    value: self.account.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled)
                )
                if self.account.authMode.isManualAPIKey {
                    AccountMetaRow(
                        label: self.model.text(.labelAutomaticCooldown),
                        value: self.model.accountCooldownPolicyText(self.account)
                    )
                }
                AccountMetaRow(
                    label: self.model.text(.labelStatus),
                    value: self.model.accountRuntimeStatusText(self.account)
                )
            }

            if let clientAccess = self.model.anthropicAPICompatibleClientAccessPresentation(for: self.account) {
                AccountClientAccessPanel(model: self.model, presentation: clientAccess)
            }

            self.actionButtons
        }
        .padding(17)
        .frame(width: self.width, alignment: .leading)
        .background(AccountCardFrameProbe(identifier: "account-card-\(self.account.id)"))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.95), palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 0.90)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .shadow(color: palette.shadow.opacity(self.colorScheme == .dark ? 0.16 : 0.07), radius: 12, x: 0, y: 6)
        .opacity(self.account.enabled ? 1.0 : 0.90)
        .saturation(self.account.enabled ? 1.0 : 0.76)
    }

    private var badgesRow: some View {
        Group {
            StatusPill(text: self.model.planText(self.account.effectivePlanType), tone: self.badgeTone)

            if self.account.isCurrent {
                StatusPill(text: self.model.text(.statusCurrent), tone: .success)
            }

            StatusPill(
                text: self.account.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled),
                tone: self.account.enabled ? .accent : .warning
            )

            if self.account.authRefreshBlocked {
                StatusPill(text: self.model.text(.optionRefreshBlocked), tone: .warning)
            }

            if AccountPoolListHelper.hasActiveQuotaBlock(self.account) {
                StatusPill(text: self.model.localization.accountQuotaBlockedLabel(), tone: .warning)
            }

            if self.account.isCoolingDown() {
                StatusPill(text: self.model.text(.statusCoolingDown), tone: .warning)
            }

            if let errorText = self.errorText {
                AccountLastErrorPillButton(
                    model: self.model,
                    accountID: self.account.id,
                    errorText: errorText,
                    isPresented: self.$isLastErrorPopoverPresented
                )
            }
        }
    }

    private var badgeTone: StatusPill.Tone {
        switch AccountPoolListHelper.normalizedPlan(for: self.account) {
        case .free:
            return .success
        case .plus, .pro:
            return .accent
        case .apiKey:
            return .warning
        default:
            return .neutral
        }
    }

    private var errorText: String? {
        self.model.accountIssueText(self.account)
    }

    private var isRefreshingUsage: Bool {
        self.model.isRefreshingUsage(for: self.account.id)
    }

    private var actionButtons: some View {
        HStack(alignment: .center, spacing: 6) {
            self.refreshUsageButton
            self.editActionButton
            self.outboundNodeButton
            self.modelRoutingButton
            Spacer(minLength: 0)
            self.moreActionsMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AccountCardActionFrameProbe(identifier: "account-card-actions-\(self.account.id)"))
    }

    private var refreshUsageButtonLabel: some View {
        HStack(spacing: 6) {
            if self.isRefreshingUsage {
                ProgressView()
                    .controlSize(.small)
            }
            Text(self.model.accountCardRefreshActionTitle(for: self.account.id))
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var refreshUsageButton: some View {
        Button {
            Task { await self.model.refreshUsage(for: self.account) }
        } label: {
            self.refreshUsageButtonLabel
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        .disabled(self.isRefreshingUsage)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var outboundNodeButton: some View {
        Button(self.model.accountCardNodeActionTitle) {
            self.model.openAccountManagedProxyNodeSheet(self.account)
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var modelRoutingButton: some View {
        Button(self.model.text(.actionEditModelRouting)) {
            self.model.openAccountModelRoutingSheet(self.account)
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var editActionButton: some View {
        if let title = self.model.accountCardEditActionTitle(for: self.account) {
            Button(title) {
                Task { await self.model.performAccountCardEditAction(for: self.account) }
            }
            .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            if self.model.canUpdateAccountCooldownPolicy(self.account) {
                Button(self.model.accountCooldownPolicyActionTitle(self.account)) {
                    Task { await self.model.toggleAccountCooldownPolicy(self.account) }
                }
            }

            if self.model.canStopAccountCooldown(self.account) {
                Button(self.model.text(.actionStopAccountCooldown)) {
                    Task { await self.model.stopAccountCooldown(self.account) }
                }
            }

            Divider()

            Button(self.account.enabled ? self.model.text(.actionDisableAccount) : self.model.text(.actionEnableAccount)) {
                Task { await self.model.toggleAccountEnabled(self.account) }
            }

            Divider()

            Button(role: .destructive) {
                Task { await self.model.removeAccount(self.account) }
            } label: {
                Text(self.model.text(.actionRemoveAuthorization))
            }
        } label: {
            Text(self.model.accountCardMoreActionTitle)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AccountCardCompactActionButtonStyle(kind: .secondary))
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct AccountLastErrorPillButton: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let accountID: String
    let errorText: String
    @Binding var isPresented: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Button {
            self.isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(palette.warning)

                Text(self.model.text(.labelLastError))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(palette.warning)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                Capsule(style: .continuous)
                    .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.84 : 1.0))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(palette.warning.opacity(0.24), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .background(AccountCardFrameProbe(identifier: "account-card-last-error-\(self.accountID)"))
        .help(self.model.text(.helperAccountCardLastError))
        .accessibilityLabel(self.model.text(.labelLastError))
        .accessibilityIdentifier("account-card-last-error-\(self.accountID)")
        .popover(isPresented: self.$isPresented, arrowEdge: .bottom) {
            AccountLastErrorPopover(model: self.model, errorText: self.errorText)
        }
        .interactiveCursor()
    }
}

private struct AccountLastErrorPopover: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let errorText: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.warning)

                Text(self.model.text(.labelLastError))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }

            ScrollView {
                Text(self.errorText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 1.0))
    }
}

private struct AccountCardFrameProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(self.identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(self.identifier)
    }
}

private struct AccountCardActionFrameProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(self.identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(self.identifier)
    }
}

private struct AccountClientAccessPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let presentation: AccountClientAccessPresentation

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let chrome = self.chrome(palette: palette)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chrome.accent)

                Text(self.model.localized(zh: "客户端接入", en: "Client Access"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)

                Spacer(minLength: 0)

                StatusPill(text: self.presentation.statusText, tone: self.presentation.tone, compact: true)
            }

            CodeValueBlock(
                label: self.model.text(.labelAPIKey),
                value: self.presentation.apiKeyText,
                actionTitle: nil,
                action: nil
            )

            Text(self.presentation.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(self.presentation.detail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(chrome.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(chrome.border, lineWidth: 1)
        )
    }

    private func chrome(
        palette: AppearancePalette
    ) -> (accent: Color, background: Color, border: Color) {
        switch self.presentation.tone {
        case .success:
            return (
                palette.success,
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.56),
                palette.success.opacity(0.18)
            )
        case .warning, .danger:
            return (
                palette.warning,
                palette.warningSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.56),
                palette.warning.opacity(0.18)
            )
        case .accent:
            return (
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.56),
                palette.accent.opacity(0.18)
            )
        case .neutral:
            return (
                palette.textSecondary,
                palette.panelMuted.opacity(self.colorScheme == .dark ? 0.32 : 0.72),
                palette.border
            )
        }
    }
}

private struct AccountUsageMiniTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String
    let subtitle: String?
    let helpText: String?
    let tone: StatusPill.Tone
    let symbol: String

    @ViewBuilder
    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        if let helpText = self.helpText, !helpText.isEmpty {
            self.tileContent(palette: palette, colors: colors)
                .help(helpText)
        } else {
            self.tileContent(palette: palette, colors: colors)
        }
    }

    private func tileContent(
        palette: AppearancePalette,
        colors: (foreground: Color, background: Color, border: Color)
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: self.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.foreground)

                Text(self.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(palette.textMuted)
            }

            Text(self.value)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.76)

            if let subtitle = self.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(subtitle)
            }

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [colors.foreground, colors.foreground.opacity(0.16)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
    }

    private func colors(palette: AppearancePalette) -> (foreground: Color, background: Color, border: Color) {
        switch self.tone {
        case .accent:
            return (palette.accent, palette.accentSoft.opacity(0.94), palette.accent.opacity(0.18))
        case .success:
            return (palette.success, palette.successSoft.opacity(0.94), palette.success.opacity(0.18))
        case .warning:
            return (palette.warning, palette.warningSoft.opacity(0.94), palette.warning.opacity(0.18))
        case .danger:
            return (palette.danger, palette.dangerSoft.opacity(0.94), palette.danger.opacity(0.18))
        case .neutral:
            return (palette.textSecondary, palette.panelMuted.opacity(0.92), palette.border)
        }
    }
}

private struct AccountMetaRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    var lineLimit: Int = 1
    var monospaced = false
    var selectable = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Text(self.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(palette.textMuted)
                .frame(width: 76, alignment: .leading)

            Group {
                if self.selectable {
                    self.valueText.textSelection(.enabled)
                } else {
                    self.valueText
                }
            }
            .help(self.value)
        }
    }

    private var valueText: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return Text(self.value)
            .font(self.monospaced ? .system(size: 12, weight: .semibold, design: .monospaced) : .system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
            .lineLimit(self.lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
