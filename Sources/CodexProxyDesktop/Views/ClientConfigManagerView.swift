#if os(macOS)
import AppKit
import CodexProxyCore
import SwiftUI

struct ClientConfigManagerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        GeometryReader { proxy in
            let layout = ClientConfigManagerLayout(size: proxy.size)
            let palette = AppearanceStore.palette(for: self.colorScheme)
            let renderState = self.model.clientConfigManagerRenderState

            ZStack(alignment: .topTrailing) {
                self.content(layout: layout, renderState: renderState)

                if renderState.isBackupDrawerPresented {
                    Color.black
                        .opacity(self.colorScheme == .dark ? 0.28 : 0.16)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.model.dismissClientConfigBackupDrawer()
                        }
                        .transition(.opacity)

                    ClientConfigBackupDrawer(
                        model: self.model,
                        layout: layout,
                        target: renderState.target,
                        mode: renderState.backupDrawerMode,
                        detail: renderState.backupDetail,
                        visibleBackups: renderState.visibleBackups,
                        previewRevealsSecrets: renderState.previewRevealsSecrets,
                        width: renderState.backupDrawerMode == .detail
                            ? layout.detailDrawerWidth
                            : layout.listDrawerWidth
                    )
                    .padding(.top, layout.outerPadding)
                    .padding(.trailing, layout.outerPadding)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .shadow(
                        color: palette.shadow.opacity(self.colorScheme == .dark ? 0.32 : 0.12),
                        radius: 20,
                        x: -8,
                        y: 12
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ShellBackground())
            .animation(.spring(response: 0.26, dampingFraction: 0.88), value: self.model.isClientConfigBackupDrawerPresented)
        }
        .compactOverlayScrollbars()
        .confirmationDialog(
            self.restoreConfirmationTitle,
            isPresented: self.$model.isClientConfigManagerRestoreConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(self.restoreConfirmationButtonTitle, role: .destructive) {
                Task { await self.model.confirmClientConfigBackupRestore() }
            }
            Button(self.model.text(.commonCancel), role: .cancel) {
                self.model.cancelClientConfigBackupRestore()
            }
        } message: {
            Text(self.restoreConfirmationMessage)
        }
    }

    private func content(
        layout: ClientConfigManagerLayout,
        renderState: ClientConfigManagerRenderState
    ) -> some View {
        self.regularContent(layout: layout, renderState: renderState)
    }

    private func regularContent(
        layout: ClientConfigManagerLayout,
        renderState: ClientConfigManagerRenderState
    ) -> some View {
        HStack(alignment: .top, spacing: layout.columnSpacing) {
            self.sidebar(layout: layout, renderState: renderState)
                .frame(width: layout.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            self.workspace(layout: layout, renderState: renderState)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, layout.outerPadding)
        .padding(.vertical, layout.outerPadding)
        .frame(width: layout.viewportWidth, height: layout.viewportHeight, alignment: .topLeading)
        .clipped()
    }

    private func sidebar(
        layout: ClientConfigManagerLayout,
        renderState: ClientConfigManagerRenderState
    ) -> some View {
        ClientConfigPlanSidebar(
            model: self.model,
            layout: layout,
            inspection: renderState.inspection,
            selectionStatusText: self.selectionStatusText,
            selectionStatusTone: self.selectionStatusTone
        )
    }

    private func workspace(
        layout: ClientConfigManagerLayout,
        renderState: ClientConfigManagerRenderState
    ) -> some View {
        ClientConfigWorkspace(
            model: self.model,
            layout: layout,
            renderState: renderState,
            missingFileText: self.model.localized(zh: "这个文件当前不存在。", en: "This file does not exist yet.")
        )
    }

    private var inspection: ClientConfigInspection {
        self.model.clientConfigManagerInspection(for: self.model.clientConfigManagerTarget)
    }

    private var selectionStatusText: String {
        if self.model.clientConfigManagerApplyUnavailableReason != nil {
            return self.model.localized(zh: "需要处理", en: "Needs Attention")
        }
        if self.isSelectedKeyAlreadyApplied {
            return self.model.localized(zh: "已是当前选择", en: "Already Selected")
        }
        return self.model.localized(zh: "准备写入", en: "Ready To Write")
    }

    private var selectionStatusTone: StatusPill.Tone {
        if self.model.clientConfigManagerApplyUnavailableReason != nil {
            return .warning
        }
        return self.isSelectedKeyAlreadyApplied ? .success : .accent
    }

    private var isSelectedKeyAlreadyApplied: Bool {
        guard let selectedID = self.model.clientConfigManagerSelectedProxyAPIKeyRecord()?.id else { return false }
        return self.inspection.currentKeyKind == .matched
            && self.inspection.matchedProxyAPIKeyID == selectedID
    }

    private var restoreConfirmationTitle: String {
        self.model.localized(zh: "确认还原备份", en: "Confirm Restore")
    }

    private var restoreConfirmationButtonTitle: String {
        self.model.localized(zh: "还原备份", en: "Restore Backup")
    }

    private var restoreConfirmationMessage: String {
        guard let backup = self.model.clientConfigManagerPendingRestoreBackup else {
            return self.model.localized(
                zh: "这会覆盖对应客户端的受管配置文件。",
                en: "This will overwrite the managed config files for the backup's client."
            )
        }
        return self.model.localized(
            zh: "将把 \(self.model.clientConfigManagerTitle(for: backup.target)) 还原到 \(self.model.clientConfigManagerBackupSummary(for: backup))。还原前会自动再创建一份当前状态备份。",
            en: "This will restore \(self.model.clientConfigManagerTitle(for: backup.target)) to \(self.model.clientConfigManagerBackupSummary(for: backup)). A backup of the current state will be created first."
        )
    }
}

