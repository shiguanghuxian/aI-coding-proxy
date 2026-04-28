#if os(macOS)
import AppKit
import CodexProxyCore
import SwiftUI

struct RemoteView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if self.model.selectedRemoteWorkflowStep == .hosts {
                RemoteHostsStepView(model: self.model)
            } else {
                RemoteSelectedHostHeader(model: self.model)
                RemoteWorkflowProgress(model: self.model)
                self.detailStepView
                RemoteWorkflowFooter(model: self.model)
            }
        }
    }

    @ViewBuilder
    private var detailStepView: some View {
        switch self.model.selectedRemoteWorkflowStep {
        case .hosts:
            EmptyView()
        case .configuration:
            RemoteConfigurationStepView(model: self.model)
        case .verification:
            RemoteVerificationStepView(model: self.model)
        case .operations:
            RemoteOperationsStepView(model: self.model)
        }
    }
}

private struct RemoteWorkflowProgress: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    private let detailSteps: [DesktopAppModel.RemoteWorkflowStep] = [
        .configuration,
        .verification,
        .operations,
    ]

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        SectionCard(
            title: self.model.text(.remoteTitle),
            subtitle: self.model.text(.remoteSubtitle),
            accessory: StatusPill(
                text: self.model.remoteWorkflowStepStatusText(self.model.selectedRemoteWorkflowStep),
                tone: self.model.remoteWorkflowStepTone(self.model.selectedRemoteWorkflowStep)
            ),
            compact: true
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    self.stepItems(palette: palette)
                }

                VStack(alignment: .leading, spacing: 10) {
                    self.stepItems(palette: palette)
                }
            }
        }
        .background(RemoteViewFrameProbe(identifier: "remote-workflow-step-strip"))
        .accessibilityIdentifier("remote-workflow-step-strip")
    }

    @ViewBuilder
    private func stepItems(palette: AppearancePalette) -> some View {
        ForEach(Array(self.detailSteps.enumerated()), id: \.offset) { index, step in
            let isCurrent = self.model.selectedRemoteWorkflowStep == step
            let isEnabled = self.model.canEnterRemoteWorkflowStep(step) || step.rawValue <= self.model.selectedRemoteWorkflowStep.rawValue
            let tone = self.model.remoteWorkflowStepTone(step)

            Button {
                self.model.selectRemoteWorkflowStep(step)
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                isCurrent
                                    ? palette.accent
                                    : (isEnabled ? palette.panelRaised : palette.panelMuted)
                            )

                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(isCurrent ? Color.white : palette.textPrimary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(self.model.remoteWorkflowStepTitle(step))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isEnabled ? palette.textPrimary : palette.textSecondary)
                            .lineLimit(1)
                        Text(self.model.remoteWorkflowStepStatusText(step))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(isEnabled ? tone.foregroundColor(palette: palette) : palette.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isCurrent ? palette.panel : palette.panelRaised.opacity(isEnabled ? 1.0 : 0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isCurrent ? palette.accent.opacity(0.24) : palette.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .interactiveCursor(isEnabled: isEnabled)
        }
    }
}

private struct RemoteHostsStepView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.remoteWorkflowStepTitle(.hosts),
            subtitle: self.model.remoteWorkflowStepSubtitle(.hosts),
            accessory: StatusPill(
                text: self.model.savedRemoteHosts.isEmpty ? self.model.text(.statusNoData) : "\(self.model.savedRemoteHosts.count)",
                tone: self.model.savedRemoteHosts.isEmpty ? .warning : .accent
            )
        ) {
            QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                CompactActionToolbarButton(
                    title: self.model.text(.actionCreateRemoteHost),
                    helpText: self.model.remoteWorkflowStepSubtitle(.configuration),
                    symbol: "plus.circle.fill",
                    tone: .accent
                ) {
                    self.model.createNewRemoteHost()
                }

                CompactActionToolbarButton(
                    title: self.model.text(.actionDeleteHost),
                    helpText: self.model.localized(
                        zh: "删除当前选中的已保存远程主机配置。",
                        en: "Delete the currently selected saved remote host."
                    ),
                    symbol: "trash.fill",
                    tone: .danger
                ) {
                    Task { await self.model.removeSelectedRemoteHost() }
                }
                .disabled(!self.model.canDeleteSelectedRemoteHost())
            }

            RemoteHintPanel(
                text: self.model.localized(
                    zh: "先在这里选择一台主机，再进入连接配置、部署前验证和部署与运维。",
                    en: "Choose a host here first, then continue to connection setup, preflight checks, and operations."
                ),
                tone: .accent
            )

            if self.model.savedRemoteHosts.isEmpty {
                EmptyStatePanel(
                    title: self.model.text(.sectionSavedHosts),
                    detail: self.model.text(.remoteSavedHostsEmpty)
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.model.savedRemoteHosts) { host in
                        RemoteHostChip(
                            host: host,
                            isSelected: self.model.selectedRemoteHost.id == host.id,
                            entryTitle: self.model.localized(zh: "进入配置", en: "Open Config")
                        ) {
                            self.model.selectRemoteHost(id: host.id)
                        }
                        .background(RemoteViewFrameProbe(identifier: "remote-host-row-\(host.id)"))
                        .accessibilityIdentifier("remote-host-row-\(host.id)")
                    }
                }
            }

            RemoteHostDraftSummary(model: self.model)
        }
        .background(RemoteViewFrameProbe(identifier: "remote-host-management-card"))
        .accessibilityIdentifier("remote-host-management-card")
    }
}

