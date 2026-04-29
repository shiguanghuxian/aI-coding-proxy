#if os(macOS)
import CodexProxyCore
import SwiftUI

struct ClientConfigManagerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        GeometryReader { proxy in
            let layout = ClientConfigManagerLayout(size: proxy.size)
            let palette = AppearanceStore.palette(for: self.colorScheme)

            ZStack(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: layout.columnSpacing) {
                    ClientConfigPlanSidebar(
                        model: self.model,
                        inspection: self.inspection,
                        selectionStatusText: self.selectionStatusText,
                        selectionStatusTone: self.selectionStatusTone
                    )
                    .frame(width: layout.sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)

                    ClientConfigWorkspace(
                        model: self.model,
                        inspection: self.inspection
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, layout.outerPadding)
                .padding(.vertical, layout.outerPadding)

                if self.model.isClientConfigBackupDrawerPresented {
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
                        width: self.model.clientConfigBackupDrawerMode == .detail
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
    let outerPadding: CGFloat
    let columnSpacing: CGFloat
    let sidebarWidth: CGFloat
    let listDrawerWidth: CGFloat
    let detailDrawerWidth: CGFloat

    init(size: CGSize) {
        let compact = size.width < 1180 || size.height < 760
        self.outerPadding = compact ? 16 : 22
        self.columnSpacing = compact ? 12 : 16
        self.sidebarWidth = compact ? 310 : 340
        self.listDrawerWidth = min(max(size.width * 0.36, 380), min(520, max(size.width - 120, 380)))
        self.detailDrawerWidth = min(max(size.width * 0.62, 620), min(920, max(size.width - 96, 620)))
    }
}

private struct ClientConfigPlanSidebar: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let inspection: ClientConfigInspection
    let selectionStatusText: String
    let selectionStatusTone: StatusPill.Tone

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(self.model.clientConfigManagerWindowTitle)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                }