private struct ClientConfigManagerLayout {
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    let isTightHeight: Bool
    let isCompactHeight: Bool
    let isNarrowWidth: Bool
    let isCompactWidth: Bool
    let usesCompactWorkspaceHeader: Bool
    let outerPadding: CGFloat
    let panelPadding: CGFloat
    let innerPanelPadding: CGFloat
    let columnSpacing: CGFloat
    let sidebarWidth: CGFloat
    let fileListWidth: CGFloat
    let backupFileListWidth: CGFloat
    let editorMinHeight: CGFloat
    let backupEditorMinHeight: CGFloat
    let sidebarApplyFooterReservedHeight: CGFloat
    let listDrawerWidth: CGFloat
    let detailDrawerWidth: CGFloat

    init(size: CGSize) {
        let tightHeight = size.height < 560
        let compactHeight = size.height < 700
        let narrowWidth = size.width < 900
        let compactWidth = size.width < 1180
        let compact = compactWidth || compactHeight || narrowWidth
        let dense = narrowWidth || tightHeight

        self.viewportWidth = max(size.width, 0)
        self.viewportHeight = max(size.height, 0)
        self.isTightHeight = tightHeight
        self.isCompactHeight = compactHeight
        self.isNarrowWidth = narrowWidth
        self.isCompactWidth = compactWidth
        self.usesCompactWorkspaceHeader = compactWidth || compactHeight || size.width < 1220
        self.outerPadding = dense ? 10 : (compact ? 14 : 22)
        self.panelPadding = dense ? 11 : (compact ? 14 : 18)
        self.innerPanelPadding = dense ? 9 : (compact ? 12 : 14)
        self.columnSpacing = dense ? 9 : (compact ? 12 : 16)
        self.sidebarWidth = narrowWidth ? 260 : (compactWidth ? 292 : 340)
        self.fileListWidth = narrowWidth ? 205 : (compactWidth ? 235 : 280)
        self.backupFileListWidth = narrowWidth ? 220 : (compact ? 245 : 270)
        self.editorMinHeight = tightHeight ? 150 : (compactHeight ? 220 : 390)
        self.backupEditorMinHeight = tightHeight ? 190 : (compact ? 260 : 440)
        self.sidebarApplyFooterReservedHeight = tightHeight ? 66 : (compactHeight ? 72 : 82)
        self.listDrawerWidth = min(max(size.width * 0.36, 380), min(520, max(size.width - 120, 380)))
        self.detailDrawerWidth = min(max(size.width * 0.62, 620), min(920, max(size.width - 96, 620)))
    }
}