private struct RemoteSelectedHostHeader: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.selectedRemoteHostDisplayName,
            subtitle: self.model.localized(
                zh: self.model.isSelectedRemoteHostSaved() ? "当前正在管理的远程主机。" : "当前未保存的远程主机草稿。",
                en: self.model.isSelectedRemoteHostSaved() ? "The remote host currently being managed." : "The current unsaved remote host draft."
            ),
            accessory: Button(self.model.localized(zh: "切换主机", en: "Switch Host")) {
                self.model.selectRemoteWorkflowStep(.hosts)
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .background(RemoteViewFrameProbe(identifier: "remote-switch-host-button"))
            .accessibilityIdentifier("remote-switch-host-button"),
            compact: true
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    self.summaryBlocks
                }

                VStack(alignment: .leading, spacing: 12) {
                    self.summaryBlocks
                }
            }
        }
        .background(RemoteViewFrameProbe(identifier: "remote-selected-host-card"))
        .accessibilityIdentifier("remote-selected-host-card")
    }

    private var summaryBlocks: some View {
        Group {
            RemoteSummaryItem(
                title: self.model.text(.labelHost),
                value: self.model.selectedRemoteHost.host.isEmpty ? self.model.text(.statusNoData) : self.model.selectedRemoteHost.host
            )
            RemoteSummaryItem(
                title: self.model.text(.labelSSHUser),
                value: "\(self.model.selectedRemoteHost.sshUser) · \(self.model.text(.labelSSHPort)) \(self.model.selectedRemoteHost.sshPort)"
            )
            RemoteSummaryItem(
                title: self.model.text(.labelPublicPort),
                value: "\(self.model.selectedRemoteHost.publicPort) / \(self.model.selectedRemoteHost.adminPort)"
            )
            RemoteSummaryItem(
                title: self.model.text(.labelRemoteDirectory),
                value: self.model.selectedRemoteHost.remoteDirectory
            )
        }
    }
}