                Text(self.model.localized(
                    zh: "选择客户端和本地 Key，确认写入摘要后应用到真实配置文件。",
                    en: "Choose the client and local key, review the write summary, then apply to real config files."
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ClientConfigSidebarPanel(title: self.model.localized(zh: "目标客户端", en: "Target Client")) {
                        Picker("", selection: self.$model.clientConfigManagerTarget) {
                            ForEach(ClientConfigTarget.allCases) { target in
                                Text(self.model.clientConfigManagerTitle(for: target)).tag(target)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: self.model.clientConfigManagerTarget) { _, newTarget in
                            self.model.clientConfigManagerSelectProxyAPIKey(
                                self.model.clientConfigManagerSelectedProxyAPIKeyRecord(for: newTarget)?.id,
                                for: newTarget
                            )
                        }
                    }

                    ClientConfigSidebarPanel(title: self.model.localized(zh: "写入 Key", en: "Key To Write")) {
                        if self.model.clientConfigManagerAvailableProxyAPIKeys.isEmpty {
                            ClientConfigInlineNotice(
                                title: self.model.localized(zh: "没有启用的本地 Key", en: "No Enabled Local Key"),
                                detail: self.model.localized(
                                    zh: "先到 Proxy 页启用至少一把本地 API Key。",
                                    en: "Enable at least one local API key on the Proxy page first."
                                ),
                                tone: .warning
                            )
                        } else {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { self.model.clientConfigManagerSelectedProxyAPIKeyRecord()?.id ?? "" },
                                    set: { self.model.clientConfigManagerSelectProxyAPIKey($0) }
                                )
                            ) {
                                ForEach(self.model.clientConfigManagerAvailableProxyAPIKeys) { record in
                                    Text(self.model.proxyAPIKeyDisplayLabel(record)).tag(record.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    ClientConfigSidebarPanel(title: self.model.localized(zh: "配置计划", en: "Configuration Plan")) {
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
                .padding(.trailing, 2)
            }
            .scrollIndicators(.hidden)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await self.model.applyClientConfigManagerSelection() }
                } label: {
                    Text(self.model.clientConfigManagerApplyButtonTitle())
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .frame(maxWidth: .infinity)
                .disabled(!self.model.clientConfigManagerCanApplyCurrentSelection)

                VStack(alignment: .leading, spacing: 8) {
                    self.utilityButtons
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.985))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private var utilityButtons: some View {
        Group {
            self.utilityButton(
                title: self.model.clientConfigManagerRevealFilesButtonTitle,
                systemImage: "folder",
                action: self.model.revealClientConfigManagedFiles
            )

            self.utilityButton(
                title: self.model.clientConfigManagerViewBackupsButtonTitle,
                systemImage: "clock.arrow.circlepath",
                action: self.model.presentClientConfigBackupDrawer
            )

            self.utilityButton(
                title: self.model.clientConfigManagerRefreshStatusButtonTitle,
                systemImage: "arrow.clockwise"
            ) {
                Task { await self.model.refreshClientConfigManagerState(showLoading: true) }
            }
        }
    }

    private func utilityButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .frame(maxWidth: .infinity)
        .disabled(self.model.isClientConfigManagerBusy)
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

private struct ClientConfigWorkspace: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let inspection: ClientConfigInspection

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            self.header(palette: palette)

            HStack(alignment: .top, spacing: 14) {
                ClientConfigManagedFileList(model: self.model)
                    .frame(width: 280)

                ClientConfigEditorPanel(model: self.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.model.clientConfigManagerTitle(for: self.model.clientConfigManagerTarget))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.model.localized(
                        zh: "查看当前配置和应用后的最终内容。预览为只读，只有点击应用才会写入磁盘。",
                        en: "Inspect current config and final applied content. Preview is read-only; only Apply writes to disk."
                    ))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 0)

                StatusPill(
                    text: self.operationText,
                    tone: self.operationTone,
                    compact: true
                )
            }

            LazyVGrid(columns: self.metricColumns, alignment: .leading, spacing: 10) {
                ClientConfigMiniMetric(
                    title: self.model.localized(zh: "受管文件", en: "Managed Files"),
                    value: "\(self.inspection.files.filter(\.exists).count) / \(self.inspection.files.count)",
                    tone: .neutral,
                    symbol: "doc.on.doc.fill"
                )
                ClientConfigMiniMetric(
                    title: self.model.localized(zh: "将修改", en: "Changes"),
                    value: "\(self.model.clientConfigManagerChangedFileCount)",
                    tone: self.model.clientConfigManagerChangedFileCount == 0 ? .neutral : .accent,
                    symbol: "square.and.pencil"
                )
                ClientConfigMiniMetric(
                    title: self.model.localized(zh: "当前 Key", en: "Current Key"),
                    value: self.model.clientConfigManagerCurrentKeyStatusText(for: self.inspection),
                    tone: self.currentKeyTone,
                    symbol: "key.fill"
                )
            }
        }
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top),
        ]
    }

    private var operationText: String {
        switch self.model.clientConfigManagerOperation {
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
        switch self.model.clientConfigManagerOperation {
        case .idle:
            return .success
        case .loading:
            return .accent
        case .applying, .restoring:
            return .warning
        }
    }

    private var currentKeyTone: StatusPill.Tone {
        if self.inspection.errorMessage?.isEmpty == false {
            return .danger
        }
        switch self.inspection.currentKeyKind {
        case .missing:
            return .warning
        case .matched:
            return .success
        case .external:
            return .neutral
        }
    }
}