private struct ClientConfigPlanSidebar: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let layout: ClientConfigManagerLayout
    let inspection: ClientConfigInspection
    let selectionStatusText: String
    let selectionStatusTone: StatusPill.Tone

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ZStack(alignment: .bottom) {
            self.scrollableContent(palette: palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            self.fixedApplyButtonArea(palette: palette)
                .frame(maxWidth: .infinity, alignment: .bottom)
        }
        .padding(self.layout.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.985))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func scrollableContent(palette: AppearancePalette) -> some View {
        ScrollView {
            self.sidebarContent(palette: palette)
                .padding(.trailing, 2)
                .padding(.bottom, self.layout.sidebarApplyFooterReservedHeight)
        }
        .scrollIndicators(.hidden)
    }

    private func sidebarContent(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: self.layout.isTightHeight ? 8 : (self.layout.isCompactHeight ? 10 : 14)) {
            self.header(palette: palette)

            ClientConfigStepGuide(
                steps: self.stepGuideItems,
                palette: palette,
                compact: self.layout.isCompactWidth || self.layout.isCompactHeight
            )

            VStack(alignment: .leading, spacing: self.layout.isTightHeight ? 8 : (self.layout.isCompactHeight ? 10 : 12)) {
                ClientConfigSidebarPanel(title: self.model.localized(zh: "目标客户端", en: "Target Client")) {
                    ClientConfigTargetSelector(
                        selection: self.model.clientConfigManagerTarget,
                        targets: ClientConfigTarget.allCases,
                        title: { self.model.clientConfigManagerTitle(for: $0) },
                        subtitle: self.targetSubtitle(for:),
                        onSelect: self.selectTarget
                    )
                }

                ClientConfigSidebarPanel(title: self.model.localized(zh: "要写入的本地 Key", en: "Local Key To Write")) {
                    if self.model.clientConfigManagerAvailableProxyAPIKeys.isEmpty {
                        ClientConfigInlineNotice(
                            title: self.model.localized(zh: "没有启用的本地 Key", en: "No Enabled Local Key"),
                            detail: self.model.localized(
                                zh: "先到代理页启用至少一把本地 API Key。",
                                en: "Enable at least one local API key on the Proxy page first."
                            ),
                            tone: .warning
                        )
                    } else {
                        ClientConfigKeySelector(
                            model: self.model,
                            records: self.model.clientConfigManagerAvailableProxyAPIKeys,
                            selectedRecord: self.model.clientConfigManagerSelectedProxyAPIKeyRecord(),
                            unavailableText: self.model.text(.statusUnavailable),
                            accessibilityLabel: self.model.localized(zh: "选择要写入的本地 Key", en: "Choose the local key to write"),
                            helpText: self.model.localized(zh: "选择要写入 Codex、Claude Code 或 Gemini 配置文件的本地代理 Key。", en: "Choose the local proxy key to write into Codex, Claude Code, or Gemini config files."),
                            title: { self.model.proxyAPIKeyDisplayLabel($0) },
                            detail: { "\(self.model.proxyAPIKeyMaskedValue($0)) · \(self.model.label(for: $0.dataSource))" },
                            onSelect: { self.model.clientConfigManagerSelectProxyAPIKey($0) }
                        )
                    }
                }

                ClientConfigSidebarPanel(title: self.model.localized(zh: "即将写入", en: "Write Preview")) {
                    VStack(alignment: .leading, spacing: 9) {
                        ClientConfigPlanMetaRow(
                            label: self.model.localized(zh: "客户端", en: "Client"),
                            value: self.model.clientConfigManagerTitle(for: self.model.clientConfigManagerTarget)
                        )
                        ClientConfigPlanMetaRow(
                            label: self.model.localized(zh: "本地 Key", en: "Local Key"),
                            value: self.model.clientConfigManagerSelectedProxyAPIKeyRecord().map {
                                self.model.proxyAPIKeyDisplayLabel($0)
                            } ?? self.model.text(.statusUnavailable)
                        )
                        ClientConfigPlanMetaRow(
                            label: self.model.localized(zh: "代理地址", en: "Endpoint"),
                            value: self.model.clientConfigManagerEndpointText()
                        )
                        ClientConfigPlanMetaRow(
                            label: self.model.localized(zh: "写入摘要", en: "Write Summary"),
                            value: self.model.clientConfigManagerChangeSummaryText
                        )
                        ClientConfigPlanMetaRow(
                            label: self.model.localized(zh: "当前 Key", en: "Current Key"),
                            value: self.model.clientConfigManagerCurrentKeyStatusText(for: self.inspection)
                        )
                    }
                }

                self.statusNotice
            }
        }
    }

    private func header(palette: AppearancePalette) -> some View {
        let compact = self.layout.isCompactWidth || self.layout.isCompactHeight

        return VStack(alignment: .leading, spacing: self.layout.isTightHeight ? 4 : 6) {
            HStack(alignment: .center, spacing: compact ? 6 : 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(self.model.clientConfigManagerWindowTitle)
                    .font(.system(size: compact ? 17 : 19, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
            }

            Text(self.model.localized(
                zh: "选择 Codex、Claude Code 或 Gemini，再选择要写入的本地代理 Key。确认右侧预览后点击应用。",
                en: "Choose Codex, Claude Code, or Gemini, select the local proxy key to write, then review the preview and apply."
            ))
            .font(.system(size: compact ? 10 : 11, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fixedApplyButtonArea(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: self.layout.isTightHeight ? 7 : 10) {
            Rectangle()
                .fill(palette.divider.opacity(self.colorScheme == .dark ? 0.72 : 0.58))
                .frame(height: 1)
                .padding(.bottom, self.layout.isTightHeight ? 0 : 2)

            self.applyButton
        }
        .padding(.top, self.layout.isTightHeight ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.94))
        .overlay {
            ClientConfigAccessibilityFrameMarker(identifier: "client-config-apply-footer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("client-config-apply-footer")
    }

    private var applyButton: some View {
        Button {
            Task { await self.model.applyClientConfigManagerSelection() }
        } label: {
            Text(self.model.clientConfigManagerApplyButtonTitle())
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(AppActionButtonStyle(kind: .primary))
        .frame(maxWidth: .infinity)
        .disabled(!self.model.clientConfigManagerCanApplyCurrentSelection)
        .overlay {
            ClientConfigAccessibilityFrameMarker(
                identifier: "client-config-apply-button",
                label: self.model.clientConfigManagerApplyButtonTitle()
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(self.model.clientConfigManagerApplyButtonTitle())
        .accessibilityIdentifier("client-config-apply-button")
    }

    private var statusNotice: some View {
        Group {
            if let issueText = self.blockingNoticeText {
                ClientConfigInlineNotice(
                    title: self.model.localized(zh: "需要处理", en: "Needs Attention"),
                    detail: issueText,
                    tone: .warning
                )
            } else if self.inspection.errorMessage?.isEmpty == false {
                ClientConfigInlineNotice(
                    title: self.model.localized(zh: "配置读取失败", en: "Failed To Read Configuration"),
                    detail: self.inspection.errorMessage ?? "",
                    tone: .danger
                )
            } else {
                ClientConfigInlineNotice(
                    title: self.selectionStatusText,
                    detail: self.model.clientConfigManagerCurrentSelectionStatusText,
                    tone: self.selectionStatusTone
                )
            }
        }
    }

    private func selectTarget(_ target: ClientConfigTarget) {
        self.model.clientConfigManagerSelectTarget(target)
    }

    private func targetSubtitle(for target: ClientConfigTarget) -> String {
        switch target {
        case .codex:
            return self.model.localized(zh: "写入 Codex 的 OpenAI 兼容配置", en: "Write OpenAI-compatible Codex config")
        case .claudeCode:
            return self.model.localized(zh: "写入 Claude Code 的 Anthropic 配置", en: "Write Anthropic config for Claude Code")
        case .gemini:
            return self.model.localized(zh: "写入 Gemini CLI/API 配置", en: "Write Gemini CLI/API config")
        }
    }

    private var stepGuideItems: [ClientConfigStepGuideItem] {
        [
            ClientConfigStepGuideItem(
                number: 1,
                title: self.model.localized(zh: "选择客户端", en: "Choose Client"),
                detail: self.model.localized(zh: "Codex、Claude Code 或 Gemini", en: "Codex, Claude Code, or Gemini"),
                tone: .success
            ),
            ClientConfigStepGuideItem(
                number: 2,
                title: self.model.localized(zh: "选择本地 Key", en: "Choose Local Key"),
                detail: self.model.localized(zh: "选择要写入客户端的代理 Key", en: "Select the proxy key to write"),
                tone: self.model.clientConfigManagerAvailableProxyAPIKeys.isEmpty ? .warning : .success
            ),
            ClientConfigStepGuideItem(
                number: 3,
                title: self.model.localized(zh: "预览后应用", en: "Review And Apply"),
                detail: self.model.localized(zh: "右侧确认，只读预览后写入", en: "Confirm the read-only preview first"),
                tone: self.selectionStatusToneForGuide
            ),
        ]
    }

    private var selectionStatusToneForGuide: StatusPill.Tone {
        if self.model.clientConfigManagerAvailableProxyAPIKeys.isEmpty {
            return .neutral
        }
        if self.selectionStatusTone == .success {
            return .success
        }
        return self.model.clientConfigManagerCanApplyCurrentSelection ? .accent : .warning
    }

    private var blockingNoticeText: String? {
        if let reason = self.model.clientConfigManagerApplyUnavailableReason {
            return reason
        }
        switch self.model.clientConfigManagerOperation {
        case .idle:
            return nil
        case .loading:
            return self.model.localized(zh: "正在重新读取客户端配置。", en: "Reading client configuration.")
        case .applying:
            return self.model.localized(zh: "正在写入配置文件并创建备份。", en: "Writing config files and creating a backup.")
        case .restoring:
            return self.model.localized(zh: "正在从备份还原配置文件。", en: "Restoring config files from backup.")
        }
    }
}

private struct ClientConfigAccessibilityFrameMarker: NSViewRepresentable {
    let identifier: String
    var label: String?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        self.updateIdentifier(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        self.updateIdentifier(on: nsView)
    }

    private func updateIdentifier(on view: NSView) {
        view.identifier = NSUserInterfaceItemIdentifier(self.identifier)
        view.setAccessibilityIdentifier(self.identifier)
        view.setAccessibilityLabel(self.label)
        view.setAccessibilityElement(false)
    }
}

private struct ClientConfigStepGuideItem: Identifiable {
    let number: Int
    let title: String
    let detail: String
    let tone: StatusPill.Tone

    var id: Int { self.number }
}

private struct ClientConfigStepGuide: View {
    let steps: [ClientConfigStepGuideItem]
    let palette: AppearancePalette
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: self.compact ? 6 : 8) {
            ForEach(self.steps) { step in
                HStack(alignment: .top, spacing: self.compact ? 7 : 9) {
                    Text("\(step.number)")
                        .font(.system(size: self.compact ? 9 : 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(self.stepForeground(tone: step.tone))
                        .frame(width: self.compact ? 18 : 20, height: self.compact ? 18 : 20)
                        .background(
                            Circle()
                                .fill(self.stepBackground(tone: step.tone))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: self.compact ? 10 : 11, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        Text(step.detail)
                            .font(.system(size: self.compact ? 9 : 10, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(self.compact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.panelRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func stepBackground(tone: StatusPill.Tone) -> Color {
        switch tone {
        case .accent:
            return palette.accentSoft
        case .success:
            return palette.successSoft
        case .warning:
            return palette.warningSoft
        case .danger:
            return palette.dangerSoft
        case .neutral:
            return palette.panelMuted
        }
    }

    private func stepForeground(tone: StatusPill.Tone) -> Color {
        switch tone {
        case .accent:
            return palette.accent
        case .success:
            return palette.success
        case .warning:
            return palette.warning
        case .danger:
            return palette.danger
        case .neutral:
            return palette.textSecondary
        }
    }
}

private struct ClientConfigTargetSelector: View {
    @Environment(\.colorScheme) private var colorScheme

    let selection: ClientConfigTarget
    let targets: [ClientConfigTarget]
    let title: (ClientConfigTarget) -> String
    let subtitle: (ClientConfigTarget) -> String
    let onSelect: (ClientConfigTarget) -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(self.targets) { target in
                let isSelected = target == self.selection

                Button {
                    self.onSelect(target)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(self.iconBackground(palette: palette, isSelected: isSelected))
                            Image(systemName: self.systemImage(for: target))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(self.iconForeground(palette: palette, isSelected: isSelected))
                        }
                        .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(self.title(target))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(1)
                            Text(self.subtitle(target))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isSelected ? palette.accent : palette.textMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(isSelected ? palette.accentSoft.opacity(0.86) : palette.panel.opacity(0.54))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(isSelected ? palette.accent.opacity(0.48) : palette.border, lineWidth: isSelected ? 1.35 : 1)
                    )
                }
                .buttonStyle(.plain)
                .interactiveCursor()
                .accessibilityLabel(self.title(target))
                .help(self.subtitle(target))
            }
        }
    }

    private func systemImage(for target: ClientConfigTarget) -> String {
        switch target {
        case .codex:
            return "terminal.fill"
        case .claudeCode:
            return "sparkles"
        case .gemini:
            return "diamond.fill"
        }
    }

    private func iconBackground(palette: AppearancePalette, isSelected: Bool) -> Color {
        isSelected ? palette.accent.opacity(0.16) : palette.panelMuted.opacity(0.72)
    }

    private func iconForeground(palette: AppearancePalette, isSelected: Bool) -> Color {
        isSelected ? palette.accent : palette.textSecondary
    }
}

private struct ClientConfigKeySelector: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let records: [ProxyAPIKeyRecord]
    let selectedRecord: ProxyAPIKeyRecord?
    let unavailableText: String
    let accessibilityLabel: String
    let helpText: String
    let title: (ProxyAPIKeyRecord) -> String
    let detail: (ProxyAPIKeyRecord) -> String
    let onSelect: (String) -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let resolvedRecord = self.selectedRecord ?? self.records.first

        Menu {
            ForEach(self.records) { record in
                Button {
                    self.onSelect(record.id)
                } label: {
                    Label(
                        self.menuTitle(for: record),
                        systemImage: record.id == resolvedRecord?.id ? "checkmark.circle.fill" : "key"
                    )
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.successSoft.opacity(0.76))
                    Image(systemName: "key.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.success)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(resolvedRecord.map { self.title($0) } ?? self.unavailableText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(resolvedRecord.map { self.detail($0) } ?? self.unavailableText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.58 : 0.64))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(palette.success.opacity(0.32), lineWidth: 1.2)
            )
        }
        .menuStyle(.borderlessButton)
        .interactiveCursor()
        .accessibilityLabel(self.accessibilityLabel)
        .help(self.helpText)
    }

    private func menuTitle(for record: ProxyAPIKeyRecord) -> String {
        "\(self.title(record)) · \(self.detail(record))"
    }
}

private struct ClientConfigWorkspace: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let layout: ClientConfigManagerLayout
    let renderState: ClientConfigManagerRenderState
    let missingFileText: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let selectedPath = self.renderState.selectedPreviewFilePresentation?.file.path

        VStack(alignment: .leading, spacing: self.layout.isTightHeight ? 10 : (self.layout.isCompactHeight ? 12 : 14)) {
            self.header(palette: palette)

            HStack(alignment: .top, spacing: self.layout.innerPanelPadding) {
                ClientConfigManagedFileList(
                    model: self.model,
                    panelPadding: self.layout.innerPanelPadding,
                    presentations: self.renderState.filePresentations,
                    selectedPath: selectedPath,
                    changeSummaryText: self.renderState.changeSummaryText
                )
                    .frame(width: self.layout.fileListWidth)

                ClientConfigEditorPanel(
                    model: self.model,
                    panelPadding: self.layout.innerPanelPadding,
                    editorMinHeight: self.layout.editorMinHeight,
                    selectedPresentation: self.renderState.selectedPreviewFilePresentation,
                    displayText: self.renderState.selectedDisplayText,
                    textIdentity: self.renderState.selectedTextIdentity,
                    missingFileText: self.missingFileText
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(self.layout.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func header(palette: AppearancePalette) -> some View {
        let changedFileCount = self.renderState.changedFileCount
        let currentKeyText = self.model.clientConfigManagerCurrentKeyStatusText(for: self.renderState.inspection)

        return VStack(alignment: .leading, spacing: self.layout.isTightHeight ? 9 : 12) {
            if self.layout.usesCompactWorkspaceHeader {
                VStack(alignment: .leading, spacing: self.layout.isTightHeight ? 8 : 10) {
                    self.headerTitleBlock(palette: palette)

                    self.headerActions
                        .frame(maxWidth: .infinity, alignment: .leading)

                    StatusPill(
                        text: self.operationText,
                        tone: self.operationTone,
                        compact: true
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    self.headerTitleBlock(palette: palette)

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        self.headerActions
                        StatusPill(
                            text: self.operationText,
                            tone: self.operationTone,
                            compact: true
                        )
                    }
                }
            }

            LazyVGrid(columns: self.metricColumns, alignment: .leading, spacing: self.layout.isCompactWidth ? 8 : 10) {
                ClientConfigMiniMetric(
                    title: self.model.localized(zh: "受管文件", en: "Managed Files"),
                    value: "\(self.renderState.inspection.files.filter(\.exists).count) / \(self.renderState.inspection.files.count)",
                    tone: .neutral,
                    symbol: "doc.on.doc.fill"
                )
                ClientConfigMiniMetric(
                    title: self.model.localized(zh: "将修改", en: "Changes"),
                    value: "\(changedFileCount)",
                    tone: changedFileCount == 0 ? .neutral : .accent,
                    symbol: "square.and.pencil"
                )
                ClientConfigMiniMetric(
                    title: self.model.localized(zh: "当前 Key", en: "Current Key"),
                    value: currentKeyText,
                    tone: self.currentKeyTone,
                    symbol: "key.fill"
                )
            }
        }
    }

    private func headerTitleBlock(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.model.clientConfigManagerTitle(for: self.renderState.target))
                .font(.system(size: self.layout.usesCompactWorkspaceHeader ? 20 : 24, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.localized(
                zh: "右侧内容是只读预览；只有点击左侧写入按钮，才会创建备份并写入磁盘。",
                en: "This is a read-only preview; files are backed up and written only when you use the write button on the left."
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerActions: some View {
        QuickActionWrapLayout(
            horizontalSpacing: self.layout.isCompactWidth ? 5 : 7,
            verticalSpacing: self.layout.isCompactWidth ? 5 : 7
        ) {
            self.headerActionButton(
                title: self.model.text(.actionOpenCodexProjectRoutes),
                systemImage: "arrow.triangle.branch",
                action: self.model.openCodexProjectRoutesWindow
            )
            self.headerActionButton(
                title: self.model.clientConfigManagerRevealFilesButtonTitle,
                systemImage: "folder",
                action: self.model.revealClientConfigManagedFiles
            )
            self.headerActionButton(
                title: self.model.clientConfigManagerViewBackupsButtonTitle,
                systemImage: "clock.arrow.circlepath",
                action: self.model.presentClientConfigBackupDrawer
            )
            self.headerActionButton(
                title: self.model.clientConfigManagerRefreshStatusButtonTitle,
                systemImage: "arrow.clockwise"
            ) {
                Task { await self.model.refreshClientConfigManagerState(showLoading: true) }
            }
        }
    }

    private func headerActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: self.layout.isCompactWidth ? 4 : 5) {
                Image(systemName: systemImage)
                    .font(.system(size: self.layout.isCompactWidth ? 10 : 11, weight: .semibold))
                    .frame(width: self.layout.isCompactWidth ? 13 : 14)
                Text(title)
                    .font(.system(size: self.layout.isCompactWidth ? 10 : 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(minHeight: self.layout.isCompactWidth ? 24 : 26)
        }
        .buttonStyle(ClientConfigHeaderActionButtonStyle())
        .disabled(self.model.isClientConfigManagerBusy)
        .help(title)
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: self.layout.isCompactWidth ? 128 : 150, maximum: 220), spacing: self.layout.isCompactWidth ? 8 : 10, alignment: .top),
        ]
    }

    private var operationText: String {
        switch self.renderState.operation {
        case .idle:
            return self.model.localized(zh: "就绪", en: "Ready")
        case .loading:
            return self.model.localized(zh: "读取中", en: "Loading")
        case .applying(let target):
            return self.model.localized(
                zh: "正在应用 \(self.model.clientConfigManagerTitle(for: target))",
                en: "Applying \(self.model.clientConfigManagerTitle(for: target))"
            )
        case .restoring:
            return self.model.localized(zh: "正在还原", en: "Restoring")
        }
    }

    private var operationTone: StatusPill.Tone {
        switch self.renderState.operation {
        case .idle:
            return .success
        case .loading:
            return .accent
        case .applying, .restoring:
            return .warning
        }
    }

    private var currentKeyTone: StatusPill.Tone {
        if self.renderState.inspection.errorMessage?.isEmpty == false {
            return .danger
        }
        switch self.renderState.inspection.currentKeyKind {
        case .missing:
            return .warning
        case .matched:
            return .success
        case .external:
            return .neutral
        }
    }
}

private struct ClientConfigHeaderActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let pressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .lineLimit(1)
            .foregroundStyle(self.isEnabled ? palette.textPrimary : palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.panel.opacity(pressed ? 0.74 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
            .shadow(color: palette.shadow.opacity(pressed ? 0.04 : 0.12), radius: 3, x: 0, y: 1)
            .scaleEffect(pressed ? 0.99 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.88)
            .animation(.easeOut(duration: 0.14), value: pressed)
            .interactiveCursor(isEnabled: self.isEnabled)
    }
}

private struct ClientConfigManagedFileList: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let panelPadding: CGFloat
    let presentations: [ClientConfigPreviewFilePresentation]
    let selectedPath: String?
    let changeSummaryText: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(self.model.localized(zh: "将写入的文件", en: "Files To Write").uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(palette.textMuted)
                    Spacer(minLength: 0)
                    Text(self.changeSummaryText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(palette.accentSoft.opacity(0.72))
                        )
                }

                Text(self.model.localized(
                    zh: "点击文件查看当前内容和写入后的预览。",
                    en: "Select a file to compare current and proposed content."
                ))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if self.presentations.isEmpty {
                EmptyStatePanel(
                    title: self.model.localized(zh: "没有可显示文件", en: "No Files"),
                    detail: self.model.localized(zh: "当前目标没有返回可预览的配置文件。", en: "The selected target has no previewable config files.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(self.presentations) { presentation in
                            let tone = self.model.clientConfigManagerFileChangeKindTone(presentation.changeKind)
                            ClientConfigManagedFileRow(
                                presentation: presentation,
                                isSelected: self.selectedPath == presentation.file.path,
                                changeText: self.model.clientConfigManagerFileChangeKindText(presentation.changeKind),
                                changeTone: tone,
                                changeSymbol: self.model.clientConfigManagerFileChangeKindSymbol(presentation.changeKind),
                                onSelect: {
                                    self.model.clientConfigManagerSelectPreviewFile(presentation.file.path)
                                }
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(self.panelPadding)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.82 : 0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct ClientConfigManagedFileRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: ClientConfigPreviewFilePresentation
    let isSelected: Bool
    let changeText: String
    let changeTone: StatusPill.Tone
    let changeSymbol: String
    let onSelect: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Button {
            self.onSelect()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.iconBackground(palette: palette, tone: self.changeTone))
                    Image(systemName: self.changeSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(self.iconForeground(palette: palette, tone: self.changeTone))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 5) {
                    Text(URL(fileURLWithPath: self.presentation.file.path).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(self.presentation.file.path)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                    StatusPill(
                        text: self.changeText,
                        tone: self.changeTone,
                        compact: true
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(self.isSelected ? palette.accentSoft.opacity(0.92) : palette.panelRaised.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(self.isSelected ? palette.accent.opacity(0.55) : palette.border, lineWidth: self.isSelected ? 1.4 : 1)
            )
        }
        .buttonStyle(.plain)
        .interactiveCursor()
    }

    private func iconBackground(palette: AppearancePalette, tone: StatusPill.Tone) -> Color {
        switch tone {
        case .accent:
            return palette.accentSoft
        case .success:
            return palette.successSoft
        case .warning:
            return palette.warningSoft
        case .danger:
            return palette.dangerSoft
        case .neutral:
            return palette.panelMuted
        }
    }

    private func iconForeground(palette: AppearancePalette, tone: StatusPill.Tone) -> Color {
        switch tone {
        case .accent:
            return palette.accent
        case .success:
            return palette.success
        case .warning:
            return palette.warning
        case .danger:
            return palette.danger
        case .neutral:
            return palette.textSecondary
        }
    }
}

private struct ClientConfigEditorPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let panelPadding: CGFloat
    let editorMinHeight: CGFloat
    let selectedPresentation: ClientConfigPreviewFilePresentation?
    let displayText: String?
    let textIdentity: String?
    let missingFileText: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            self.toolbar(palette: palette)

            if let presentation = self.selectedPresentation,
               let displayText = self.displayText,
               let textIdentity = self.textIdentity
            {
                self.fileHeader(presentation: presentation, palette: palette)

                ClientConfigCodeEditorContent(
                    file: presentation.file,
                    displayText: displayText,
                    textIdentity: textIdentity,
                    missingFileText: self.missingFileText
                )
                .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(minHeight: self.editorMinHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                EmptyStatePanel(
                    title: self.model.localized(zh: "没有可预览的配置文件", en: "No Configuration Files"),
                    detail: self.model.localized(zh: "当前目标没有返回可查看的配置内容。", en: "The selected target did not return previewable configuration content.")
                )
            }
        }
        .padding(self.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.82 : 0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func toolbar(palette: AppearancePalette) -> some View {
        QuickActionWrapLayout(horizontalSpacing: 10, verticalSpacing: 8) {
            self.previewModePicker
            self.revealSecretsButton
        }
    }

    private var previewModePicker: some View {
        Picker("", selection: Binding(
            get: { self.model.clientConfigManagerPreviewMode },
            set: { self.model.clientConfigManagerPreviewMode = $0 }
        )) {
            ForEach(ClientConfigPreviewMode.allCases) { mode in
                Text(self.model.clientConfigManagerPreviewModeText(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
    }

    private var revealSecretsButton: some View {
        Button(self.model.clientConfigManagerPreviewRevealsSecrets
            ? self.model.localized(zh: "隐藏密钥", en: "Hide Secrets")
            : self.model.localized(zh: "显示密钥", en: "Show Secrets"))
        {
            self.model.clientConfigManagerPreviewRevealsSecrets.toggle()
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
    }

    private func fileHeader(
        presentation: ClientConfigPreviewFilePresentation,
        palette: AppearancePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: presentation.file.path).lastPathComponent)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(presentation.file.path)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }

            QuickActionWrapLayout(horizontalSpacing: 7, verticalSpacing: 7) {
                StatusPill(
                    text: self.model.clientConfigManagerFileChangeKindText(presentation.changeKind),
                    tone: self.model.clientConfigManagerFileChangeKindTone(presentation.changeKind),
                    compact: true
                )
                StatusPill(
                    text: self.model.clientConfigManagerPreviewFileStatusText(presentation.file),
                    tone: self.model.clientConfigManagerPreviewFileStatusTone(presentation.file),
                    compact: true
                )
                StatusPill(
                    text: presentation.file.language.rawValue.uppercased(),
                    tone: .neutral,
                    compact: true
                )
            }
        }
    }

}

private struct ClientConfigCodeEditorContent: View, @MainActor Equatable {
    let file: ClientConfigFileTextSnapshot
    let displayText: String
    let textIdentity: String
    let missingFileText: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.textIdentity == rhs.textIdentity && lhs.displayText == rhs.displayText
    }

    var body: some View {
        ClientConfigCodeEditorView(
            text: self.resolvedDisplayText,
            textIdentity: self.textIdentity
        )
    }

    private var resolvedDisplayText: String {
        if self.file.exists == false, self.file.content.isEmpty, self.file.errorMessage == nil {
            return self.missingFileText
        }
        return self.displayText
    }
}

private struct ClientConfigBackupDrawer: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let layout: ClientConfigManagerLayout
    let target: ClientConfigTarget
    let mode: ClientConfigBackupDrawerMode
    let detail: ClientConfigBackupDetail?
    let visibleBackups: [ClientConfigBackupRecord]
    let previewRevealsSecrets: Bool
    let width: CGFloat

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            switch self.mode {
            case .list:
                self.listContent(palette: palette)
            case .detail:
                if let detail {
                    ClientConfigBackupDetailDrawerContent(
                        model: self.model,
                        panelPadding: self.layout.innerPanelPadding,
                        fileListWidth: self.layout.backupFileListWidth,
                        editorMinHeight: self.layout.backupEditorMinHeight,
                        detail: detail,
                        previewRevealsSecrets: self.previewRevealsSecrets
                    )
                } else {
                    self.listContent(palette: palette)
                }
            }
        }
        .padding(self.layout.panelPadding)
        .frame(width: self.width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panel.opacity(self.colorScheme == .dark ? 0.98 : 0.97),
                            palette.panelRaised.opacity(self.colorScheme == .dark ? 0.96 : 0.94),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func listContent(palette: AppearancePalette) -> some View {
        Group {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.model.localized(zh: "可回退备份", en: "Restorable Backups"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.summaryText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 0)

                self.closeButton
            }

            Button(self.model.localized(zh: "打开备份目录", en: "Open Backup Folder")) {
                self.model.revealClientConfigBackupDirectory()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))

            if self.visibleBackups.isEmpty {
                Spacer(minLength: 0)
                EmptyStatePanel(
                    title: self.model.localized(zh: "还没有备份记录", en: "No Backups Yet"),
                    detail: self.model.localized(
                        zh: "首次应用配置后，这里会显示当前客户端的备份历史。",
                        en: "Backups for the selected client appear here after the first configuration write."
                    )
                )
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(self.visibleBackups) { backup in
                            ClientConfigBackupDrawerRow(model: self.model, backup: backup)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var closeButton: some View {
        Button {
            self.model.dismissClientConfigBackupDrawer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
    }

    private var summaryText: String {
        self.model.localized(
            zh: "\(self.model.clientConfigManagerTitle(for: self.target)) · \(self.visibleBackups.count) 份备份",
            en: "\(self.model.clientConfigManagerTitle(for: self.target)) · \(self.visibleBackups.count) backups"
        )
    }
}

private struct ClientConfigBackupDrawerRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let backup: ClientConfigBackupRecord

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.model.clientConfigManagerBackupSummary(for: self.backup))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(self.model.localized(
                        zh: "\(self.backup.files.count) 个文件 · \(self.model.clientConfigManagerTitle(for: self.backup.target))",
                        en: "\(self.backup.files.count) files · \(self.model.clientConfigManagerTitle(for: self.backup.target))"
                    ))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button(self.model.localized(zh: "查看", en: "View")) {
                    self.model.openClientConfigBackupViewer(self.backup)
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                .disabled(self.model.isClientConfigManagerBusy)

                Button(self.model.localized(zh: "还原", en: "Restore")) {
                    self.model.requestClientConfigBackupRestore(self.backup)
                }
                .buttonStyle(AppActionButtonStyle(kind: .danger))
                .disabled(self.model.isClientConfigManagerBusy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelRaised.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct ClientConfigBackupDetailDrawerContent: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: DesktopAppModel
    let panelPadding: CGFloat
    let fileListWidth: CGFloat
    let editorMinHeight: CGFloat
    let detail: ClientConfigBackupDetail
    let previewRevealsSecrets: Bool

    @State private var selectedPath: String?

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            self.header(palette: palette)

            HStack(alignment: .top, spacing: 14) {
                self.fileList(palette: palette)
                    .frame(width: self.fileListWidth)

                self.editorPane(palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            self.ensureSelection()
        }
        .onChange(of: self.detail.id) { _, _ in
            self.selectedPath = self.detail.files.first?.path
        }
    }

    private var selectedFile: ClientConfigFileTextSnapshot? {
        if let selectedPath,
           let matched = self.detail.files.first(where: { $0.path == selectedPath })
        {
            return matched
        }
        return self.detail.files.first
    }

    private func header(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    self.model.returnToClientConfigBackupList()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.model.localized(zh: "备份内容", en: "Backup Detail"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.model.clientConfigManagerBackupSummary(for: self.detail.record))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    self.model.dismissClientConfigBackupDrawer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
            }

            QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                self.metadataPills
                self.headerActions
            }
        }
    }

    private var metadataPills: some View {
        Group {
            StatusPill(
                text: self.model.clientConfigManagerTitle(for: self.detail.record.target),
                tone: .accent,
                compact: true
            )
            StatusPill(
                text: self.model.clientConfigManagerBackupReasonText(self.detail.record.reason),
                tone: self.detail.record.reason == .beforeApply ? .neutral : .warning,
                compact: true
            )
            StatusPill(
                text: self.model.localized(
                    zh: "\(self.detail.files.count) 个文件",
                    en: "\(self.detail.files.count) files"
                ),
                tone: .neutral,
                compact: true
            )
            if let label = self.detail.record.proxyAPIKeyLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty
            {
                StatusPill(text: label, tone: .neutral, compact: true)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button(self.model.clientConfigManagerPreviewRevealsSecrets
                ? self.model.localized(zh: "隐藏密钥", en: "Hide Secrets")
                : self.model.localized(zh: "显示密钥", en: "Show Secrets"))
            {
                self.model.clientConfigManagerPreviewRevealsSecrets.toggle()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))

            Button(self.model.localized(zh: "还原", en: "Restore")) {
                self.model.requestClientConfigBackupRestore(self.detail.record)
            }
            .buttonStyle(AppActionButtonStyle(kind: .danger))
            .disabled(self.model.isClientConfigManagerBusy)
        }
    }

    private func fileList(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.model.localized(zh: "备份文件", en: "Backup Files").uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            if self.detail.files.isEmpty {
                EmptyStatePanel(
                    title: self.model.localized(zh: "没有文件", en: "No Files"),
                    detail: self.model.localized(zh: "这个备份没有记录任何受管配置文件。", en: "This backup does not contain managed configuration files.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(self.detail.files) { file in
                            self.fileButton(file: file, palette: palette)
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .padding(self.panelPadding)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.82 : 0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func fileButton(file: ClientConfigFileTextSnapshot, palette: AppearancePalette) -> some View {
        Button {
            self.selectedPath = file.path
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: file.exists ? "doc.text" : "doc.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(self.model.clientConfigManagerPreviewFileStatusText(file))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(self.selectedPath == file.path ? palette.accentSoft.opacity(0.72) : palette.panelRaised.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(self.selectedPath == file.path ? palette.accent.opacity(0.28) : palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .interactiveCursor()
    }

    @ViewBuilder
    private func editorPane(palette: AppearancePalette) -> some View {
        if let selectedFile {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(URL(fileURLWithPath: selectedFile.path).lastPathComponent)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(selectedFile.path)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    QuickActionWrapLayout(horizontalSpacing: 7, verticalSpacing: 7) {
                        StatusPill(
                            text: self.model.clientConfigManagerPreviewFileStatusText(selectedFile),
                            tone: self.model.clientConfigManagerPreviewFileStatusTone(selectedFile),
                            compact: true
                        )
                        StatusPill(
                            text: selectedFile.language.rawValue.uppercased(),
                            tone: .neutral,
                            compact: true
                        )
                    }
                }

                ClientConfigCodeEditorContent(
                    file: selectedFile,
                    displayText: self.model.clientConfigManagerDisplayContent(for: selectedFile),
                    textIdentity: self.backupTextIdentity(for: selectedFile),
                    missingFileText: self.model.localized(zh: "文件不存在于该备份。", en: "This file did not exist in this backup.")
                )
                .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(minHeight: self.editorMinHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
            .padding(self.panelPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.82 : 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
        } else {
            EmptyStatePanel(
                title: self.model.localized(zh: "没有可查看的文件", en: "No Files To View"),
                detail: self.model.localized(zh: "这个备份没有记录任何受管配置文件。", en: "This backup does not contain managed configuration files.")
            )
        }
    }

    private func backupTextIdentity(for file: ClientConfigFileTextSnapshot) -> String {
        [
            "backup",
            self.detail.id,
            file.path,
            self.previewRevealsSecrets ? "reveal" : "masked",
        ].joined(separator: "|")
    }

    private func ensureSelection() {
        if self.selectedPath == nil {
            self.selectedPath = self.detail.files.first?.path
        }
    }
}

private struct ClientConfigSidebarPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            Text(self.title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            self.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.70 : 0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct ClientConfigPlanMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(self.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(self.value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct ClientConfigInlineNotice: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let detail: String
    let tone: StatusPill.Tone

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            StatusPill(text: self.title, tone: self.tone, compact: true)
            Text(self.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(self.backgroundColor(palette: palette).opacity(self.colorScheme == .dark ? 0.30 : 0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(self.foregroundColor(palette: palette).opacity(0.18), lineWidth: 1)
        )
    }

    private func backgroundColor(palette: AppearancePalette) -> Color {
        switch self.tone {
        case .accent:
            return palette.accentSoft
        case .success:
            return palette.successSoft
        case .warning:
            return palette.warningSoft
        case .danger:
            return palette.dangerSoft
        case .neutral:
            return palette.panelMuted
        }
    }

    private func foregroundColor(palette: AppearancePalette) -> Color {
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
            return palette.textSecondary
        }
    }
}

private struct ClientConfigMiniMetric: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String
    let tone: StatusPill.Tone
    let symbol: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: self.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(self.foregroundColor(palette: palette))
                Text(self.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }

            Text(self.value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(self.backgroundColor(palette: palette).opacity(self.colorScheme == .dark ? 0.34 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(self.foregroundColor(palette: palette).opacity(0.15), lineWidth: 1)
        )
    }

    private func backgroundColor(palette: AppearancePalette) -> Color {
        switch self.tone {
        case .accent:
            return palette.accentSoft
        case .success:
            return palette.successSoft
        case .warning:
            return palette.warningSoft
        case .danger:
            return palette.dangerSoft
        case .neutral:
            return palette.panelMuted
        }
    }

    private func foregroundColor(palette: AppearancePalette) -> Color {
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
            return palette.textSecondary
        }
    }
}
#endif
