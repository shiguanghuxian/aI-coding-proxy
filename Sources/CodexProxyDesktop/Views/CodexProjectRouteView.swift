#if os(macOS)
import CodexProxyCore
import SwiftUI

struct CodexProjectRoutesView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    @State private var selectedRuleID: String?

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let selectedRule = self.selectedRule

        VStack(spacing: 0) {
            self.header(palette: palette)

            Divider()

            HSplitView {
                self.sidebar(palette: palette, selectedRule: selectedRule)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

                self.detail(palette: palette, rule: selectedRule)
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .background(ShellBackground())
        .compactOverlayScrollbars()
        .sheet(item: self.$model.codexProjectRouteDraft) { _ in
            CodexProjectRouteEditorSheet(model: self.model)
        }
    }

    private var selectedRule: CodexProjectRouteRule? {
        self.model.selectedCodexProjectRouteRule(id: self.selectedRuleID)
            ?? self.model.codexProjectRouteRules.first
    }

    private func header(palette: AppearancePalette) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.model.codexProjectRoutesWindowTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Text(self.model.codexProjectRoutesWindowSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    await self.model.refreshClientConfigManagerState(showLoading: true, target: .codex, force: true)
                }
            } label: {
                Label(self.model.text(.commonReload), systemImage: "arrow.clockwise")
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))

            Button {
                self.model.presentNewCodexProjectRoute()
            } label: {
                Label(self.model.localized(zh: "添加路由", en: "Add Route"), systemImage: "plus")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            palette.panelRaised.opacity(self.colorScheme == .dark ? 0.86 : 0.94)
        )
    }

    private func notice(palette: AppearancePalette) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 18)
            Text(self.model.localized(
                zh: "这里管理 Codex 与 Claude Code 的项目路由。Codex CLI 通过项目 `.codex/config.toml` 的路由模型标签触发；Codex 桌面版按 Codex Desktop 会话工作目录匹配项目目录，不依赖项目 `model` 是否生效。Claude Code 新路由默认使用 `claude-cp-route-*`，并会同时写入 `ANTHROPIC_CUSTOM_MODEL_OPTION`；命中后代理使用绑定本地 Key。",
                en: "This manages project routes for Codex and Claude Code. Codex CLI is triggered by the route model tag in project `.codex/config.toml`; Codex Desktop matches the Codex Desktop session working directory against the project directory and does not depend on the project `model` taking effect. New Claude Code routes default to `claude-cp-route-*` and also write `ANTHROPIC_CUSTOM_MODEL_OPTION`; matched requests use the bound local key."
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.panelRaised.opacity(0.64))
        )
    }

    private func sidebar(palette: AppearancePalette, selectedRule: CodexProjectRouteRule?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            self.notice(palette: palette)

            if self.model.codexProjectRouteRules.isEmpty {
                self.emptyState(palette: palette)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(self.model.codexProjectRouteRules) { rule in
                            CodexProjectRouteRow(
                                model: self.model,
                                rule: rule,
                                isSelected: selectedRule?.id == rule.id,
                                onSelect: { self.selectedRuleID = rule.id }
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.panel.opacity(self.colorScheme == .dark ? 0.54 : 0.68))
    }

    @ViewBuilder
    private func detail(palette: AppearancePalette, rule: CodexProjectRouteRule?) -> some View {
        if let rule {
            CodexProjectRouteDetailPanel(model: self.model, rule: rule)
                .padding(18)
        } else {
            self.emptyDetailState(palette: palette)
                .padding(18)
        }
    }

    private func emptyState(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.model.localized(zh: "还没有项目路由", en: "No project routes yet"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.localized(
                zh: "添加一个项目目录、路由模型标签和绑定本地 Key。Codex 桌面版会按会话工作目录匹配；CLI 和 Claude Code 可继续写入项目配置触发。",
                en: "Add a project directory, route model tag, and bound local key. Codex Desktop matches by session working directory; CLI and Claude Code can still use project config to trigger the route."
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                self.model.presentNewCodexProjectRoute()
            } label: {
                Label(self.model.localized(zh: "添加项目路由", en: "Add Project Route"), systemImage: "plus")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.panel.opacity(0.76))
        )
    }

    private func emptyDetailState(palette: AppearancePalette) -> some View {
        EmptyStatePanel(
            title: self.model.localized(zh: "选择一个项目路由", en: "Select A Project Route"),
            detail: self.model.localized(
                zh: "左侧列表会显示 Codex 与 Claude Code 的项目路由。选择一条后可查看当前配置和将写入的配置预览。",
                en: "The left list shows Codex and Claude Code project routes. Select one to inspect current and proposed project config."
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.panel.opacity(0.72))
        )
    }
}

private struct CodexProjectRouteRow: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let rule: CodexProjectRouteRule
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Button(action: self.onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.rule.label.isEmpty ? self.rule.routeModel : self.rule.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    StatusPill(
                        text: self.rule.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled),
                        tone: self.rule.enabled ? .success : .neutral,
                        compact: true
                    )
                }

                VStack(alignment: .leading, spacing: 3) {
                    self.metaLine(
                        icon: "app.connected.to.app.below.fill",
                        text: self.model.codexProjectRouteClientLabel(self.rule)
                    )
                    self.metaLine(
                        icon: "arrow.triangle.branch",
                        text: "\(self.rule.routeModel) -> \(self.rule.targetModel)"
                    )
                    self.metaLine(
                        icon: "checkmark.seal",
                        text: self.model.codexProjectRouteConfigStatus(self.rule)
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(self.isSelected ? palette.accentSoft.opacity(0.86) : palette.panel.opacity(self.colorScheme == .dark ? 0.62 : 0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(self.isSelected ? palette.accent.opacity(0.42) : palette.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .interactiveCursor()
    }

    private func metaLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12)
            Text(text.isEmpty ? "-" : text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
    }
}

private struct CodexProjectRouteDetailPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let rule: CodexProjectRouteRule

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let currentFiles = self.model.currentProjectRoutePreviewFiles(for: self.rule)
        let proposedFiles = self.model.proposedProjectRoutePreviewFiles(for: self.rule)

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                self.summary(palette: palette)

                if currentFiles.isEmpty == false {
                    ForEach(currentFiles) { file in
                        CodexProjectRoutePreviewPanel(
                            model: self.model,
                            title: self.model.localized(zh: "当前项目配置", en: "Current Project Config"),
                            subtitle: self.model.projectRouteFileActionSummary(self.rule, file: file),
                            file: file
                        )
                    }
                } else {
                    self.missingPreviewPanel(title: self.model.localized(zh: "当前项目配置", en: "Current Project Config"), palette: palette)
                }

                if proposedFiles.isEmpty == false {
                    ForEach(proposedFiles) { file in
                        CodexProjectRoutePreviewPanel(
                            model: self.model,
                            title: self.model.localized(zh: "将写入项目配置", en: "Proposed Project Config"),
                            subtitle: self.model.localized(
                                zh: "点击写入项目后会把下方内容写入对应配置文件。",
                                en: "Writing the project will store the content below in the matching config file."
                            ),
                            file: file
                        )
                    }
                } else {
                    self.missingPreviewPanel(title: self.model.localized(zh: "将写入项目配置", en: "Proposed Project Config"), palette: palette)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.76 : 0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func summary(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(self.rule.label.isEmpty ? self.rule.routeModel : self.rule.label)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                    Text(self.model.codexProjectRouteClientLabel(self.rule))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                StatusPill(
                    text: self.rule.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled),
                    tone: self.rule.enabled ? .success : .neutral
                )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], alignment: .leading, spacing: 10) {
                self.summaryItem(title: self.model.localized(zh: "客户端类型", en: "Client Type"), value: self.model.codexProjectRouteClientLabel(self.rule), palette: palette)
                self.summaryItem(title: self.model.localized(zh: "项目目录", en: "Project Directory"), value: self.rule.projectPath, palette: palette)
                self.summaryItem(title: self.model.localized(zh: "路由模型标签", en: "Route Model Tag"), value: self.rule.routeModel, palette: palette)
                self.summaryItem(title: self.model.localized(zh: "目标模型", en: "Target Model"), value: self.rule.targetModel, palette: palette)
                self.summaryItem(title: self.model.localized(zh: "绑定本地 Key", en: "Bound Local Key"), value: self.model.codexProjectRouteKeyLabel(self.rule), palette: palette)
                self.summaryItem(title: self.model.localized(zh: "匹配状态", en: "Match Status"), value: self.model.codexProjectRouteConfigStatus(self.rule), palette: palette)
            }

            if self.rule.client == .codex {
                self.codexActivationNotice(palette: palette)
            } else if self.rule.client == .claudeCode {
                self.claudeCodeActivationNotice(palette: palette)
            }

            QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                Button(self.model.localized(zh: "写入项目", en: "Write Project")) {
                    Task { await self.model.applyCodexProjectRouteToProject(self.rule) }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))

                Button(self.model.text(.actionEditAPIKey)) {
                    self.model.presentEditCodexProjectRoute(self.rule)
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Button(self.model.text(.actionClearCodexProjectConfig)) {
                    Task { await self.model.clearCodexProjectRouteFromProject(self.rule) }
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Button(self.model.text(.actionDeleteHost)) {
                    Task { await self.model.deleteCodexProjectRoute(self.rule) }
                }
                .buttonStyle(AppActionButtonStyle(kind: .danger))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelRaised.opacity(0.68))
        )
    }

    private func summaryItem(title: String, value: String, palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.textMuted)
            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.panel.opacity(0.70))
        )
    }

    private func claudeCodeActivationNotice(palette: AppearancePalette) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.top, 1)

            Text(self.model.localized(
                zh: "Claude Code 通常在会话启动时读取 `model`。写入或修改项目路由后，请从该项目目录重新启动一个新的非 resume 会话；请求日志里看到 `model = \(self.rule.routeModel)` 且 `project_route_id` 非空，才表示路由命中。命中后将使用绑定本地 Key 的账号池。",
                en: "Claude Code usually reads `model` when a session starts. After writing or changing this route, start a new non-resumed session from the project directory. The route is active when request logs show `model = \(self.rule.routeModel)` with a non-empty `project_route_id`. Matched requests use the bound local key account pool."
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.accentSoft.opacity(self.colorScheme == .dark ? 0.26 : 0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.accent.opacity(self.colorScheme == .dark ? 0.30 : 0.20), lineWidth: 1)
        )
    }

    private func codexActivationNotice(palette: AppearancePalette) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.top, 1)

            Text(self.model.localized(
                zh: "Codex CLI 仍通过路由模型标签触发；点击写入项目会更新 `.codex/config.toml`。Codex 桌面版不依赖该模型标签是否被桌面版读取，而是根据 Codex Desktop 会话工作目录匹配这里的项目目录；请求日志里看到 `project_route_id` 非空即表示命中。",
                en: "Codex CLI is still triggered by the route model tag; Write Project updates `.codex/config.toml`. Codex Desktop does not depend on the desktop app reading that model tag. It matches this project directory using the Codex Desktop session working directory; a non-empty `project_route_id` in request logs means the route matched."
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.accentSoft.opacity(self.colorScheme == .dark ? 0.26 : 0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.accent.opacity(self.colorScheme == .dark ? 0.30 : 0.20), lineWidth: 1)
        )
    }

    private func missingPreviewPanel(title: String, palette: AppearancePalette) -> some View {
        EmptyStatePanel(
            title: title,
            detail: self.model.localized(zh: "没有可显示的项目配置预览。", en: "No project config preview is available.")
        )
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelRaised.opacity(0.60))
        )
    }
}

private struct CodexProjectRoutePreviewPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let title: String
    let subtitle: String
    let file: ClientConfigFileTextSnapshot

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(self.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                StatusPill(
                    text: self.model.projectRouteFileStatusText(self.file),
                    tone: self.model.projectRouteFileStatusTone(self.file),
                    compact: true
                )
            }

            Text(self.file.path)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)

            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(self.model.projectRoutePreviewDisplayContent(self.file))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 150, maxHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(self.colorScheme == .dark ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelRaised.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

struct CodexProjectRouteEditorSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(self.model.localized(zh: "项目路由", en: "Project Route"))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        Text(self.model.localized(
                            zh: "为一个工作目录绑定本地代理 Key 和目标模型。Codex CLI 用路由模型标签触发；Codex 桌面版按会话工作目录触发；Claude Code 使用项目 settings 的自定义模型选项触发。",
                            en: "Bind one workspace to a local proxy key and target model. Codex CLI uses the route model tag; Codex Desktop uses the session working directory; Claude Code uses the custom model option in project settings."
                        ))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                    }

                    FormFieldPanel(title: self.model.localized(zh: "客户端类型", en: "Client Type")) {
                        Picker(
                            self.model.localized(zh: "客户端类型", en: "Client Type"),
                            selection: Binding(
                                get: { self.model.codexProjectRouteDraft?.client ?? .codex },
                                set: { self.model.updateCodexProjectRouteDraftClient($0) }
                            )
                        ) {
                            Text("Codex").tag(ProjectRouteClient.codex)
                            Text("Claude Code").tag(ProjectRouteClient.claudeCode)
                        }
                        .pickerStyle(.segmented)
                    }

                    if self.model.codexProjectRouteDraft?.client == .claudeCode {
                        FormFieldPanel(
                            title: self.model.localized(zh: "Claude 配置范围", en: "Claude Settings Scope"),
                            footer: self.model.localized(
                                zh: "本机配置优先级更高，适合只在当前电脑生效；共享配置适合提交到项目团队配置。",
                                en: "Local settings have higher priority and only affect this machine; shared settings fit team project config."
                            )
                        ) {
                            Picker(
                                self.model.localized(zh: "Claude 配置范围", en: "Claude Settings Scope"),
                                selection: Binding(
                                    get: { self.model.codexProjectRouteDraft?.claudeSettingsScope ?? .local },
                                    set: { self.model.codexProjectRouteDraft?.claudeSettingsScope = $0 }
                                )
                            ) {
                                Text(self.model.localized(zh: "本机 .claude/settings.local.json", en: "Local .claude/settings.local.json"))
                                    .tag(ClaudeProjectSettingsScope.local)
                                Text(self.model.localized(zh: "共享 .claude/settings.json", en: "Shared .claude/settings.json"))
                                    .tag(ClaudeProjectSettingsScope.shared)
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    FormFieldPanel(title: self.model.text(.labelLabel)) {
                        TextField(self.model.text(.labelLabel), text: Binding(
                            get: { self.model.codexProjectRouteDraft?.label ?? "" },
                            set: { self.model.codexProjectRouteDraft?.label = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                    }

                    FormFieldPanel(title: self.model.localized(zh: "项目目录", en: "Project Directory")) {
                        HStack(spacing: 8) {
                            TextField(self.model.localized(zh: "项目目录", en: "Project Directory"), text: Binding(
                                get: { self.model.codexProjectRouteDraft?.projectPath ?? "" },
                                set: { self.model.codexProjectRouteDraft?.projectPath = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .dashboardFieldChrome()

                            Button(self.model.localized(zh: "选择", en: "Choose")) {
                                self.model.chooseCodexProjectRouteDirectory()
                            }
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        }
                    }

                    FormFieldPanel(
                        title: self.model.localized(zh: "路由模型标签", en: "Route Model Tag"),
                        footer: self.routeModelFooterText
                    ) {
                        HStack(spacing: 8) {
                            TextField(self.routeModelPlaceholder, text: Binding(
                                get: { self.model.codexProjectRouteDraft?.routeModel ?? "" },
                                set: { self.model.codexProjectRouteDraft?.routeModel = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .dashboardFieldChrome()

                            Button(self.model.localized(zh: "生成", en: "Generate")) {
                                self.model.regenerateCodexProjectRouteModel()
                            }
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        }
                    }

                    FormFieldPanel(title: self.model.localized(zh: "目标模型", en: "Target Model")) {
                        TextField(self.targetModelPlaceholder, text: Binding(
                            get: { self.model.codexProjectRouteDraft?.targetModel ?? "" },
                            set: { self.model.codexProjectRouteDraft?.targetModel = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .dashboardFieldChrome()

                        self.targetModelNotice(palette: palette)
                    }

                    FormFieldPanel(title: self.model.localized(zh: "绑定本地 Key", en: "Bound Local Key")) {
                        Picker(
                            self.model.localized(zh: "绑定本地 Key", en: "Bound Local Key"),
                            selection: Binding(
                                get: { self.model.codexProjectRouteDraft?.proxyAPIKeyID ?? "" },
                                set: { self.model.codexProjectRouteDraft?.proxyAPIKeyID = $0 }
                            )
                        ) {
                            ForEach(self.model.codexProjectRouteAvailableProxyKeys) { record in
                                Text(self.model.proxyAPIKeyDisplayLabel(record)).tag(record.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Toggle(
                        self.model.text(.statusEnabled),
                        isOn: Binding(
                            get: { self.model.codexProjectRouteDraft?.enabled ?? true },
                            set: { self.model.codexProjectRouteDraft?.enabled = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack(spacing: 10) {
                Button(self.model.text(.commonCancel)) {
                    self.model.dismissCodexProjectRouteDraft()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Spacer(minLength: 0)

                Button(self.model.text(.actionSaveGeneralSettings)) {
                    Task { await self.model.saveCodexProjectRouteDraft() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(!self.model.canSaveCodexProjectRouteDraft)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
        }
        .frame(minWidth: 540, idealWidth: 600, maxWidth: 680, minHeight: 560, idealHeight: 680, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
        .compactOverlayScrollbars()
    }

    private var routeModelFooterText: String {
        if self.model.codexProjectRouteDraft?.client == .claudeCode {
            return self.model.localized(
                zh: "这个值会写入所选 Claude 项目 settings 的顶层 `model`，并同步写入 `ANTHROPIC_CUSTOM_MODEL_OPTION`，让 Claude Code 接受该自定义路由标签；新建建议使用 `claude-cp-route-*`。请求命中后代理使用绑定本地 Key，再改写为目标模型。",
                en: "This value is written to the selected Claude project settings top-level `model` and `ANTHROPIC_CUSTOM_MODEL_OPTION`, allowing Claude Code to accept the custom route tag; new routes should use `claude-cp-route-*`. After a match, the proxy uses the bound local key, then rewrites it to the target model."
            )
        }
        return self.model.localized(
            zh: "这个值会写入项目 `.codex/config.toml` 的 `model`，用于触发 Codex CLI 路由。Codex 桌面版会按 Codex Desktop 会话工作目录匹配项目目录，不依赖这个模型标签是否被桌面版读取。",
            en: "This value is written to project `.codex/config.toml` `model` to trigger Codex CLI routing. Codex Desktop matches the project directory by Codex Desktop session working directory and does not depend on the desktop app reading this model tag."
        )
    }

    private var routeModelPlaceholder: String {
        self.model.codexProjectRouteDraft?.client == .claudeCode
            ? "claude-cp-route-project"
            : "cp-route-project"
    }

    private var targetModelPlaceholder: String {
        self.model.codexProjectRouteDraft?.client == .claudeCode
            ? "claude-sonnet-4-5"
            : ProxyTranscoder.defaultModel
    }

    private var targetModelHelpText: String {
        self.model.localized(
            zh: "目标模型是代理最终发给上游账号的真实模型名。Codex CLI 和 Claude Code 项目配置里只写“路由模型标签”；Codex 桌面版按会话工作目录触发。请求命中后，代理会按绑定本地 Key 切换账号池，再把 model 改写成这里的目标模型。它不固定要求 `claude-` 前缀：Anthropic 官方账号通常填写 `claude-*`，小米、DeepSeek 等 Anthropic-compatible 网关则填写该供应商实际支持的模型名。",
            en: "The target model is the real model name the proxy sends to the upstream account. Codex CLI and Claude Code project config only store the Route Model Tag; Codex Desktop triggers by session working directory. After a match, the proxy switches to the bound local key account pool, then rewrites `model` to this target model. It does not always require a `claude-` prefix: official Anthropic accounts usually use `claude-*`, while Xiaomi, DeepSeek, or other Anthropic-compatible gateways should use the model name that provider actually supports."
        )
    }

    private func targetModelNotice(palette: AppearancePalette) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.top, 1)

            Text(self.targetModelHelpText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.accentSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.accent.opacity(self.colorScheme == .dark ? 0.32 : 0.22), lineWidth: 1)
        )
    }
}
#endif
