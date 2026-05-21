#if os(macOS)
import CodexProxyCore
import SwiftUI

struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ZStack {
            ShellBackground()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(self.model.localized(zh: "新手引导", en: "Getting Started"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                            Text(self.model.onboardingStepSummary(self.model.onboardingStep))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Button(self.model.localized(zh: "稍后再说", en: "Maybe Later")) {
                            self.model.dismissOnboarding()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }

                    OnboardingStepProgress(model: self.model)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 20)
                .background(palette.panel.opacity(self.colorScheme == .dark ? 0.82 : 0.78))

                Divider()
                    .padding(.horizontal, 28)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch self.model.onboardingStep {
                        case .accountPool:
                            OnboardingAccountPoolStep(model: self.model)
                        case .outboundProxy:
                            OnboardingProxyStep(model: self.model)
                        case .clientAccess:
                            OnboardingClientAccessStep(model: self.model)
                        case .completion:
                            OnboardingCompletionStep(model: self.model)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(palette.windowBottom.opacity(self.colorScheme == .dark ? 0.72 : 0.52))

                Divider()
                    .padding(.horizontal, 28)

                OnboardingFooter(model: self.model)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 0.86))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(palette.windowBottom)
        .compactOverlayScrollbars()
        .sheet(
            item: Binding(
                get: { self.model.authImportDraft },
                set: { newValue in self.model.authImportDraft = newValue }
            )
        ) { presentedDraft in
            AuthImportSheet(model: self.model, presentedDraft: presentedDraft)
                .interactiveDismissDisabled(self.model.authImportIsSubmitting)
        }
    }
}

private struct OnboardingStepProgress: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                self.stepItems(palette: palette)
            }

            VStack(alignment: .leading, spacing: 10) {
                self.stepItems(palette: palette)
            }
        }
    }

    @ViewBuilder
    private func stepItems(palette: AppearancePalette) -> some View {
        ForEach(Array(DesktopAppModel.OnboardingStep.allCases.enumerated()), id: \.offset) { index, step in
            let isCurrent = self.model.onboardingStep == step
            let isCompleted = self.model.onboardingStep.rawValue > step.rawValue

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            isCurrent
                                ? palette.accent
                                : (isCompleted ? palette.accentSoft : palette.panelMuted)
                        )
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(isCurrent ? Color.white : palette.textPrimary)
                }
                .frame(width: 30, height: 30)

                Text(self.model.onboardingStepTitle(step))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? palette.textPrimary : palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isCurrent ? palette.panel : palette.panelRaised.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isCurrent ? palette.accent.opacity(0.24) : palette.border, lineWidth: 1)
            )
        }
    }
}

