#if os(macOS)
import CodexProxyCore
import SwiftUI

struct ProxyView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProxyAccessOverviewCard(model: self.model)

            DashboardTabStrip(
                items: ProxyWorkspaceTab.allCases,
                selection: self.$model.selectedProxyWorkspaceTab,
                title: { self.model.proxyWorkspaceTabTitle($0) },
                symbol: { $0.symbolName }
            ) {
                ProxyTopUtilityControls(model: self.model)
            }

            Group {
                switch self.model.selectedProxyWorkspaceTab {
                case .access:
                    VStack(alignment: .leading, spacing: 16) {
                        ProxyOpenAIAccessCard(model: self.model)

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                ProxyAnthropicAccessCard(model: self.model)
                                ProxyGeminiAccessCard(model: self.model)
                            }

                            VStack(alignment: .leading, spacing: 16) {
                                ProxyAnthropicAccessCard(model: self.model)
                                ProxyGeminiAccessCard(model: self.model)
                            }
                        }
                    }
                case .apiKeys:
                    ProxyAPIKeysManagementCard(model: self.model)
                case .usage:
                    ProxyAPIKeyUsageCard(model: self.model)
                case .advanced:
                    VStack(alignment: .leading, spacing: 16) {
                        Text(self.model.text(.helperSelectionPolicy))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ProxyAnthropicMappingCard(model: self.model)
                        ProxyNetworkSettingsCard(model: self.model)
                    }
                }
            }
        }
        .sheet(item: self.$model.proxyAPIKeyDraft) { _ in
            ProxyAPIKeyEditorSheet(model: self.model)
        }
        .sheet(isPresented: self.$model.isProxyUsageRangePickerPresented) {
            ProxyAPIKeyUsageRangeSheet(model: self.model)
        }
    }
}

struct ProxyAccessOverviewCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAccessInfo),
            subtitle: self.model.text(.proxyConnectionHint),
            accessory: StatusPill(
                text: self.model.shellServiceStatusText,
                tone: self.model.shellServiceStatusTone,
                compact: true
            ),
            compact: true
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ProxyRuntimeStatusBlock(
                            model: self.model,
                            tone: self.runtimeTone,
                            compact: true
                        )
                        .frame(minWidth: 236, maxWidth: 320, alignment: .topLeading)

                        ProxyActiveRoutingBlock(model: self.model, compact: true)
                            .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ProxyRuntimeStatusBlock(
                            model: self.model,
                            tone: self.runtimeTone,
                            compact: true
                        )
                        ProxyActiveRoutingBlock(model: self.model, compact: true)
                    }
                }

                ServiceActionBar(
                    start: .init(
                        title: self.model.localStartButtonTitle,
                        isEnabled: self.model.localCanStartService,
                        isLoading: self.model.localServiceOperation == .starting,
                        kind: .primary,
                        action: self.startDaemon
                    ),
                    stop: .init(
                        title: self.model.localStopButtonTitle,
                        isEnabled: self.model.localCanStopService,
                        isLoading: self.model.localServiceOperation == .stopping,
                        kind: .danger,
                        action: self.stopDaemon
                    ),
                    compact: true
                )
            }
        }
    }

    private func startDaemon() {
        Task { await self.model.startDaemon() }
    }

    private func stopDaemon() {
        Task { await self.model.stopDaemon() }
    }

    private var runtimeTone: StatusPill.Tone {
        switch self.model.localServiceControlState {
        case .checking:
            return .neutral
        case .notInstalled, .stopped, .stopping, .runningDegraded:
            return .warning
        case .starting:
            return .accent
        case .runningHealthy:
            return .success
        }
    }
}

private struct ProxyRuntimeStatusBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    let tone: StatusPill.Tone
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        VStack(alignment: .leading, spacing: self.compact ? 8 : 12) {
            HStack(alignment: .top, spacing: self.compact ? 10 : 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: self.compact ? 12 : 14, style: .continuous)
                        .fill(colors.iconBackground)

                    Image(systemName: "server.rack")
                        .font(.system(size: self.compact ? 14 : 16, weight: .semibold))
                        .foregroundStyle(colors.iconForeground)
                }
                .frame(width: self.compact ? 36 : 42, height: self.compact ? 36 : 42)

                VStack(alignment: .leading, spacing: self.compact ? 3 : 4) {
                    Text(self.model.text(.labelStatus).uppercased())
                        .font(.system(size: self.compact ? 9 : 10, weight: .bold))
                        .tracking(self.compact ? 0.7 : 0.8)
                        .foregroundStyle(palette.textMuted)

                    Text(self.model.localServicePrimaryStatusText)
                        .font(.system(size: self.compact ? 18 : 20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Text(self.model.localServiceSummaryText)
                .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                .foregroundStyle(self.summaryColor(palette: palette))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, self.compact ? 13 : 15)
        .padding(.vertical, self.compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [colors.backgroundTop, colors.backgroundBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
    }

    private func summaryColor(palette: AppearancePalette) -> Color {
        switch self.model.localServiceSummaryTone {
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

    private func colors(palette: AppearancePalette) -> (
        backgroundTop: Color,
        backgroundBottom: Color,
        border: Color,
        iconForeground: Color,
        iconBackground: Color
    ) {
        switch self.tone {
        case .accent:
            return (
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.94 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.accent.opacity(0.22),
                palette.accent,
                palette.accent.opacity(self.colorScheme == .dark ? 0.22 : 0.14)
            )
        case .success:
            return (
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.92 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.success.opacity(0.22),
                palette.success,
                palette.success.opacity(self.colorScheme == .dark ? 0.22 : 0.14)
            )
        case .warning:
            return (
                palette.warningSoft.opacity(self.colorScheme == .dark ? 0.92 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.warning.opacity(0.22),
                palette.warning,
                palette.warning.opacity(self.colorScheme == .dark ? 0.22 : 0.14)
            )
        case .danger:
            return (
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.92 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.danger.opacity(0.22),
                palette.danger,
                palette.danger.opacity(self.colorScheme == .dark ? 0.22 : 0.14)
            )
        case .neutral:
            return (
                palette.panelMuted.opacity(self.colorScheme == .dark ? 0.88 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.86 : 0.95),
                palette.border,
                palette.textSecondary,
                palette.border.opacity(0.9)
            )
        }
    }
}

private struct ProxyActiveRoutingBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 8 : 12) {
            HStack(alignment: .center, spacing: self.compact ? 8 : 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: self.compact ? 10 : 12, style: .continuous)
                        .fill(palette.accentSoft.opacity(self.colorScheme == .dark ? 0.26 : 0.86))

                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: self.compact ? 13 : 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
                .frame(width: self.compact ? 32 : 36, height: self.compact ? 32 : 36)

                Text(self.model.text(.labelProxySummary).uppercased())
                    .font(.system(size: self.compact ? 9 : 10, weight: .bold))
                    .tracking(self.compact ? 0.7 : 0.8)
                    .foregroundStyle(palette.textMuted)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: self.compact ? 8 : 10) {
                ProxyActiveRoutingRow(
                    label: self.model.text(.labelActiveLabel),
                    value: self.model.displayValue(self.model.status?.activeAccountLabel),
                    compact: self.compact
                )
                ProxyActiveRoutingRow(
                    label: self.model.text(.labelActiveAccount),
                    value: self.model.displayValue(self.model.status?.activeAccountID),
                    monospaced: true,
                    compact: self.compact
                )
            }
        }
        .padding(.horizontal, self.compact ? 13 : 15)
        .padding(.vertical, self.compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.88 : 0.97),
                            palette.panel.opacity(self.colorScheme == .dark ? 0.90 : 0.94),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct ProxyActiveRoutingRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    var monospaced = false
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 4 : 6) {
            Text(self.label.uppercased())
                .font(.system(size: self.compact ? 8 : 9, weight: .bold))
                .tracking(self.compact ? 0.6 : 0.7)
                .foregroundStyle(palette.textMuted)

            Text(self.value)
                .font(
                    self.monospaced
                        ? .system(size: self.compact ? 11 : 12, weight: .semibold, design: .monospaced)
                        : .system(size: self.compact ? 11 : 12, weight: .semibold)
                )
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(self.value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProxyTopUtilityControls: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        HStack(spacing: 10) {
            if self.model.adminSupportsProxyTesting {
                Button(self.model.text(.actionTestProxy)) {
                    self.model.openProxyTestConsole()
                }
                .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
                .accessibilityIdentifier("proxy-test-proxy-button")
            }
        }
        .accessibilityIdentifier("proxy-top-utility-controls")
    }
}

struct ProxyAPIKeysManagementCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAPIKeys),
            subtitle: self.model.text(.helperProxyAPIKeys)
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    self.summaryPills
                    Spacer(minLength: 0)
                    self.actions
                }

                VStack(alignment: .leading, spacing: 10) {
                    self.summaryPills
                    self.actions
                }
            }

            if self.model.configuredProxyAPIKeys.isEmpty {
                ContentUnavailableView(
                    self.model.text(.placeholderNoProxyAPIKeys),
                    systemImage: "key.slash"
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.model.configuredProxyAPIKeys) { record in
                        ProxyAPIKeyRow(model: self.model, record: record)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var summaryPills: some View {
        HStack(spacing: 8) {
            StatusPill(
                text: "\(self.model.configuredProxyAPIKeys.count) \(self.model.text(.sectionAPIKeys))",
                tone: .accent
            )
            StatusPill(
                text: "\(self.model.configuredProxyAPIKeys.filter(\.enabled).count) \(self.model.text(.statusEnabled))",
                tone: .success
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(self.model.text(.actionAddAPIKey)) {
                self.model.openAddProxyAPIKeySheet()
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))

            Button(self.model.text(.actionRotateAPIKey)) {
                Task { await self.model.rotateProxyKey() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
        }
    }
}

private struct ProxyAPIKeyRow: View {
    @ObservedObject var model: DesktopAppModel

    let record: ProxyAPIKeyRecord

    var body: some View {
        let restrictionSummary = self.model.proxyAPIKeyRestrictionSummary(for: self.record)

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(self.model.proxyAPIKeyDisplayLabel(self.record))
                        .font(.system(size: 13, weight: .bold))

                    if self.model.settings.primaryProxyAPIKeyID == self.record.id {
                        StatusPill(text: self.model.text(.labelPrimary), tone: .accent)
                    }

                    StatusPill(
                        text: self.model.label(for: self.record.dataSource),
                        tone: self.model.proxyDataSourceTone(self.record.dataSource)
                    )

                    StatusPill(
                        text: self.record.enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled),
                        tone: self.record.enabled ? .success : .warning
                    )
                }

                Text(self.model.proxyAPIKeyMaskedValue(self.record))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.2.crop.square.stack.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)

                    Text(restrictionSummary.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if restrictionSummary.staleCount > 0 {
                        StatusPill(
                            text: self.model.localized(
                                zh: "\(restrictionSummary.staleCount) 个失效",
                                en: "\(restrictionSummary.staleCount) stale"
                            ),
                            tone: .warning
                        )
                    }
                }
            }

            Spacer(minLength: 12)

            Menu {
                Button(self.model.text(.actionCopyAPIKey)) {
                    self.model.copyProxyAPIKey(self.record)
                }
                Button(self.model.text(.actionEditAPIKey)) {
                    self.model.openEditProxyAPIKeySheet(self.record)
                }
                Button(self.model.text(.actionSetPrimaryAPIKey)) {
                    Task { await self.model.setPrimaryProxyAPIKey(self.record) }
                }
                Button(self.model.text(.actionRegenerateAPIKey)) {
                    Task { await self.model.regenerateProxyAPIKey(self.record) }
                }
                Button(self.record.enabled ? self.model.text(.actionDisableAPIKey) : self.model.text(.actionEnableAPIKey)) {
                    Task { await self.model.setProxyAPIKeyEnabled(self.record, enabled: !self.record.enabled) }
                }
                Divider()
                Button(self.model.text(.actionRemoveAPIKey), role: .destructive) {
                    Task { await self.model.deleteProxyAPIKey(self.record) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .menuStyle(.borderlessButton)
            .interactiveCursor()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct ProxyAPIKeyUsageCard: View {
    @ObservedObject var model: DesktopAppModel

    private let metricColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12),
    ]

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAPIKeyUsage),
            subtitle: self.model.text(.helperProxyAPIKeyUsage),
            accessory: StatusPill(
                text: self.model.proxyUsageRangeText,
                tone: .accent
            )
        ) {
            VStack(alignment: .leading, spacing: 16) {
                self.filterBar

                LazyVGrid(columns: self.metricColumns, spacing: 12) {
                    MetricTile(
                        label: self.model.text(.sectionAPIKeys),
                        value: "\(self.model.proxyAPIKeyUsageReport.entries.count)",
                        footnote: self.model.text(.labelStatus),
                        tone: .accent,
                        symbol: "key.fill"
                    )
                    MetricTile(
                        label: self.model.text(.labelRequests),
                        value: "\(self.model.proxyAPIKeyUsageReport.totalRequests)",
                        footnote: self.model.text(.sectionTraffic),
                        tone: .accent,
                        symbol: "arrow.triangle.branch"
                    )
                    MetricTile(
                        label: self.model.text(.labelFailures),
                        value: "\(self.model.proxyAPIKeyUsageReport.totalFailures)",
                        footnote: self.model.text(.labelQuotaErrors),
                        tone: self.model.proxyAPIKeyUsageReport.totalFailures > 0 ? .danger : .neutral,
                        symbol: "exclamationmark.triangle.fill"
                    )
                    MetricTile(
                        label: self.model.text(.labelTotalTokens),
                        value: self.model.proxySummaryTokenText(self.model.proxyAPIKeyUsageReport.totalTokens),
                        footnote: self.model.text(.labelInputTokens),
                        tone: .success,
                        symbol: "chart.bar.xaxis"
                    )
                    .help(self.model.proxySummaryTokenHelp(self.model.proxyAPIKeyUsageReport.totalTokens))
                }

                if self.model.proxyAPIKeyUsageIsRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }

                if self.model.proxyAPIKeyUsageReport.entries.isEmpty && self.model.proxyAPIKeyUsageIsRefreshing == false {
                    ContentUnavailableView(
                        self.model.text(.placeholderNoProxyAPIKeyUsage),
                        systemImage: "chart.line.downtrend.xyaxis"
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(self.model.proxyAPIKeyUsageReport.entries) { entry in
                            ProxyAPIKeyUsageRow(model: self.model, entry: entry)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                self.presetButtons
                Spacer(minLength: 0)
                self.actions
            }

            VStack(alignment: .leading, spacing: 10) {
                self.presetButtons
                self.actions
            }
        }
    }

    private var presetButtons: some View {
        HStack(spacing: 8) {
            ForEach(ProxyAPIKeyUsagePreset.allCases) { preset in
                Button(self.model.proxyAPIKeyUsagePresetTitle(preset)) {
                    Task { await self.model.applyProxyAPIKeyUsagePreset(preset) }
                }
                .buttonStyle(
                    AppActionButtonStyle(
                        kind: self.model.proxyAPIKeyUsageFilter.preset == preset ? .primary : .secondary
                    )
                )
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if self.model.proxyAPIKeyUsageFilter.preset == .custom {
                Button(self.model.text(.actionSelectTimeRange)) {
                    self.model.openProxyUsageCustomRangePicker()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }

            Button(self.model.text(.commonReload)) {
                Task { await self.model.refreshProxyAPIKeyUsage() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
        }
    }
}

private struct ProxyAPIKeyUsageRow: View {
    @ObservedObject var model: DesktopAppModel

    let entry: ProxyAPIKeyUsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(self.entry.label?.isEmpty == false ? self.entry.label! : self.model.proxyUsageMaskedKey(self.entry))
                    .font(.system(size: 13, weight: .bold))

                if self.entry.isPrimary {
                    StatusPill(text: self.model.text(.labelPrimary), tone: .accent)
                }

                if let enabled = self.entry.enabled {
                    StatusPill(
                        text: enabled ? self.model.text(.statusEnabled) : self.model.text(.statusDisabled),
                        tone: enabled ? .success : .warning
                    )
                }

                StatusPill(
                    text: self.model.label(for: self.entry.dataSource),
                    tone: self.model.proxyDataSourceTone(self.entry.dataSource)
                )

                Spacer(minLength: 0)

                Text(self.model.proxyUsageLastUsedText(self.entry))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(self.model.proxyUsageMaskedKey(self.entry))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 18) {
                self.metric(label: self.model.text(.labelRequests), value: "\(self.entry.requestCount)")
                self.metric(label: self.model.text(.labelFailures), value: self.model.proxyUsageFailureRateText(self.entry))
                self.metric(
                    label: self.model.text(.labelTotalTokens),
                    value: self.model.proxySummaryTokenText(self.entry.totalTokens),
                    helpText: self.model.proxySummaryTokenHelp(self.entry.totalTokens)
                )
                self.metric(label: self.model.text(.labelLatency), value: self.model.proxyUsageAverageLatencyText(self.entry))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metric(label: String, value: String, helpText: String? = nil) -> some View {
        if let helpText, !helpText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(helpText)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProxyAPIKeyEditorSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(self.model.text(.sectionAPIKeys))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(palette.textPrimary)

                        Text(self.model.text(.helperProxyAPIKeys))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    FormFieldPanel(title: self.model.text(.labelLabel)) {
                        TextField(self.model.text(.labelLabel), text: Binding(
                            get: { self.model.proxyAPIKeyDraft?.label ?? "" },
                            set: { self.model.proxyAPIKeyDraft?.label = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                    }

                    FormFieldPanel(title: self.model.text(.labelAPIKey)) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(self.model.text(.labelAPIKey), text: Binding(
                                get: { self.model.proxyAPIKeyDraft?.key ?? "" },
                                set: { self.model.proxyAPIKeyDraft?.key = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .dashboardFieldChrome()

                            Button(self.model.text(.actionRegenerateAPIKey)) {
                                self.model.proxyAPIKeyDraft?.key = AppConfig.generatedProxyAPIKey()
                            }
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        }
                    }

                    FormFieldPanel(
                        title: self.model.localized(zh: "数据源", en: "Data Source"),
                        footer: self.model.proxyDataSourceDetailText(self.model.proxyAPIKeyDraft?.dataSource ?? .all)
                    ) {
                        Picker(
                            self.model.localized(zh: "数据源", en: "Data Source"),
                            selection: Binding(
                                get: { self.model.proxyAPIKeyDraft?.dataSource ?? .all },
                                set: { self.model.proxyAPIKeyDraft?.dataSource = $0 }
                            )
                        ) {
                            ForEach([ProxyDataSource.all, .openAI, .anthropic, .gemini], id: \.self) { source in
                                Text(self.model.label(for: source)).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    ProxyAPIKeyAccountRestrictionSection(model: self.model)

                    Toggle(
                        self.model.text(.statusEnabled),
                        isOn: Binding(
                            get: { self.model.proxyAPIKeyDraft?.enabled ?? true },
                            set: { self.model.proxyAPIKeyDraft?.enabled = $0 }
                        )
                    )
                    .toggleStyle(.switch)

                    Toggle(
                        self.model.text(.actionSetPrimaryAPIKey),
                        isOn: Binding(
                            get: { self.model.proxyAPIKeyDraft?.isPrimary ?? false },
                            set: { self.model.proxyAPIKeyDraft?.isPrimary = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: 10) {
                Button(self.model.text(.commonCancel)) {
                    self.model.dismissProxyAPIKeySheet()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Spacer(minLength: 0)

                Button(self.model.text(.actionSaveProxySettings)) {
                    Task { await self.model.saveProxyAPIKeyDraft() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
        }
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 620, minHeight: 500, idealHeight: 620, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
        .compactOverlayScrollbars()
    }
}

private struct ProxyAPIKeyAccountRestrictionSection: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let context = self.model.proxyAPIKeyAccountEditorContext()
        let hasRestriction = !(self.model.proxyAPIKeyDraft?.allowedAccountKeys ?? []).isEmpty
        let palette = AppearanceStore.palette(for: self.colorScheme)

        FormFieldPanel(
            title: self.model.text(.labelAllowedAccounts),
            footer: self.model.text(.helperProxyAPIKeyAllowedAccounts)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Button(self.model.text(.actionSelectAllCompatibleAccounts)) {
                            self.model.selectAllCompatibleProxyAPIKeyAccounts()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        .disabled(context.selectableOptions.isEmpty)

                        Button(self.model.text(.actionClearAccountRestriction)) {
                            self.model.clearProxyAPIKeyAllowedAccounts()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        .disabled(hasRestriction == false)

                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button(self.model.text(.actionSelectAllCompatibleAccounts)) {
                            self.model.selectAllCompatibleProxyAPIKeyAccounts()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        .disabled(context.selectableOptions.isEmpty)

                        Button(self.model.text(.actionClearAccountRestriction)) {
                            self.model.clearProxyAPIKeyAllowedAccounts()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                        .disabled(hasRestriction == false)
                    }
                }

                if context.selectableOptions.isEmpty {
                    Text(self.model.text(.placeholderProxyAPIKeyNoCompatibleAccounts))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(palette.panelMuted.opacity(0.75))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(palette.border, lineWidth: 1)
                        )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(context.selectableOptions) { option in
                                ProxyAPIKeyAccountRestrictionOptionRow(
                                    model: self.model,
                                    option: option
                                )
                            }
                        }
                        .padding(2)
                    }
                    .frame(minHeight: 96, maxHeight: 176)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(palette.panelMuted.opacity(self.colorScheme == .dark ? 0.72 : 0.86))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
                }

                if context.staleSelections.isEmpty == false {
                    ProxyAPIKeyStaleSelectionBlock(
                        model: self.model,
                        selections: context.staleSelections
                    )
                }
            }
        }
    }
}

private struct ProxyAPIKeyAccountRestrictionOptionRow: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    let option: ProxyAPIKeyAccountOption

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Toggle(
            isOn: Binding(
                get: { self.model.isProxyAPIKeyAccountSelected(self.option.accountKey) },
                set: { newValue in
                    let isSelected = self.model.isProxyAPIKeyAccountSelected(self.option.accountKey)
                    if newValue != isSelected {
                        self.model.toggleProxyAPIKeyAllowedAccount(self.option.accountKey)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.option.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(self.option.secondaryText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ProxyAPIKeyStaleSelectionBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    let selections: [ProxyAPIKeyStaleSelection]

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.warning)

                Text(self.model.localized(zh: "历史限制需确认", en: "Saved stale restrictions"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }

            Text(self.model.text(.helperProxyAPIKeyStaleSelections))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(self.selections) { selection in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selection.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let secondaryText = selection.secondaryText, !secondaryText.isEmpty {
                                Text(secondaryText)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(palette.textSecondary)
                                    .textSelection(.enabled)
                            }

                            Text(selection.reason)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Button(self.model.localized(zh: "移除", en: "Remove")) {
                            self.model.removeProxyAPIKeyAllowedAccount(selection.accountKey)
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.18 : 0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.warning.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct ProxyAPIKeyUsageRangeSheet: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(self.model.text(.labelTimeRange))
                .font(.system(size: 20, weight: .bold))

            FormFieldPanel(title: self.model.text(.labelFrom)) {
                FixedDateTimeField(
                    value: self.$model.proxyAPIKeyUsageFilter.customFromDate,
                    title: self.model.text(.labelFrom)
                )
            }

            FormFieldPanel(title: self.model.text(.labelTo)) {
                FixedDateTimeField(
                    value: self.$model.proxyAPIKeyUsageFilter.customToDate,
                    title: self.model.text(.labelTo)
                )
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(self.model.text(.commonCancel)) {
                    self.model.isProxyUsageRangePickerPresented = false
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

                Button(self.model.text(.actionApplyNow)) {
                    Task { await self.model.applyProxyAPIKeyUsageCustomRange() }
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 260)
        .compactOverlayScrollbars()
    }
}

struct ProxyOpenAIAccessCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAccessInfo),
            subtitle: self.model.text(.proxyConnectionHint)
        ) {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ProxyAnthropicAccessCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAnthropicAccess),
            subtitle: self.model.text(.helperAnthropicConnection)
        ) {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ProxyGeminiAccessCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionGeminiAccess),
            subtitle: self.model.text(.helperGeminiConnection)
        ) {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ProxyAnthropicMappingCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAnthropicModelMapping),
            subtitle: self.model.text(.helperAnthropicModelMapping)
        ) {
            FormFieldPanel(title: self.model.text(.labelAnthropicDefaultTargetModel)) {
                Picker(
                    self.model.text(.labelAnthropicDefaultTargetModel),
                    selection: self.$model.settings.anthropicDefaultTargetModel
                ) {
                    ForEach(self.targetModelOptions(for: self.model.settings.anthropicDefaultTargetModel), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .dashboardFieldChrome()
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(self.model.settings.anthropicModelMappings.indices), id: \.self) { index in
                    self.mappingRow(index: index)
                }

                Button(self.model.text(.actionAddAnthropicMapping), action: self.addMapping)
                    .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(self.model.text(.helperAnthropicMappingFallback))
                Text(self.model.text(.helperAnthropicOAuthModelFallback))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

            Button(self.model.text(.actionSaveProxySettings), action: self.saveSettings)
                .buttonStyle(AppActionButtonStyle(kind: .primary))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("proxy-anthropic-mapping-card")
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
                text: self.$model.settings.anthropicModelMappings[index].sourceModel
            )
            .textFieldStyle(.plain)
            .dashboardFieldChrome()
        }
    }

    private func targetModelField(index: Int) -> some View {
        FormFieldPanel(title: self.model.text(.labelAnthropicTargetModel)) {
            Picker(
                self.model.text(.labelAnthropicTargetModel),
                selection: self.$model.settings.anthropicModelMappings[index].targetModel
            ) {
                ForEach(self.targetModelOptions(for: self.model.settings.anthropicModelMappings[index].targetModel), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .dashboardFieldChrome()
        }
    }

    private func removeButton(index: Int) -> some View {
        Button(self.model.text(.actionRemoveAnthropicMapping)) {
            self.model.settings.anthropicModelMappings.remove(at: index)
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
    }

    private func addMapping() {
        self.model.settings.anthropicModelMappings.append(
            AnthropicModelMapping(
                targetModel: self.model.settings.anthropicDefaultTargetModel
            )
        )
    }

    private func targetModelOptions(for current: String) -> [String] {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = ProxyTranscoder.supportedModels
        if trimmedCurrent.isEmpty == false, options.contains(trimmedCurrent) == false {
            options.insert(trimmedCurrent, at: 0)
        }
        return options
    }

    private func saveSettings() {
        Task { await self.model.saveSettings() }
    }
}

struct ProxyNetworkSettingsCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionNetworkSettings),
            subtitle: self.model.text(.proxySubtitle)
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    self.hostField
                    self.publicPortField
                    self.adminPortField
                }

                VStack(alignment: .leading, spacing: 12) {
                    self.hostField
                    HStack(alignment: .top, spacing: 12) {
                        self.publicPortField
                        self.adminPortField
                    }
                }
            }

            if self.model.adminCapabilities.allowsLocalFallback {
                FormFieldPanel(title: self.model.text(.labelAutoStart)) {
                    Toggle(self.model.text(.labelAutoStart), isOn: self.$model.settings.autoStart)
                        .toggleStyle(.switch)
                }
            }

            Button(self.model.text(.actionSaveProxySettings), action: self.saveSettings)
                .buttonStyle(AppActionButtonStyle(kind: .primary))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var hostField: some View {
        FormFieldPanel(title: self.model.text(.labelPublicHost)) {
            TextField(self.model.text(.labelPublicHost), text: self.$model.settings.publicHost)
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
        }
    }

    private var publicPortField: some View {
        FormFieldPanel(title: self.model.text(.labelPublicPort)) {
            TextField(self.model.text(.labelPublicPort), value: self.$model.settings.publicPort, formatter: NumberFormatter())
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
        }
    }

    private var adminPortField: some View {
        FormFieldPanel(title: self.model.text(.labelAdminPort)) {
            TextField(self.model.text(.labelAdminPort), value: self.$model.settings.adminPort, formatter: NumberFormatter())
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
        }
    }

    private func saveSettings() {
        Task { await self.model.saveSettings() }
    }
}
#endif