private struct RemoteConfigurationStepView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.remoteWorkflowStepTitle(.configuration),
            subtitle: self.model.remoteWorkflowStepSubtitle(.configuration),
            accessory: StatusPill(
                text: self.model.canEnterRemoteWorkflowStep(.verification)
                    ? self.model.text(.statusReady)
                    : self.model.localized(zh: "草稿", en: "Draft"),
                tone: self.model.canEnterRemoteWorkflowStep(.verification) ? .success : .neutral
            )
        ) {
            RemoteFormGroup(title: self.model.text(.sectionRemoteConnection)) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        self.connectionFields
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        self.connectionFields
                    }
                }
            }

            RemoteFormGroup(title: self.model.text(.sectionRemoteAuthentication)) {
                VStack(alignment: .leading, spacing: 12) {
                    FormFieldPanel(title: self.model.text(.labelAuth)) {
                        Picker(self.model.text(.labelAuth), selection: self.$model.selectedRemoteHost.authMode) {
                            ForEach(RemoteHostConfig.AuthMode.allCases, id: \.self) { mode in
                                Text(self.model.label(for: mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Group {
                        switch self.model.selectedRemoteHost.authMode {
                        case .password:
                            FormFieldPanel(title: self.model.text(.labelSSHPassword)) {
                                SecureField(self.model.text(.labelSSHPassword), text: self.$model.selectedRemoteHost.password)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }
                        case .sshKeyPath:
                            FormFieldPanel(title: self.model.text(.labelIdentityFile)) {
                                TextField(self.model.text(.labelIdentityFile), text: self.$model.selectedRemoteHost.identityFile)
                                    .textFieldStyle(.plain)
                                    .dashboardFieldChrome()
                            }
                        case .sshKeyContent:
                            FormFieldPanel(title: self.model.text(.labelPrivateKey)) {
                                TextEditor(text: self.$model.selectedRemoteHost.privateKey)
                                    .frame(minHeight: 150)
                                    .dashboardFieldChrome()
                            }
                        }
                    }
                }
            }

            RemoteFormGroup(title: self.model.text(.sectionRemoteRuntimeConfig)) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        self.runtimeFields
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        self.runtimeFields
                    }
                }
            }

            if let validationMessage = self.model.remoteHostValidationMessage(for: self.model.selectedRemoteHost) {
                RemoteHintPanel(text: validationMessage, tone: .warning)
            }
        }
    }

    private var connectionFields: some View {
        Group {
            FormFieldPanel(title: self.model.text(.labelLabel)) {
                TextField(self.model.text(.labelLabel), text: self.$model.selectedRemoteHost.label)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelHost)) {
                TextField(self.model.text(.labelHost), text: self.$model.selectedRemoteHost.host)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelSSHUser)) {
                TextField(self.model.text(.labelSSHUser), text: self.$model.selectedRemoteHost.sshUser)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelSSHPort)) {
                TextField(
                    self.model.text(.labelSSHPort),
                    value: self.$model.selectedRemoteHost.sshPort,
                    formatter: NumberFormatter()
                )
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
            }
        }
    }

    private var runtimeFields: some View {
        Group {
            FormFieldPanel(title: self.model.text(.labelRemoteDirectory)) {
                TextField(self.model.text(.labelRemoteDirectory), text: self.$model.selectedRemoteHost.remoteDirectory)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelPublicPort)) {
                TextField(
                    self.model.text(.labelPublicPort),
                    value: self.$model.selectedRemoteHost.publicPort,
                    formatter: NumberFormatter()
                )
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelAdminPort)) {
                TextField(
                    self.model.text(.labelAdminPort),
                    value: self.$model.selectedRemoteHost.adminPort,
                    formatter: NumberFormatter()
                )
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
            }
        }
    }
}

private struct RemoteVerificationStepView: View {
    @ObservedObject var model: DesktopAppModel

