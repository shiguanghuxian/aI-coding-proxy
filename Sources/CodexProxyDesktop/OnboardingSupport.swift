#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation

@MainActor
extension DesktopAppModel {
    func onboardingStepTitle(_ step: OnboardingStep) -> String {
        switch step {
        case .accountPool:
            return self.localized(zh: "账号池", en: "Account Pool")
        case .outboundProxy:
            return self.localized(zh: "出站代理", en: "Outbound Proxy")
        case .clientAccess:
            return self.localized(zh: "客户端接入", en: "Client Setup")
        case .completion:
            return self.localized(zh: "完成使用", en: "Finish")
        }
    }

    func onboardingStepSummary(_ step: OnboardingStep) -> String {
        switch step {
        case .accountPool:
            return self.localized(
                zh: "先把至少一个可用账号加入账号池，后续代理才有上游可以使用。",
                en: "Add at least one usable account so the proxy has an upstream source to route to."
            )
        case .outboundProxy:
            return self.localized(
                zh: "如果当前网络能直连上游，就保持直连；如果必须走代理，再填写你的手工代理地址。",
                en: "Keep direct egress when your network can reach the upstream directly, or enter your manual proxy settings when needed."
            )
        case .clientAccess:
            return self.localized(
                zh: "把这里的地址和 Key 复制给 Codex、Claude Code、Gemini CLI 或其它兼容客户端，后续都在代理页统一维护。",
                en: "Copy these addresses and keys into Codex, Claude Code, Gemini CLI, or another compatible client. Future maintenance stays centralized on the Proxy page."
            )
        case .completion:
            return self.localized(
                zh: "最后确认当前状态，并记住后续去哪个页面维护账号、代理和客户端接入。",
                en: "Review the current state and note which page to return to for accounts, proxying, and client setup."
            )
        }
    }

    func onboardingProxyChoiceTitle(_ choice: OnboardingProxyChoice) -> String {
        switch choice {
        case .direct:
            return self.localized(zh: "我不需要代理", en: "No Proxy Needed")
        case .manual:
            return self.localized(zh: "我要使用手工代理", en: "Use Manual Proxy")
        }
    }

    func onboardingProxyChoiceHelp(_ choice: OnboardingProxyChoice) -> String {
        switch choice {
        case .direct:
            return self.localized(
                zh: "适合当前网络已经能稳定访问上游接口的情况。",
                en: "Best when your current network already reaches the upstream reliably."
            )
        case .manual:
            return self.localized(
                zh: "适合你已经有 HTTP / HTTPS / SOCKS5 代理端口的情况。",
                en: "Best when you already have an HTTP / HTTPS / SOCKS5 proxy endpoint."
            )
        }
    }

    func onboardingProxyModeSummary() -> String {
        switch self.settings.outboundProxyMode {
        case .disabled:
            return self.localized(
                zh: "当前保存的是直连模式，daemon 会直接访问上游。",
                en: "The current saved mode is direct egress, so the daemon connects to upstreams directly."
            )
        case .manual:
            let host = self.settings.outboundProxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.isEmpty == false, self.settings.outboundProxy.port > 0 else {
                return self.localized(
                    zh: "当前保存的是手工代理模式，但代理地址还不完整。",
                    en: "The current saved mode is manual proxy, but the proxy address is still incomplete."
                )
            }
            return self.localized(
                zh: "当前保存的是手工代理模式：\(host):\(self.settings.outboundProxy.port)。",
                en: "The current saved mode is manual proxy: \(host):\(self.settings.outboundProxy.port)."
            )
        case .subscription:
            return self.localized(
                zh: "当前正在使用订阅代理。这个高级模式仍在 设置 > 出站代理 单独维护。",
                en: "The current setup uses subscription proxying. This advanced mode is still maintained separately in Settings > Outbound Proxy."
            )
        }
    }

    func makeOnboardingProxyDraft(from settings: AppConfig) -> OnboardingProxyDraft {
        let choice: OnboardingProxyChoice = settings.outboundProxyMode == .manual ? .manual : .direct
        return OnboardingProxyDraft(
            choice: choice,
            scheme: settings.outboundProxy.scheme == .disabled ? .http : settings.outboundProxy.scheme,
            host: settings.outboundProxy.host,
            port: settings.outboundProxy.port,
            username: settings.outboundProxy.username,
            password: settings.outboundProxy.password
        )
    }

    func startOnboarding(step: OnboardingStep = .accountPool) {
        self.onboardingStep = step
        self.onboardingManualAPIKeyDraft = nil
        self.onboardingProxyDraft = self.makeOnboardingProxyDraft(from: self.settings)
        self.isOnboardingPresented = true
        if self.onboardingWindowController == nil {
            self.onboardingWindowController = self.onboardingWindowFactory(self)
        }
        self.onboardingWindowController?.showWindow()
    }

