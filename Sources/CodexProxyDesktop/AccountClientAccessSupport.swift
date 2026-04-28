#if os(macOS)
import CodexProxyCore
import SwiftUI

struct AccountClientAccessPresentation: Equatable {
    let statusText: String
    let apiKeyText: String
    let detail: String
    let tone: StatusPill.Tone
}

private enum AccountClientAccessKeyResolution {
    case available(ProxyAPIKeyRecord)
    case restricted
    case missing
}

@MainActor
extension DesktopAppModel {
    func isAnthropicAPICompatibleManualAccount(_ account: AccountSummary) -> Bool {
        account.authMode == .anthropicAPIKey && account.providerPreset == .anthropicAPICompatible
    }

    func anthropicAPICompatibleClientAccessPresentation(for account: AccountSummary) -> AccountClientAccessPresentation? {
        guard self.isAnthropicAPICompatibleManualAccount(account) else { return nil }

        switch self.anthropicAPICompatibleClientAccessKeyResolution(for: account) {
        case .available(let record):
            let keyLabel = self.proxyAPIKeyDisplayLabel(record)
            return AccountClientAccessPresentation(
                statusText: self.localized(zh: "可直接提供给客户端", en: "Ready"),
                apiKeyText: keyLabel,
                detail: self.localized(
                    zh: "这个 Anthropic API 兼容手动账号本身已经同时支持 Anthropic 原生协议和 OpenAI-compatible 下游。当前推荐使用本地 API Key “\(keyLabel)”：Claude Code 使用 Anthropic 根地址，Codex 使用 OpenAI-compatible Base URL，并复用同一把 Key。",
                    en: "This Anthropic API-compatible manual account already supports both the native Anthropic protocol and OpenAI-compatible downstream clients. The recommended local API key is “\(keyLabel)”: Claude Code uses the Anthropic root URL, while Codex uses the OpenAI-compatible base URL with the same key."
                ),
                tone: .success
            )
        case .restricted:
            let restrictedText = self.localized(zh: "账号范围受限", en: "Allowlist Restricted")
            return AccountClientAccessPresentation(
                statusText: restrictedText,
                apiKeyText: restrictedText,
                detail: self.localized(
                    zh: "这个 Anthropic API 兼容手动账号本身可以提供给 Claude Code 和 Codex，但当前启用的 `.anthropic` / `.all` 本地 API Key 都没有允许这个账号。把该账号加入允许范围，或新增一把不受限的 Anthropic 路由本地 Key 后才能使用。",
                    en: "This Anthropic API-compatible manual account can serve Claude Code and Codex, but none of the enabled `.anthropic` / `.all` local API keys currently allow this account. Add the account to an existing allowlist or create an unrestricted Anthropic-routed key before using it."
                ),
                tone: .warning
            )
        case .missing:
            return AccountClientAccessPresentation(
                statusText: self.text(.statusUnavailable),
                apiKeyText: self.text(.statusUnavailable),
                detail: self.localized(
                    zh: "这个 Anthropic API 兼容手动账号本身已经支持 Claude Code 和 Codex，但当前还没有启用的 `.anthropic` / `.all` 本地 API Key。新增或启用一把 Anthropic 路由本地 Key 后，Claude Code 走 Anthropic 根地址，Codex 走 OpenAI-compatible Base URL。",
                    en: "This Anthropic API-compatible manual account already supports Claude Code and Codex, but there is no enabled `.anthropic` / `.all` local API key yet. Enable or create an Anthropic-routed key first, then use the Anthropic root URL for Claude Code and the OpenAI-compatible base URL for Codex."
                ),
                tone: .warning
            )
        }
    }

    private func anthropicAPICompatibleClientAccessKeyResolution(for account: AccountSummary) -> AccountClientAccessKeyResolution {
        var foundRestrictedCandidate = false

        for dataSource in [ProxyDataSource.anthropic, .all] {
            let records = self.configuredProxyAPIKeys.filter { $0.enabled && $0.dataSource == dataSource }
            if records.isEmpty {
                continue
            }
            if let record = records.first(where: { self.proxyAPIKeyAllowsAccount($0, accountKey: account.accountKey) }) {
                return .available(record)
            }
            foundRestrictedCandidate = true
        }

        return foundRestrictedCandidate ? .restricted : .missing
    }

    private func proxyAPIKeyAllowsAccount(_ record: ProxyAPIKeyRecord, accountKey: String) -> Bool {
        let trimmedAccountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountKey.isEmpty else { return true }
        return record.allowedAccountKeys.isEmpty || record.allowedAccountKeys.contains(trimmedAccountKey)
    }
}
#endif
