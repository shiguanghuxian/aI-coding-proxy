#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation

struct CodexProjectRouteDraft: Identifiable, Equatable {
    let id = UUID()
    var editingRuleID: String?
    var client: ProjectRouteClient = .codex
    var claudeSettingsScope: ClaudeProjectSettingsScope = .local
    var label = ""
    var projectPath = ""
    var routeModel = ""
    var targetModel = ProxyTranscoder.defaultModel
    var proxyAPIKeyID = ""
    var enabled = true
    var createdAt = Helpers.now()

    var isEditing: Bool {
        self.editingRuleID != nil
    }

    init(rule: CodexProjectRouteRule? = nil, defaultProxyAPIKeyID: String = "") {
        if let rule {
            self.editingRuleID = rule.id
            self.client = rule.client
            self.claudeSettingsScope = rule.claudeSettingsScope
            self.label = rule.label
            self.projectPath = rule.projectPath
            self.routeModel = rule.routeModel
            self.targetModel = rule.targetModel
            self.proxyAPIKeyID = rule.proxyAPIKeyID
            self.enabled = rule.enabled
            self.createdAt = rule.createdAt
        } else {
            self.proxyAPIKeyID = defaultProxyAPIKeyID
        }
    }

    func routeRule(existingID: String? = nil) -> CodexProjectRouteRule {
        CodexProjectRouteRule(
            id: existingID ?? self.editingRuleID ?? UUID().uuidString,
            client: self.client,
            claudeSettingsScope: self.claudeSettingsScope,
            label: self.label,
            projectPath: self.projectPath,
            routeModel: self.routeModel,
            targetModel: self.targetModel,
            proxyAPIKeyID: self.proxyAPIKeyID,
            enabled: self.enabled,
            createdAt: self.createdAt
        )
    }
}

@MainActor
extension DesktopAppModel {
    var codexProjectRouteRules: [CodexProjectRouteRule] {
        self.settings.codexProjectRoutes
    }

    var codexProjectRouteAvailableProxyKeys: [ProxyAPIKeyRecord] {
        self.clientConfigManagerAvailableProxyAPIKeys
    }

    var canSaveCodexProjectRouteDraft: Bool {
        guard let draft = self.codexProjectRouteDraft else { return false }
        return draft.projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && draft.routeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && draft.targetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && draft.proxyAPIKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && self.isBusy == false
    }

    func presentNewCodexProjectRoute() {
        let defaultKeyID = self.codexProjectRouteAvailableProxyKeys.first?.id ?? ""
        self.codexProjectRouteDraft = CodexProjectRouteDraft(defaultProxyAPIKeyID: defaultKeyID)
    }

    func presentEditCodexProjectRoute(_ rule: CodexProjectRouteRule) {
        self.codexProjectRouteDraft = CodexProjectRouteDraft(rule: rule)
    }

    func dismissCodexProjectRouteDraft() {
        self.codexProjectRouteDraft = nil
    }