    func dismissOnboarding() {
        self.isOnboardingPresented = false
        self.onboardingManualAPIKeyDraft = nil
        self.onboardingWindowController?.closeWindow()
    }

    func onboardingWindowDidClose() {
        guard self.isOnboardingPresented || self.onboardingManualAPIKeyDraft != nil else { return }
        self.isOnboardingPresented = false
        self.onboardingManualAPIKeyDraft = nil
    }

    func goToOnboardingStep(_ step: OnboardingStep) {
        self.onboardingStep = step
    }

    func advanceOnboardingStep() {
        guard let next = OnboardingStep(rawValue: self.onboardingStep.rawValue + 1) else { return }
        self.onboardingStep = next
    }

    func retreatOnboardingStep() {
        guard let previous = OnboardingStep(rawValue: self.onboardingStep.rawValue - 1) else { return }
        self.onboardingStep = previous
    }

    func presentOnboardingAfterHelpDismissIfNeeded() {
        guard self.shouldAutoPresentOnboardingAfterHelpDismiss else { return }
        self.updatePreferences(showSuccessNotice: false) { preferences in
            preferences.hasAutoPresentedOnboardingAfterHelp = true
        }
        self.startOnboarding()
    }

    func presentOnboardingManualAPIKeyDraft() {
        self.onboardingManualAPIKeyDraft = ManualAPIKeyDraft()
    }

    func dismissOnboardingManualAPIKeyDraft() {
        guard self.manualAPIKeyIsSubmitting == false else { return }
        self.onboardingManualAPIKeyDraft = nil
    }

    func updateOnboardingProxyChoice(_ choice: OnboardingProxyChoice) {
        self.onboardingProxyDraft.choice = choice
        if choice == .manual, self.onboardingProxyDraft.scheme == .disabled {
            self.onboardingProxyDraft.scheme = .http
        }
    }

    private func validateOnboardingManualProxyDraft() -> Bool {
        guard self.onboardingProxyDraft.choice == .manual else { return true }

        let host = self.onboardingProxyDraft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.localized(zh: "请先填写代理地址", en: "Enter a proxy host first"),
                detail: self.localized(zh: "手工代理至少需要填写 host 和 port。", en: "Manual proxy mode needs at least a host and port.")
            )
            return false
        }

        guard self.onboardingProxyDraft.port > 0 else {
            self.publishBanner(
                .warning,
                title: self.localized(zh: "请先填写代理端口", en: "Enter a proxy port first"),
                detail: self.localized(zh: "手工代理至少需要填写 host 和 port。", en: "Manual proxy mode needs at least a host and port.")
            )
            return false
        }

        return true
    }

    @discardableResult
    func saveOnboardingProxyConfiguration() async -> Bool {
        guard self.validateOnboardingManualProxyDraft() else { return false }

        switch self.onboardingProxyDraft.choice {
        case .direct:
            self.settings.outboundProxyMode = .disabled
            self.settings.outboundProxy.scheme = .disabled
        case .manual:
            self.settings.outboundProxyMode = .manual
            self.settings.outboundProxy.scheme = self.onboardingProxyDraft.scheme == .disabled ? .http : self.onboardingProxyDraft.scheme
            self.settings.outboundProxy.host = self.onboardingProxyDraft.host
            self.settings.outboundProxy.port = self.onboardingProxyDraft.port
            self.settings.outboundProxy.username = self.onboardingProxyDraft.username
            self.settings.outboundProxy.password = self.onboardingProxyDraft.password
        }

        let saved = await self.saveSettings(noticeContext: .saveSettings)
        if saved {
            self.onboardingProxyDraft = self.makeOnboardingProxyDraft(from: self.settings)
        }
        return saved
    }

    func continueOnboardingFromProxyStep() async {
        if self.onboardingProxyNeedsSave || self.onboardingProxyStepCompleted == false {
            guard await self.saveOnboardingProxyConfiguration() else { return }
        }
        self.onboardingStep = .clientAccess
    }

    func openAccountsPage() {
        self.openDashboard(.accounts)
    }

    func openProxyAccessPage() {
        self.selectedProxyWorkspaceTab = .access
        self.openDashboard(.proxy)
    }

    func openSettingsAppearancePage() {
        self.selectedSettingsTab = .appearance
        self.openDashboard(.settings)
    }

    func openSettingsProxyPage() {
        self.selectedSettingsTab = .proxy
        self.openDashboard(.settings)
    }

    func openSettingsServicePage() {
        self.selectedSettingsTab = .service
        self.openDashboard(.settings)
    }

    func openDashboard(_ page: Page) {
        guard self.canOpenPage(page) else { return }
        if self.preferences.interfaceMode == .minimal {
            self.switchInterfaceMode(target: .full, destination: .page(page))
            self.activateMainWindow()
            return
        }
        self.selectedPage = page
        self.activateMainWindow()
    }
}
#endif