    private let verificationColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12),
    ]

    var body: some View {
        let hostID = self.model.selectedRemoteHost.id

        SectionCard(
            title: self.model.remoteWorkflowStepTitle(.verification),
            subtitle: self.model.remoteWorkflowStepSubtitle(.verification),
            accessory: StatusPill(
                text: self.verificationStatusText(hostID: hostID),
                tone: self.verificationStatusTone(hostID: hostID)
            )
        ) {
            if self.model.isSelectedRemoteHostSaved() {
                QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    CompactActionToolbarButton(
                        title: self.model.selectedRemoteConnectionCheck == nil
                            ? self.model.text(.actionTestConnection)
                            : self.model.text(.actionRetestConnection),
                        helpText: self.model.remoteWorkflowStepSubtitle(.verification),
                        symbol: "point.3.connected.trianglepath.dotted",
                        tone: .accent
                    ) {
                        Task { await self.model.testSelectedRemoteConnection() }
                    }
                    .disabled(self.model.isRemoteTesting(hostID: hostID))
                }

                if let check = self.model.selectedRemoteConnectionCheck {
                    LazyVGrid(columns: self.verificationColumns, spacing: 12) {
                        MetricTile(
                            label: self.model.text(.labelArchitecture),
                            value: check.architecture,
                            tone: .neutral,
                            symbol: "cpu.fill"
                        )
                        MetricTile(
                            label: self.model.text(.labelRemoteUser),
                            value: check.remoteUser,
                            tone: .neutral,
                            symbol: "person.crop.circle.fill"
                        )
                        MetricTile(
                            label: self.model.text(.labelSystemctl),
                            value: self.booleanStatusText(check.systemctlAvailable),
                            tone: check.systemctlAvailable ? .success : .danger,
                            symbol: "gearshape.2.fill"
                        )
                        MetricTile(
                            label: self.model.text(.labelSudo),
                            value: self.booleanStatusText(check.sudoAvailable),
                            tone: check.sudoAvailable ? .success : .danger,
                            symbol: "lock.shield.fill"
                        )
                        MetricTile(
                            label: self.model.text(.labelLocalArtifacts),
                            value: self.booleanStatusText(check.localArtifactAvailable),
                            tone: check.localArtifactAvailable ? .success : .danger,
                            symbol: "shippingbox.fill"
                        )
                        MetricTile(
                            label: self.model.text(.labelRemoteDirectory),
                            value: self.booleanStatusText(check.remoteDirectoryWritable),
                            tone: check.remoteDirectoryWritable ? .success : .danger,
                            symbol: "folder.fill.badge.gearshape"
                        )
                    }
                } else {
                    EmptyStatePanel(
                        title: self.model.text(.sectionRemoteVerification),
                        detail: self.model.text(.helperRemoteNeedsVerification)
                    )
                }

                let issues = self.model.remoteReadinessIssues(for: hostID)
                if !issues.isEmpty {
                    RemoteReadinessPanel(
                        title: self.model.text(.labelReadiness),
                        issues: issues,
                        tone: self.model.remoteReadinessTone(for: hostID)
                    )
                }
            } else {
                EmptyStatePanel(
                    title: self.model.text(.sectionRemoteVerification),
                    detail: self.model.text(.helperRemoteNeedsSavedHost)
                )
            }
        }
    }

    private func verificationStatusText(hostID: String) -> String {
        if self.model.isRemoteTesting(hostID: hostID) {
            return self.model.text(.statusTesting)
        }
        if self.model.hasSuccessfulRemoteManagementCheck(for: hostID) {
            return self.model.text(.statusReady)
        }
        if self.model.selectedRemoteConnectionError?.isEmpty == false {
            return self.model.text(.statusFailed)
        }
        if self.model.selectedRemoteConnectionCheck != nil {
            return self.model.text(.statusUnavailable)
        }
        return self.model.text(.statusNoData)
    }

    private func verificationStatusTone(hostID: String) -> StatusPill.Tone {
        if self.model.isRemoteTesting(hostID: hostID) {
            return .accent
        }
        if self.model.hasSuccessfulRemoteManagementCheck(for: hostID) {
            return .success
        }
        if self.model.selectedRemoteConnectionError?.isEmpty == false {
            return .danger
        }
        if self.model.selectedRemoteConnectionCheck != nil {
            return .warning
        }
        return .neutral
    }

    private func booleanStatusText(_ value: Bool) -> String {
        value ? self.model.text(.statusReady) : self.model.text(.statusUnavailable)
    }
}

private struct RemoteOperationsStepView: View {
    @ObservedObject var model: DesktopAppModel