private struct OnboardingFooter: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        HStack(spacing: 10) {
            if self.model.onboardingStep != .accountPool {
                Button(self.model.localized(zh: "上一步", en: "Back")) {
                    self.model.retreatOnboardingStep()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }

            Spacer(minLength: 0)

            switch self.model.onboardingStep {
            case .accountPool:
                Button(self.model.localized(zh: "下一步", en: "Next")) {
                    self.model.advanceOnboardingStep()
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(self.model.onboardingAccountStepCompleted == false)
            case .outboundProxy:
                Button(self.primaryTitleForProxyStep) {
                    Task { await self.model.continueOnboardingFromProxyStep() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(self.model.isBusy)
            case .clientAccess:
                Button(self.model.localized(zh: "下一步", en: "Next")) {
                    self.model.advanceOnboardingStep()
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            case .completion:
                Button(self.model.localized(zh: "完成", en: "Done")) {
                    self.model.dismissOnboarding()
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            }
        }
    }

    private var primaryTitleForProxyStep: String {
        if self.model.onboardingProxyNeedsSave || self.model.onboardingProxyStepCompleted == false {
            return self.model.localized(zh: "保存并继续", en: "Save and Continue")
        }
        return self.model.localized(zh: "下一步", en: "Next")
    }
}

private struct OnboardingAccountPoolStep: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        SectionCard(
            title: self.model.onboardingStepTitle(.accountPool),
            subtitle: self.model.localized(
                zh: "至少导入一个账号后，后续代理请求才有上游可以选。",
                en: "Import at least one account so later proxy requests have an upstream to choose from."
            ),
            accessory: StatusPill(
                text: self.model.localized(
                    zh: "已导入 \(self.model.accounts.count) 个账号",
                    en: "\(self.model.accounts.count) account(s) imported"
                ),
                tone: self.model.accounts.isEmpty ? .warning : .success
            )
        ) {
            QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
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

                CompactActionToolbarButton(
                    title: self.model.text(.actionImportCurrent),
                    helpText: self.model.text(.helperQuickActionImportCurrent),
                    symbol: "person.badge.key.fill",
                    tone: .success
                ) {
                    Task { await self.model.importCurrentAuth() }
                }

                CompactActionToolbarButton(
                    title: self.model.text(.actionManualAddAccount),
                    helpText: self.model.text(.helperQuickActionManualAdd),
                    symbol: "plus.circle.fill",
                    tone: .warning
                ) {
                    self.model.presentOnboardingManualAPIKeyDraft()
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

            if let draft = self.model.oauthDraft {
                OAuthFlowPanel(model: self.model, draft: draft)
            }

            if self.model.accounts.isEmpty {
                EmptyStatePanel(
                    title: self.model.localized(zh: "还没有可用账号", en: "No accounts yet"),
                    detail: self.model.localized(
                        zh: "完成任意一种导入方式后，这一步就会自动变成可继续状态。",
                        en: "As soon as any import path succeeds, this step becomes ready to continue."
                    )
                )
            }

            if self.model.onboardingManualAPIKeyDraft != nil {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(self.model.localized(zh: "手动添加兼容 API Key 账号", en: "Add a compatible API key account"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                            Text(self.model.text(.helperManualAPIKeyAccount))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        StatusPill(text: self.model.planText("api_key"), tone: .warning)
                    }

                    ManualAPIKeyAccountForm(
                        model: self.model,
                        draft: Binding(
                            get: { self.model.onboardingManualAPIKeyDraft ?? DesktopAppModel.ManualAPIKeyDraft() },
                            set: { self.model.onboardingManualAPIKeyDraft = $0 }
                        )
                    )

                    HStack(spacing: 10) {
                        Button(self.model.text(.commonCancel)) {
                            self.model.dismissOnboardingManualAPIKeyDraft()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        .disabled(self.model.manualAPIKeyIsSubmitting)

                        Spacer(minLength: 0)

                        Button(self.model.text(.actionSaveAccount)) {
                            Task { await self.model.submitOnboardingManualAPIKeyAccount() }
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                        .disabled(self.model.manualAPIKeyIsSubmitting)
                    }
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.96 : 0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
            }

            DashboardNavigationHintCard(
                title: self.model.localized(zh: "后续管理", en: "Later Management"),
                detail: self.model.localized(
                    zh: "账号池、额度刷新、启停账号和调用顺序，都在 账号页 > 账号池 继续维护。",
                    en: "Account pool management, usage refreshes, enable or disable actions, and routing order all stay under Accounts > Account Pool."
                ),
                actionTitle: self.model.localized(zh: "打开账号页", en: "Open Accounts")
            ) {
                self.model.openAccountsPage()
            }
        }
    }
}

private struct OnboardingProxyStep: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        SectionCard(
            title: self.model.onboardingStepTitle(.outboundProxy),
            subtitle: self.model.localized(
                zh: "这一步只处理最常见的直连和手工代理；订阅代理仍保留在设置页单独管理。",
                en: "This step covers the most common direct and manual proxy paths. Subscription proxying stays in Settings as an advanced path."
            ),
            accessory: StatusPill(
                text: self.model.label(for: self.model.settings.outboundProxyMode),
                tone: self.model.settings.outboundProxyMode == .manual ? .warning : .accent
            )
        ) {
            OnboardingInsetPanel(
                title: self.model.localized(zh: "当前保存状态", en: "Current Saved State"),
                subtitle: self.model.onboardingProxyModeSummary()
            ) {
                if self.model.settings.outboundProxyMode == .subscription {
                    Text(
                        self.model.localized(
                            zh: "你现在已经在使用订阅代理。如果保持这个模式，可以直接继续；如果想切换成直连或手工代理，再用下面的选项保存即可。",
                            en: "You are already using subscription proxying. You can continue with it as-is, or switch to direct/manual proxying by saving one of the choices below."
                        )
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            FormFieldPanel(title: self.model.localized(zh: "选择一种方式继续", en: "Choose how to continue")) {
                Picker(
                    self.model.localized(zh: "选择一种方式继续", en: "Choose how to continue"),
                    selection: Binding(
                        get: { self.model.onboardingProxyDraft.choice },
                        set: { self.model.updateOnboardingProxyChoice($0) }
                    )
                ) {
                    ForEach(DesktopAppModel.OnboardingProxyChoice.allCases, id: \.self) { choice in
                        Text(self.model.onboardingProxyChoiceTitle(choice)).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text(self.model.onboardingProxyChoiceHelp(self.model.onboardingProxyDraft.choice))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            if self.model.onboardingProxyDraft.choice == .manual {
                OnboardingInsetPanel(
                    title: self.model.localized(zh: "手工代理", en: "Manual Proxy"),
                    subtitle: self.model.localized(
                        zh: "请填写你已有的代理地址；用户名和密码只有代理要求认证时才需要填写。",
                        en: "Enter the proxy endpoint you already use. Username and password are only needed when that proxy requires authentication."
                    )
                ) {
                    FormFieldPanel(title: self.model.text(.labelScheme)) {
                        Picker(
                            self.model.text(.labelScheme),
                            selection: self.$model.onboardingProxyDraft.scheme
                        ) {
                            ForEach([OutboundProxyScheme.http, .https, .socks5], id: \.self) { scheme in
                                Text(self.model.label(for: scheme)).tag(scheme)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            FormFieldPanel(title: self.model.text(.labelHost)) {
                                TextField(self.model.text(.labelHost), text: self.$model.onboardingProxyDraft.host)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }

                            FormFieldPanel(title: self.model.text(.labelPublicPort)) {
                                TextField(
                                    self.model.text(.labelPublicPort),
                                    value: self.$model.onboardingProxyDraft.port,
                                    formatter: NumberFormatter()
                                )
                                .textFieldStyle(.plain)
                                .dashboardFieldChrome()
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            FormFieldPanel(title: self.model.text(.labelHost)) {
                                TextField(self.model.text(.labelHost), text: self.$model.onboardingProxyDraft.host)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }

                            FormFieldPanel(title: self.model.text(.labelPublicPort)) {
                                TextField(
                                    self.model.text(.labelPublicPort),
                                    value: self.$model.onboardingProxyDraft.port,
                                    formatter: NumberFormatter()
                                )
                                .textFieldStyle(.plain)
                                .dashboardFieldChrome()
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            FormFieldPanel(title: self.model.text(.labelUsername)) {
                                TextField(self.model.text(.labelUsername), text: self.$model.onboardingProxyDraft.username)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }

                            FormFieldPanel(title: self.model.text(.labelPassword)) {
                                SecureField(self.model.text(.labelPassword), text: self.$model.onboardingProxyDraft.password)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            FormFieldPanel(title: self.model.text(.labelUsername)) {
                                TextField(self.model.text(.labelUsername), text: self.$model.onboardingProxyDraft.username)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }

                            FormFieldPanel(title: self.model.text(.labelPassword)) {
                                SecureField(self.model.text(.labelPassword), text: self.$model.onboardingProxyDraft.password)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }
                        }
                    }
                }
            }

            DashboardNavigationHintCard(
                title: self.model.localized(zh: "后续管理", en: "Later Management"),
                detail: self.model.localized(
                    zh: "以后如果网络策略变化，回到 设置 > 出站代理 调整模式。订阅代理也仍在这个页面进入。",
                    en: "If your network path changes later, return to Settings > Outbound Proxy to switch modes. Subscription proxying also still starts from that page."
                ),
                actionTitle: self.model.localized(zh: "打开出站代理设置", en: "Open Outbound Proxy")
            ) {
                self.model.openSettingsProxyPage()
            }
        }
    }
}

private struct OnboardingClientAccessStep: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            self.codexCard

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    self.claudeCard
                    self.geminiCard
                }

                VStack(alignment: .leading, spacing: 18) {
                    self.claudeCard
                    self.geminiCard
                }
            }

            DashboardNavigationHintCard(
                title: self.model.localized(zh: "后续管理", en: "Later Management"),
                detail: self.model.localized(
                    zh: "以后接入地址、本地 API Key、多 Key 分配和复制动作，都统一在 代理页 > 接入信息 / API Keys 维护。",
                    en: "Later on, endpoints, local API keys, per-tool key allocation, and copy actions all stay under Proxy > Access Info / API Keys."
                ),
                actionTitle: self.model.localized(zh: "打开代理页接入信息", en: "Open Proxy Access")
            ) {
                self.model.openProxyAccessPage()
            }
        }
    }

    private var codexCard: some View {
        SectionCard(
            title: self.model.localized(zh: "Codex", en: "Codex"),
            subtitle: self.model.localized(
                zh: "把下面两个值填到 Codex 的 OpenAI 兼容配置里。地址填写 Base URL，鉴权填写本地 API Key。",
                en: "Fill these two values into Codex's OpenAI-compatible configuration. Use the Base URL for the endpoint and the local API key for authentication."
            )
        ) {
            Text(
                self.model.localized(
                    zh: "如果你以后轮换本地 Key，直接回到代理页复制新的值即可，不需要重新导入账号池。",
                    en: "If you rotate the local key later, just return to Proxy and copy the new value without re-importing the account pool."
                )
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                CodeValueBlock(
                    label: self.model.text(.labelOpenAIBaseURL),
                    value: self.model.openAICompatibleBaseURL,
                    actionTitle: self.model.text(.actionCopyEndpoint)
                ) {
                    self.model.copyEndpoint()
                }

                CodeValueBlock(
                    label: self.model.text(.labelAPIKey),
                    value: self.model.localProxyAPIKeyValue,
                    actionTitle: self.model.text(.actionCopyAPIKey),
                    isSensitive: true
                ) {
                    self.model.copyAPIKey()
                }
            }
        }
    }

    private var claudeCard: some View {
        SectionCard(
            title: self.model.localized(zh: "Claude Code", en: "Claude Code"),
            subtitle: self.model.localized(
                zh: "Claude Code 只需要根地址和这把 Anthropic 路由的本地 API Key；如果希望 Codex 也固定走 Anthropic 账号池，也可以在 OpenAI 兼容 Base URL 上复用它。",
                en: "Claude Code only needs the root endpoint and this Anthropic-routed local API key. You can also reuse it with the OpenAI-compatible base URL when you want Codex pinned to the Anthropic account pool."
            )
        ) {
            Text(
                self.model.localized(
                    zh: "如果你给不同工具分配独立本地 Key，也是在代理页里把默认 Key 换掉或新增多把 Key。",
                    en: "If you assign separate local keys to different tools, that still happens on the Proxy page by changing the primary key or adding more keys."
                )
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                CodeValueBlock(
                    label: self.model.text(.labelAnthropicBaseURL),
                    value: self.model.anthropicBaseURL,
                    actionTitle: self.model.text(.actionCopyEndpoint)
                ) {
                    self.model.copyAnthropicBaseURL()
                }

                CodeValueBlock(
                    label: self.model.text(.labelAnthropicAuthToken),
                    value: self.model.anthropicAccessProxyAPIKeyDisplayValue,
                    actionTitle: self.model.canCopyAnthropicAccessProxyAPIKey ? self.model.text(.actionCopyAPIKey) : nil,
                    isSensitive: true
                ) {
                    self.model.copyAnthropicAccessAPIKey()
                }

                CodeValueBlock(
                    label: self.model.text(.labelClaudeCodeEnv),
                    value: self.model.claudeCodeEnvironmentSnippet,
                    actionTitle: self.model.canCopyClaudeCodeEnvironmentSnippet ? self.model.text(.actionCopyClaudeCodeEnv) : nil
                ) {
                    self.model.copyClaudeCodeEnvironment()
                }
            }
        }
    }

    private var geminiCard: some View {
        SectionCard(
            title: self.model.localized(zh: "Gemini CLI", en: "Gemini CLI"),
            subtitle: self.model.localized(
                zh: "Gemini CLI 通过 Gemini 根地址和同一份本地 API Key 接入。你也可以直接复制现成的环境变量片段。",
                en: "Gemini CLI connects through the Gemini root endpoint and the same local API key. You can also copy the ready-to-use environment snippet."
            )
        ) {
            Text(
                self.model.localized(
                    zh: "如果后面你切换默认本地 Key 或新增独立 Key，Gemini CLI 也只需要重新复制这里的值，不用改账号池。",
                    en: "If you later switch the primary local key or add a dedicated one, Gemini CLI only needs these values recopied. The account pool does not need to change."
                )
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                CodeValueBlock(
                    label: self.model.text(.labelGeminiBaseURL),
                    value: self.model.geminiBaseURL,
                    actionTitle: self.model.text(.actionCopyEndpoint)
                ) {
                    self.model.copyGeminiBaseURL()
                }

                CodeValueBlock(
                    label: self.model.text(.labelAPIKey),
                    value: self.model.localProxyAPIKeyValue,
                    actionTitle: self.model.text(.actionCopyAPIKey),
                    isSensitive: true
                ) {
                    self.model.copyAPIKey()
                }

                CodeValueBlock(
                    label: self.model.text(.labelGeminiCLIEnv),
                    value: self.model.geminiCLIEnvironmentSnippet,
                    actionTitle: self.model.text(.actionCopyGeminiCLIEnv)
                ) {
                    self.model.copyGeminiCLIEnvironment()
                }
            }
        }
    }
}

private struct OnboardingCompletionStep: View {
    @ObservedObject var model: DesktopAppModel

    private let summaryColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14),
    ]

    var body: some View {
        SectionCard(
            title: self.model.onboardingStepTitle(.completion),
            subtitle: self.model.localized(
                zh: "以后只要记住“账号去账号页，接入去代理页，网络去设置页”，日常维护就会很顺。",
                en: "Once you remember that accounts live in Accounts, client access lives in Proxy, and networking lives in Settings, day-to-day maintenance becomes much easier."
            )
        ) {
            LazyVGrid(columns: self.summaryColumns, spacing: 14) {
                MetricTile(
                    label: self.model.localized(zh: "账号池", en: "Accounts"),
                    value: self.model.accounts.isEmpty ? self.model.localized(zh: "未完成", en: "Not Ready") : self.model.localized(zh: "已就绪", en: "Ready"),
                    footnote: self.model.localized(
                        zh: "当前共 \(self.model.accounts.count) 个账号",
                        en: "\(self.model.accounts.count) account(s) available"
                    ),
                    tone: self.model.accounts.isEmpty ? .warning : .success,
                    symbol: "person.2.fill"
                )
                MetricTile(
                    label: self.model.localized(zh: "出站代理", en: "Outbound Proxy"),
                    value: self.model.label(for: self.model.settings.outboundProxyMode),
                    footnote: self.model.onboardingProxyModeSummary(),
                    tone: self.model.settings.outboundProxyMode == .manual ? .warning : .accent,
                    symbol: "network"
                )
                MetricTile(
                    label: self.model.localized(zh: "客户端接入", en: "Client Access"),
                    value: self.model.effectiveServiceRunning ? self.model.localized(zh: "可测试", en: "Testable") : self.model.localized(zh: "可复制", en: "Copy Ready"),
                    footnote: self.model.localized(
                        zh: "地址和本地 Key 已可从代理页继续复制",
                        en: "Endpoints and the local key are ready to copy from Proxy"
                    ),
                    tone: self.model.effectiveServiceRunning ? .success : .accent,
                    symbol: "bolt.horizontal.circle.fill"
                )
            }

            QuickActionWrapLayout(horizontalSpacing: 10, verticalSpacing: 10) {
                Button(self.model.localized(zh: "管理账号池", en: "Manage Accounts")) {
                    self.model.dismissOnboarding()
                    self.model.openAccountsPage()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Button(self.model.localized(zh: "打开接入信息", en: "Open Access Info")) {
                    self.model.dismissOnboarding()
                    self.model.openProxyAccessPage()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Button(self.model.localized(zh: "配置出站代理", en: "Open Outbound Proxy")) {
                    self.model.dismissOnboarding()
                    self.model.openSettingsProxyPage()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Button(self.model.text(.actionTestProxy)) {
                    self.model.dismissOnboarding()
                    self.model.openProxyAccessPage()
                    self.model.openProxyTestConsole()
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            }
        }
    }
}

private struct OnboardingInsetPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                Text(self.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            self.content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}
#endif