    func chooseCodexProjectRouteDirectory() {
        guard var draft = self.codexProjectRouteDraft else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = self.localized(zh: "选择项目目录", en: "Choose Project")
        if panel.runModal() == .OK, let url = panel.url {
            draft.projectPath = url.path
            if draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.label = url.lastPathComponent
            }
            if draft.routeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.routeModel = CodexProjectRouteRule.generatedRouteModel(
                    label: draft.label,
                    projectPath: draft.projectPath,
                    client: draft.client
                )
            }
            self.codexProjectRouteDraft = draft
        }
    }

    func regenerateCodexProjectRouteModel() {
        guard var draft = self.codexProjectRouteDraft else { return }
        draft.routeModel = CodexProjectRouteRule.generatedRouteModel(
            label: draft.label,
            projectPath: draft.projectPath,
            client: draft.client
        )
        self.codexProjectRouteDraft = draft
    }

    func saveCodexProjectRouteDraft() async {
        guard let draft = self.codexProjectRouteDraft else { return }
        let rule = draft.routeRule(existingID: draft.editingRuleID)
        let isCreating = draft.editingRuleID == nil
        guard rule.isComplete, rule.projectPath.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.localized(zh: "项目路由不完整", en: "Project Route Incomplete"),
                detail: self.localized(zh: "请填写项目目录、路由模型、目标模型，并选择本地 Key。", en: "Fill in the project path, route model, target model, and local key.")
            )
            return
        }

        var updatedSettings = self.settings
        if let editingID = draft.editingRuleID,
           let index = updatedSettings.codexProjectRoutes.firstIndex(where: { $0.id == editingID })
        {
            updatedSettings.codexProjectRoutes[index] = rule
        } else {
            updatedSettings.codexProjectRoutes.append(rule)
        }
        updatedSettings = updatedSettings.normalizedModelRoutingConfig()

        let saved = await self.persistSettingsUpdate(
            updatedSettings,
            noticeContext: .saveSettings,
            successTitle: self.localized(zh: "项目路由已保存", en: "Project Route Saved"),
            successDetail: rule.label.isEmpty ? rule.routeModel : rule.label
        )
        guard saved else {
            return
        }

        if isCreating {
            let didWriteProjectConfig = await self.writeProjectRouteConfiguration(
                rule,
                successTitle: self.localized(
                    zh: "项目路由已保存并写入项目配置",
                    en: "Project Route Saved And Written"
                ),
                successDetail: self.projectRouteWriteDetail(rule)
            )
            if didWriteProjectConfig {
                self.codexProjectRouteDraft = nil
            }
        } else {
            self.codexProjectRouteDraft = nil
        }
    }

    func deleteCodexProjectRoute(_ rule: CodexProjectRouteRule) async {
        var updatedSettings = self.settings
        updatedSettings.codexProjectRoutes.removeAll { $0.id == rule.id }
        updatedSettings = updatedSettings.normalizedModelRoutingConfig()
        _ = await self.persistSettingsUpdate(
            updatedSettings,
            noticeContext: .saveSettings,
            successTitle: self.localized(zh: "项目路由已删除", en: "Project Route Deleted"),
            successDetail: rule.label.isEmpty ? rule.routeModel : rule.label
        )
    }

    func applyCodexProjectRouteToProject(_ rule: CodexProjectRouteRule) async {
        _ = await self.writeProjectRouteConfiguration(
            rule,
            successTitle: self.localized(zh: "已写入项目配置", en: "Project Config Written"),
            successDetail: self.projectRouteWriteDetail(rule)
        )
    }

    @discardableResult
    private func writeProjectRouteConfiguration(
        _ rule: CodexProjectRouteRule,
        successTitle: String,
        successDetail: String
    ) async -> Bool {
        do {
            _ = try self.clientConfigFileService.applyProjectRouteConfiguration(rule)
            self.publishBanner(
                .success,
                title: successTitle,
                detail: successDetail
            )
            await self.refreshClientConfigManagerState(target: self.clientConfigTarget(for: rule), force: true)
            await self.loadClientConfigManagerBackupsIfNeeded(target: self.clientConfigTarget(for: rule), force: true)
            return true
        } catch {
            self.present(error: error, context: .saveSettings)
            return false
        }
    }

    func clearCodexProjectRouteFromProject(_ rule: CodexProjectRouteRule) async {
        do {
            _ = try self.clientConfigFileService.clearProjectRouteConfiguration(rule)
            self.publishBanner(
                .success,
                title: self.localized(zh: "已清空项目路由", en: "Project Route Cleared"),
                detail: self.projectRouteClearDetail(rule)
            )
            await self.refreshClientConfigManagerState(target: self.clientConfigTarget(for: rule), force: true)
            await self.loadClientConfigManagerBackupsIfNeeded(target: self.clientConfigTarget(for: rule), force: true)
        } catch {
            self.present(error: error, context: .saveSettings)
        }
    }

    func codexProjectRouteKeyLabel(_ rule: CodexProjectRouteRule) -> String {
        guard let key = self.settings.proxyAPIKeys.first(where: { $0.id == rule.proxyAPIKeyID }) else {
            return self.localized(zh: "本地 Key 不存在", en: "Local Key Missing")
        }
        return self.proxyAPIKeyDisplayLabel(key)
    }

    func codexProjectRouteConfigStatus(_ rule: CodexProjectRouteRule) -> String {
        let preview = self.clientConfigFileService.previewCurrentProjectRoute(rule)
        guard let file = preview.files.first, file.exists else {
            return self.localized(zh: "项目配置未写入", en: "Project config not written")
        }
        if self.projectRouteConfigMatches(content: file.content, rule: rule) {
            return self.localized(zh: "项目配置已匹配", en: "Project config matches")
        }
        return self.localized(zh: "项目配置与路由不一致", en: "Project config differs")
    }

    func codexProjectRouteClientLabel(_ rule: CodexProjectRouteRule) -> String {
        switch rule.client {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code · \(self.claudeProjectSettingsScopeLabel(rule.claudeSettingsScope))"
        }
    }

    func claudeProjectSettingsScopeLabel(_ scope: ClaudeProjectSettingsScope) -> String {
        switch scope {
        case .local:
            return ".claude/settings.local.json"
        case .shared:
            return ".claude/settings.json"
        }
    }

    func updateCodexProjectRouteDraftClient(_ client: ProjectRouteClient) {
        guard var draft = self.codexProjectRouteDraft else { return }
        draft.client = client
        if client == .claudeCode, draft.targetModel == ProxyTranscoder.defaultModel {
            draft.targetModel = "claude-sonnet-4-5"
        } else if client == .codex, draft.targetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.targetModel = ProxyTranscoder.defaultModel
        }
        self.codexProjectRouteDraft = draft
    }

    func selectedCodexProjectRouteRule(id: String?) -> CodexProjectRouteRule? {
        guard let id else { return nil }
        return self.settings.codexProjectRoutes.first(where: { $0.id == id })
    }

    func currentProjectRoutePreviewFile(for rule: CodexProjectRouteRule) -> ClientConfigFileTextSnapshot? {
        self.clientConfigFileService.previewCurrentProjectRoute(rule).files.first
    }

    func proposedProjectRoutePreviewFile(for rule: CodexProjectRouteRule) -> ClientConfigFileTextSnapshot? {
        self.clientConfigFileService.previewProposedProjectRoute(rule).files.first
    }

    func projectRoutePreviewDisplayContent(_ file: ClientConfigFileTextSnapshot) -> String {
        self.clientConfigManagerDisplayContent(for: file)
    }

    func projectRouteFileStatusText(_ file: ClientConfigFileTextSnapshot) -> String {
        if let error = file.errorMessage, error.isEmpty == false {
            return self.localized(zh: "读取失败", en: "Read Failed")
        }
        return file.exists
            ? self.localized(zh: "已存在", en: "Exists")
            : self.localized(zh: "不存在", en: "Missing")
    }

    func projectRouteFileStatusTone(_ file: ClientConfigFileTextSnapshot) -> StatusPill.Tone {
        if let error = file.errorMessage, error.isEmpty == false {
            return .danger
        }
        return file.exists ? .success : .warning
    }

    func projectRouteFileActionSummary(_ rule: CodexProjectRouteRule, file: ClientConfigFileTextSnapshot) -> String {
        if let error = file.errorMessage, error.isEmpty == false {
            return self.localized(
                zh: "无法读取项目配置，可尝试重新写入。",
                en: "Project config cannot be read; try writing again."
            )
        }
        if file.exists == false {
            return self.localized(
                zh: "当前项目目录还没有配置文件，点击写入即可创建。",
                en: "No project config exists yet; write to create it."
            )
        }
        if self.projectRouteConfigMatches(content: file.content, rule: rule) {
            return self.localized(
                zh: "项目配置与当前路由一致。",
                en: "Project config matches this route."
            )
        }
        return self.localized(
            zh: "项目配置与当前路由不一致，建议重新写入。",
            en: "Project config differs from this route; consider rewriting."
        )
    }

    private func clientConfigTarget(for rule: CodexProjectRouteRule) -> ClientConfigTarget {
        rule.client == .codex ? .codex : .claudeCode
    }

    private func projectRouteConfigMatches(content: String, rule: CodexProjectRouteRule) -> Bool {
        switch rule.client {
        case .codex:
            return content.contains("model = \"\(rule.routeModel)\"")
        case .claudeCode:
            guard let data = content.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return false
            }
            let env = object["env"] as? [String: Any] ?? [:]
            return (object["model"] as? String) == rule.routeModel
                && (env["ANTHROPIC_CUSTOM_MODEL_OPTION"] as? String) == rule.routeModel
        }
    }

    private func projectRouteWriteDetail(_ rule: CodexProjectRouteRule) -> String {
        switch rule.client {
        case .codex:
            return self.localized(
                zh: "已把 \(rule.routeModel) 写入 \(rule.projectPath)/.codex/config.toml。",
                en: "Wrote \(rule.routeModel) to \(rule.projectPath)/.codex/config.toml."
            )
        case .claudeCode:
            return self.localized(
                zh: "已把 \(rule.routeModel) 和 Claude Code 自定义模型选项写入 \(rule.projectPath)/\(self.claudeProjectSettingsScopeLabel(rule.claudeSettingsScope))。命中后将使用绑定本地 Key；请重新启动非 resume 的 Claude Code 会话。",
                en: "Wrote \(rule.routeModel) and the Claude Code custom model option to \(rule.projectPath)/\(self.claudeProjectSettingsScopeLabel(rule.claudeSettingsScope)). Matched requests use the bound local key; start a new non-resumed Claude Code session."
            )
        }
    }

    private func projectRouteClearDetail(_ rule: CodexProjectRouteRule) -> String {
        switch rule.client {
        case .codex:
            return self.localized(
                zh: "已移除 \(rule.projectPath)/.codex/config.toml 中的顶层 model 配置。",
                en: "Removed the top-level model setting from \(rule.projectPath)/.codex/config.toml."
            )
        case .claudeCode:
            return self.localized(
                zh: "已移除 \(rule.projectPath)/\(self.claudeProjectSettingsScopeLabel(rule.claudeSettingsScope)) 中的顶层 model 和 Claude Code 自定义模型选项。",
                en: "Removed the top-level model setting and Claude Code custom model option from \(rule.projectPath)/\(self.claudeProjectSettingsScopeLabel(rule.claudeSettingsScope))."
            )
        }
    }
}
#endif