    private let metricColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12),
    ]

    var body: some View {
        let hostID = self.model.selectedRemoteHost.id

        VStack(alignment: .leading, spacing: 18) {
            SectionCard(
                title: self.model.remoteWorkflowStepTitle(.operations),
                subtitle: self.model.remoteWorkflowStepSubtitle(.operations),
                accessory: StatusPill(
                    text: self.model.remoteServiceStatusText(for: hostID),
                    tone: self.model.remoteServiceTone(for: hostID)
                )
            ) {
                if let status = self.model.remoteStatuses[hostID] {
                    LazyVGrid(columns: self.metricColumns, spacing: 12) {
                        MetricTile(
                            label: self.model.text(.labelInstalled),
                            value: status.installed ? self.model.text(.statusOnline) : self.model.text(.statusOffline),
                            tone: status.installed ? .success : .warning,
                            symbol: "shippingbox.fill"
                        )
                        MetricTile(
                            label: self.model.text(.labelRunning),
                            value: self.model.remoteServiceStatusText(for: hostID),
                            tone: self.metricTone(for: hostID),
                            symbol: "play.circle.fill"
                        )
                        MetricTile(
                            label: self.model.text(.labelEnabled),
                            value: status.enabled ? self.model.text(.statusOnline) : self.model.text(.statusOffline),
                            tone: status.enabled ? .accent : .neutral,
                            symbol: "switch.2"
                        )
                        MetricTile(
                            label: self.model.text(.labelArchitecture),
                            value: status.architecture,
                            tone: .neutral,
                            symbol: "cpu.fill"
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        CodeValueBlock(
                            label: self.model.text(.labelEndpoint),
                            value: status.baseURL,
                            actionTitle: nil,
                            action: nil
                        )
                        if let apiKey = status.apiKey, !apiKey.isEmpty {
                            CodeValueBlock(
                                label: self.model.text(.labelAPIKey),
                                value: apiKey,
                                actionTitle: nil,
                                isSensitive: true,
                                action: nil
                            )
                        }
                    }
                } else {
                    EmptyStatePanel(
                        title: self.model.text(.sectionRemoteStatus),
                        detail: self.model.text(.placeholderNoRemoteStatus)
                    )
                }

                if let deployDisabledMessage = self.model.remoteDeployDisabledMessage(for: hostID) {
                    RemoteHintPanel(text: deployDisabledMessage, tone: .warning)
                }

                QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    CompactActionToolbarButton(
                        title: self.model.remoteDeployButtonTitle(for: hostID),
                        helpText: self.model.remoteDeployButtonHelpText(for: hostID),
                        symbol: "square.and.arrow.up.fill",
                        tone: .accent
                    ) {
                        Task { await self.model.deploySelectedRemote() }
                    }
                    .disabled(self.model.isRemoteDeploying(hostID: hostID) || !self.model.canDeployRemoteHost(for: hostID))

                    CompactActionToolbarButton(
                        title: self.model.isRemoteStatusLoading(hostID: hostID)
                            ? self.model.text(.statusChecking)
                            : self.model.text(.actionLoadStatus),
                        helpText: self.model.text(.helperRemoteStatusRequired),
                        symbol: "arrow.clockwise.circle.fill",
                        tone: .neutral
                    ) {
                        Task { await self.model.refreshSelectedRemote() }
                    }
                    .disabled(self.model.isRemoteStatusLoading(hostID: hostID) || !self.model.canManageRemoteHostOperations(for: hostID))

                    CompactActionToolbarButton(
                        title: self.model.isRemoteLogsLoading(hostID: hostID)
                            ? self.model.text(.statusLoadingLogs)
                            : self.model.text(.actionLogs),
                        helpText: self.model.text(.remoteLogsHint),
                        symbol: "doc.text.magnifyingglass",
                        tone: .success
                    ) {
                        Task { await self.model.loadSelectedRemoteLogs() }
                    }
                    .disabled(self.model.isRemoteLogsLoading(hostID: hostID) || !self.model.canManageRemoteHostOperations(for: hostID))

                    CompactActionToolbarButton(
                        title: self.model.localized(zh: "打开远端管理台", en: "Open Remote Admin"),
                        helpText: self.model.localized(
                            zh: "通过临时 SSH 隧道打开当前主机的账号、代理和统计管理台。",
                            en: "Open the current host's accounts, proxy, and stats console over a temporary SSH tunnel."
                        ),
                        symbol: "rectangle.and.text.magnifyingglass",
                        tone: .warning
                    ) {
                        self.model.openSelectedRemoteAdminWindow()
                    }
                    .disabled(!self.model.canOpenRemoteAdminWindow(for: hostID))
                }

                ServiceActionBar(
                    start: .init(
                        title: self.model.remoteStartButtonTitle(for: hostID),
                        isEnabled: self.model.remoteCanStartService(for: hostID),
                        isLoading: self.model.isRemoteServiceStarting(for: hostID),
                        kind: .primary,
                        action: self.start
                    ),
                    stop: .init(
                        title: self.model.remoteStopButtonTitle(for: hostID),
                        isEnabled: self.model.remoteCanStopService(for: hostID),
                        isLoading: self.model.isRemoteServiceStopping(for: hostID),
                        kind: .danger,
                        action: self.stop
                    ),
                    helperText: self.model.remoteServiceHelperText(for: hostID),
                    helperTone: self.model.remoteServiceTone(for: hostID)
                )
            }

            SectionCard(
                title: self.model.text(.sectionLogs),
                subtitle: self.model.text(.remoteLogsHint)
            ) {
                if self.model.currentRemoteLogs.isEmpty {
                    EmptyStatePanel(
                        title: self.model.text(.sectionLogs),
                        detail: self.model.text(.placeholderNoRemoteLogsForHost)
                    )
                } else {
                    RemoteConsoleView(logs: self.model.currentRemoteLogs)
                }
            }
        }
    }

    private func start() {
        Task { await self.model.startSelectedRemote() }
    }

    private func stop() {
        Task { await self.model.stopSelectedRemote() }
    }

    private func metricTone(for hostID: String) -> MetricTile.Tone {
        switch self.model.remoteServiceControlState(for: hostID) {
        case .unloaded:
            return .neutral
        case .stopped, .stopping:
            return .warning
        case .starting:
            return .accent
        case .running:
            return .success
        case .unreachable:
            return .danger
        }
    }
}