private struct ClientConfigManagedFileList: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(self.model.localized(zh: "文件", en: "Files").uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)
                Spacer(minLength: 0)
                Text(self.model.clientConfigManagerChangeSummaryText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            if self.model.clientConfigManagerVisibleFilePresentations.isEmpty {
                EmptyStatePanel(
                    title: self.model.localized(zh: "没有可显示文件", en: "No Files"),
                    detail: self.model.localized(zh: "当前目标没有返回可预览的配置文件。", en: "The selected target has no previewable config files.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(self.model.clientConfigManagerVisibleFilePresentations) { presentation in
                            ClientConfigManagedFileRow(
                                model: self.model,
                                presentation: presentation,
                                isSelected: self.model.clientConfigManagerSelectedPreviewFile?.path == presentation.file.path
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
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

    @ObservedObject var model: DesktopAppModel
    let presentation: ClientConfigPreviewFilePresentation
    let isSelected: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let tone = self.model.clientConfigManagerFileChangeKindTone(self.presentation.changeKind)

        Button {
            self.model.clientConfigManagerSelectPreviewFile(self.presentation.file.path)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.iconBackground(palette: palette, tone: tone))
                    Image(systemName: self.model.clientConfigManagerFileChangeKindSymbol(self.presentation.changeKind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(self.iconForeground(palette: palette, tone: tone))
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
                        text: self.model.clientConfigManagerFileChangeKindText(self.presentation.changeKind),
                        tone: tone,
                        compact: true
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(self.isSelected ? palette.accentSoft.opacity(0.72) : palette.panelRaised.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(self.isSelected ? palette.accent.opacity(0.28) : palette.border, lineWidth: 1)
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

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            self.toolbar(palette: palette)

            if let presentation = self.model.clientConfigManagerSelectedPreviewFilePresentation {
                self.fileHeader(presentation: presentation, palette: palette)

                ClientConfigCodeEditorView(text: self.previewDisplayText(for: presentation.file))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(minHeight: 390)
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
        .padding(14)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                self.previewModePicker
                Spacer(minLength: 0)
                self.revealSecretsButton
            }

            VStack(alignment: .leading, spacing: 10) {
                self.previewModePicker
                self.revealSecretsButton
            }
        }
    }

    private var previewModePicker: some View {
        Picker("", selection: self.$model.clientConfigManagerPreviewMode) {
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

    private func previewDisplayText(for file: ClientConfigFileTextSnapshot) -> String {
        if file.exists == false, file.content.isEmpty, file.errorMessage == nil {
            return self.model.localized(zh: "这个文件当前不存在。", en: "This file does not exist yet.")
        }
        return self.model.clientConfigManagerDisplayContent(for: file)
    }
}

private struct ClientConfigBackupDrawer: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let width: CGFloat

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            switch self.model.clientConfigBackupDrawerMode {
            case .list:
                self.listContent(palette: palette)
            case .detail:
                if let detail = self.model.clientConfigManagerBackupDetail {
                    ClientConfigBackupDetailDrawerContent(model: self.model, detail: detail)
                } else {
                    self.listContent(palette: palette)
                }
            }
        }
        .padding(18)
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

            if self.model.clientConfigManagerVisibleBackups.isEmpty {
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
                        ForEach(self.model.clientConfigManagerVisibleBackups) { backup in
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
            zh: "\(self.model.clientConfigManagerTitle(for: self.model.clientConfigManagerTarget)) · \(self.model.clientConfigManagerVisibleBackups.count) 份备份",
            en: "\(self.model.clientConfigManagerTitle(for: self.model.clientConfigManagerTarget)) · \(self.model.clientConfigManagerVisibleBackups.count) backups"
        )
    }
}

private struct ClientConfigBackupDrawerRow: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
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

    @ObservedObject var model: DesktopAppModel
    let detail: ClientConfigBackupDetail

    @State private var selectedPath: String?

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            self.header(palette: palette)

            HStack(alignment: .top, spacing: 14) {
                self.fileList(palette: palette)
                    .frame(width: 270)

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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    self.metadataPills
                    Spacer(minLength: 0)
                    self.headerActions
                }

                VStack(alignment: .leading, spacing: 10) {
                    self.metadataPills
                    self.headerActions
                }
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
        .padding(14)
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

                ClientConfigCodeEditorView(text: self.backupDisplayText(for: selectedFile))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(minHeight: 440)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
            .padding(14)
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

    private func backupDisplayText(for file: ClientConfigFileTextSnapshot) -> String {
        if file.exists == false, file.content.isEmpty, file.errorMessage == nil {
            return self.model.localized(zh: "文件不存在于该备份。", en: "This file did not exist in this backup.")
        }
        return self.model.clientConfigManagerDisplayContent(for: file)
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