private struct RemoteWorkflowFooter: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        if self.model.selectedRemoteWorkflowStep != .hosts {
            SectionCard(
                title: self.model.remoteWorkflowStepTitle(self.model.selectedRemoteWorkflowStep),
                subtitle: self.model.remoteWorkflowStepSubtitle(self.model.selectedRemoteWorkflowStep),
                compact: true
            ) {
                HStack(spacing: 10) {
                    Button(self.model.text(.actionBack)) {
                        self.model.retreatRemoteWorkflowStep()
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .secondary))

                    Spacer(minLength: 0)

                    switch self.model.selectedRemoteWorkflowStep {
                    case .hosts:
                        EmptyView()
                    case .configuration:
                        Button(self.model.localized(zh: "保存并开始验证", en: "Save & Start Verification")) {
                            Task { await self.model.saveSelectedRemoteHostAndContinue() }
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                        .disabled(!self.model.canSaveSelectedRemoteHost() || self.model.isRemoteSaving(hostID: self.model.selectedRemoteHost.id))
                    case .verification:
                        Button(self.verificationActionTitle) {
                            Task { await self.model.testSelectedRemoteConnection() }
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                        .disabled(!self.model.canEnterRemoteWorkflowStep(.verification) || self.model.isRemoteTesting(hostID: self.model.selectedRemoteHost.id))
                    case .operations:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var verificationActionTitle: String {
        let hostID = self.model.selectedRemoteHost.id
        if self.model.isRemoteTesting(hostID: hostID) {
            return self.model.text(.statusTesting)
        }
        return self.model.selectedRemoteConnectionCheck == nil
            ? self.model.text(.actionTestConnection)
            : self.model.text(.actionRetestConnection)
    }
}

private struct RemoteHostDraftSummary: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let isSaved = self.model.canEnterRemoteWorkflowStep(.verification)
        let title = self.model.selectedRemoteHostDisplayName

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(
                        self.model.localized(
                            zh: isSaved ? "当前选中的已保存主机" : "当前远程主机草稿",
                            en: isSaved ? "Currently selected saved host" : "Current remote host draft"
                        )
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 0)

                StatusPill(
                    text: isSaved ? self.model.text(.statusReady) : self.model.localized(zh: "草稿", en: "Draft"),
                    tone: isSaved ? .success : .neutral
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    self.summaryBlocks
                }

                VStack(alignment: .leading, spacing: 12) {
                    self.summaryBlocks
                }
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

    private var summaryBlocks: some View {
        Group {
            RemoteSummaryItem(
                title: self.model.text(.labelHost),
                value: self.model.selectedRemoteHost.host.isEmpty ? self.model.text(.statusNoData) : self.model.selectedRemoteHost.host
            )
            RemoteSummaryItem(
                title: self.model.text(.labelSSHUser),
                value: "\(self.model.selectedRemoteHost.sshUser) · \(self.model.label(for: self.model.selectedRemoteHost.authMode))"
            )
            RemoteSummaryItem(
                title: self.model.text(.labelPublicPort),
                value: "\(self.model.selectedRemoteHost.publicPort) / \(self.model.selectedRemoteHost.adminPort)"
            )
            RemoteSummaryItem(
                title: self.model.text(.labelRemoteDirectory),
                value: self.model.selectedRemoteHost.remoteDirectory
            )
        }
    }
}

private struct RemoteSummaryItem: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 5) {
            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            Text(self.value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.84 : 0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct RemoteFormGroup<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            Text(self.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.textPrimary)

            self.content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.95 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct RemoteHintPanel: View {
    let text: String
    let tone: StatusPill.Tone

    var body: some View {
        RemoteReadinessPanel(title: nil, issues: [self.text], tone: self.tone)
    }
}

private struct RemoteReadinessPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String?
    let issues: [String]
    let tone: StatusPill.Tone

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let background = self.backgroundColor(palette: palette)

        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
            }

            ForEach(Array(self.issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: self.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(self.tone.foregroundColor(palette: palette))
                        .padding(.top, 2)

                    Text(issue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private var symbolName: String {
        switch self.tone {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .danger:
            return "xmark.octagon.fill"
        case .accent:
            return "sparkles"
        case .neutral:
            return "info.circle.fill"
        }
    }

    private func backgroundColor(palette: AppearancePalette) -> Color {
        switch self.tone {
        case .accent:
            return palette.accentSoft
        case .success:
            return palette.success.opacity(self.colorScheme == .dark ? 0.18 : 0.12)
        case .warning:
            return palette.warning.opacity(self.colorScheme == .dark ? 0.18 : 0.12)
        case .danger:
            return palette.danger.opacity(self.colorScheme == .dark ? 0.18 : 0.12)
        case .neutral:
            return palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 0.96)
        }
    }
}

private struct RemoteHostChip: View {
    @Environment(\.colorScheme) private var colorScheme

    let host: RemoteHostConfig
    let isSelected: Bool
    let entryTitle: String
    let action: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Button(action: self.action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(self.isSelected ? palette.accentSoft : palette.panelMuted)
                    Image(systemName: "server.rack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(self.isSelected ? palette.accent : palette.textSecondary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 6) {
                    Text(self.host.label.isEmpty ? self.host.host : self.host.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.host.host)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                    Text("\(self.host.sshUser) · SSH \(self.host.sshPort) · \(self.host.publicPort)/\(self.host.adminPort)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Text(self.entryTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(self.isSelected ? palette.accent : palette.textSecondary)
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(self.isSelected ? palette.accent : palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(self.isSelected ? palette.panelRaised : palette.panelMuted.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(self.isSelected ? palette.accent.opacity(0.22) : palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .interactiveCursor()
    }
}

private struct RemoteConsoleView: View {
    @Environment(\.colorScheme) private var colorScheme

    let logs: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ScrollView {
            Text(self.logs)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: 280)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.consoleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct RemoteViewFrameProbe: NSViewRepresentable {
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

private extension StatusPill.Tone {
    func foregroundColor(palette: AppearancePalette) -> Color {
        switch self {
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
