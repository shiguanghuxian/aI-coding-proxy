#if os(macOS)
import Charts
import CodexProxyCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: DesktopAppModel

    private let metricColumns = [
        GridItem(.adaptive(minimum: 190, maximum: 236), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardTabStrip(
                items: OverviewTab.allCases,
                selection: self.$model.selectedOverviewTab,
                title: { self.model.overviewTabTitle($0) },
                symbol: { $0.symbolName }
            ) {
                OverviewTopUtilityControls(model: self.model)
            }

            Group {
                switch self.model.selectedOverviewTab {
                case .runtime:
                    OverviewControlPanel(model: self.model, metricColumns: self.metricColumns)
                case .traffic:
                    OverviewTrafficCard(model: self.model, metricColumns: self.metricColumns)
                case .recentActivity:
                    OverviewRecentActivityCard(model: self.model)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.18), value: self.model.selectedOverviewTab)
        }
    }
}

private struct OverviewTopUtilityControls: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        HStack(spacing: 8) {
            self.statusPill
            OverviewServiceControls(model: self.model)
        }
    }

    private var statusPill: some View {
        StatusPill(
            text: self.model.shellServiceStatusText,
            tone: self.model.shellServiceStatusTone
        )
    }
}

private struct OverviewServiceControls: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        HStack(spacing: 8) {
            if self.model.localCanStopService || self.model.localServiceOperation == .stopping {
                self.actionButton(
                    title: self.model.localStopButtonTitle,
                    isEnabled: self.model.localCanStopService,
                    isLoading: self.model.localServiceOperation == .stopping,
                    kind: .danger,
                    action: self.stopDaemon
                )
            } else {
                self.actionButton(
                    title: self.model.localStartButtonTitle,
                    isEnabled: self.model.localCanStartService,
                    isLoading: self.model.localServiceOperation == .starting,
                    kind: .primary,
                    action: self.startDaemon
                )
            }
        }
    }

    private func actionButton(
        title: String,
        isEnabled: Bool,
        isLoading: Bool,
        kind: AppActionButtonStyle.Kind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(kind == .danger ? .white : nil)
                }
                Text(title)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(TopBarCompactActionButtonStyle(kind: kind))
        .disabled(!isEnabled || isLoading)
    }

    private func startDaemon() {
        Task { await self.model.startDaemon() }
    }

    private func stopDaemon() {
        Task { await self.model.stopDaemon() }
    }
}

private struct OverviewControlPanel: View {
    @ObservedObject var model: DesktopAppModel

    let metricColumns: [GridItem]

    var body: some View {
        let runtimeTone = self.runtimeTone

        SectionCard(
            title: self.model.text(.sectionRuntime),
            subtitle: self.model.text(.overviewServiceHint),
            accessory: StatusPill(
                text: self.model.shellServiceStatusText,
                tone: self.model.shellServiceStatusTone
            )
        ) {
            LazyVGrid(columns: self.metricColumns, spacing: 12) {
                OverviewRuntimeMetricCard(
                    label: self.model.text(.labelStatus),
                    value: self.model.localServicePrimaryStatusText,
                    subtitle: self.model.localServiceSummaryText,
                    tone: runtimeTone,
                    symbol: "waveform.path.ecg",
                    highlightsStatus: true
                )
                OverviewRuntimeMetricCard(
                    label: self.model.text(.labelAccounts),
                    value: "\(self.model.accounts.count)",
                    subtitle: self.model.text(.sectionAccountPool),
                    tone: .accent,
                    symbol: "person.2.fill"
                )
                OverviewRuntimeMetricCard(
                    label: self.model.text(.labelRequests),
                    value: "\(self.model.stats.totalRequests)",
                    subtitle: self.model.text(.sectionLatestActivity),
                    tone: .neutral,
                    symbol: "bolt.horizontal.fill"
                )
                OverviewRuntimeMetricCard(
                    label: self.model.text(.labelFailures),
                    value: "\(self.model.stats.totalFailures)",
                    subtitle: self.model.text(.labelLastError),
                    tone: self.model.stats.totalFailures > 0 ? .danger : .neutral,
                    symbol: "exclamationmark.triangle.fill"
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    OverviewAccessPanel(model: self.model)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)

                    OverviewRuntimeSummary(model: self.model)
                        .frame(width: 354, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 14) {
                    OverviewAccessPanel(model: self.model)

                    OverviewRuntimeSummary(model: self.model)
                }
            }
        }
    }

    private var runtimeTone: MetricTile.Tone {
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

private struct OverviewAccessPanel: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        OverviewInsetPanel(
            title: self.model.text(.sectionAccessInfo),
            footer: self.model.text(.proxyConnectionHint),
            compact: true
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
            }
        }
    }
}

private struct OverviewRuntimeSummary: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        OverviewInsetPanel(title: self.model.text(.labelProxySummary)) {
            VStack(alignment: .leading, spacing: 2) {
                DetailRow(
                    label: self.model.text(.labelActiveLabel),
                    value: self.model.displayValue(self.model.status?.activeAccountLabel),
                    labelWidth: 92,
                    compact: true
                )
                DetailRow(
                    label: self.model.text(.labelActiveAccount),
                    value: self.model.displayValue(self.model.status?.activeAccountID),
                    labelWidth: 92,
                    compact: true
                )
                DetailRow(
                    label: self.model.text(.labelLastError),
                    value: self.model.displayValue(self.model.status?.lastError),
                    labelWidth: 92,
                    compact: true
                )

                OverviewSummaryInfoBar(text: self.model.text(.overviewDiagnosticsHint), palette: palette)
                    .padding(.top, 10)
            }
        }
    }
}

private struct OverviewInsetPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var footer: String? = nil
    var compact = false
    @ViewBuilder var content: Content

    init(
        title: String,
        footer: String? = nil,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 10 : 12) {
            Text(self.title)
                .font(.system(size: self.compact ? 13.5 : 14, weight: .bold))
                .foregroundStyle(palette.textPrimary)

            self.content

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: self.compact ? 9.5 : 10, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(self.compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct OverviewSummaryInfoBar: View {
    let text: String
    let palette: AppearancePalette

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(self.palette.info)

            Text(self.text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(self.palette.info)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.palette.infoSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(self.palette.infoBorder, lineWidth: 1)
        )
    }
}

private struct OverviewRuntimeMetricCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    let subtitle: String
    let tone: MetricTile.Tone
    let symbol: String
    var highlightsStatus = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colors.iconBackground)
                    Image(systemName: self.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.iconForeground)
                }
                .frame(width: 28, height: 28)

                Text(self.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.value)
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)

                    if self.highlightsStatus {
                        Circle()
                            .fill(colors.line)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(self.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [colors.line, colors.line.opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2.5)
        }
        .padding(14)
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

    private func colors(palette: AppearancePalette) -> (
        background: Color,
        border: Color,
        line: Color,
        iconBackground: Color,
        iconForeground: Color
    ) {
        switch self.tone {
        case .success:
            return (
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.54 : 1.0),
                palette.success.opacity(0.18),
                palette.success,
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.94 : 1.0),
                palette.success
            )
        case .accent:
            return (
                palette.panel,
                palette.accent.opacity(0.14),
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
                palette.accent
            )
        case .danger:
            return (
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.48 : 1.0),
                palette.danger.opacity(0.18),
                palette.danger,
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.94 : 1.0),
                palette.danger
            )
        case .warning:
            return (
                palette.panel,
                palette.warning.opacity(0.16),
                palette.warning,
                palette.warningSoft.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
                palette.warning
            )
        case .neutral:
            return (
                palette.panel,
                palette.border,
                palette.accent,
                palette.panelMuted.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
                palette.info
            )
        }
    }
}

private struct OverviewTrafficCard: View {
    @ObservedObject var model: DesktopAppModel

    let metricColumns: [GridItem]

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionTraffic),
            subtitle: self.model.text(.overviewTrafficHint),
            accessory: StatusPill(text: self.model.text(.sectionTraffic), tone: .accent)
        ) {
            OverviewTrafficAPIKeyFilterBar(model: self.model)

            LazyVGrid(columns: self.metricColumns, spacing: 14) {
                MetricTile(
                    label: self.model.text(.labelInputTokens),
                    value: OverviewNumberFormat.abbreviated(self.model.stats.totalInputTokens),
                    tone: .accent,
                    symbol: "arrow.down.left.circle.fill"
                )
                .help(OverviewNumberFormat.full(self.model.stats.totalInputTokens))

                MetricTile(
                    label: self.model.text(.labelOutputTokens),
                    value: OverviewNumberFormat.abbreviated(self.model.stats.totalOutputTokens),
                    tone: .neutral,
                    symbol: "arrow.up.right.circle.fill"
                )
                .help(OverviewNumberFormat.full(self.model.stats.totalOutputTokens))

                MetricTile(
                    label: self.model.text(.labelRateLimits),
                    value: "\(self.model.stats.totalRateLimits)",
                    tone: self.model.stats.totalRateLimits > 0 ? .warning : .neutral,
                    symbol: "speedometer"
                )
                MetricTile(
                    label: self.model.text(.labelQuotaErrors),
                    value: "\(self.model.stats.totalQuotaFailures)",
                    tone: self.model.stats.totalQuotaFailures > 0 ? .danger : .neutral,
                    symbol: "creditcard.trianglebadge.exclamationmark"
                )
            }

            FormFieldPanel(
                title: self.model.text(.labelNaturalTokenUsage),
                footer: self.model.text(.helperNaturalTokenUsage)
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: self.metricColumns, spacing: 14) {
                        ForEach(self.model.overviewNaturalTokenCards) { card in
                            OverviewNaturalTokenRangeCard(card: card, model: self.model)
                        }
                    }

                    FormFieldPanel(
                        title: self.model.text(.labelRecentFourWeeks),
                        footer: self.model.overviewRecentFourWeeksRangeText
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            if self.model.overviewHasTrafficTrendData {
                                VStack(alignment: .leading, spacing: 14) {
                                    OverviewTrafficWeekSelector(model: self.model)

                                    OverviewTrafficTrendPanel(
                                        model: self.model,
                                        title: self.model.text(.labelDailyTrend),
                                        subtitle: self.model.overviewSelectedRecentWeekOption.rangeText,
                                        points: self.model.overviewSelectedDailyTrendPoints
                                    )

                                    OverviewTrafficTrendPanel(
                                        model: self.model,
                                        title: self.model.text(.labelWeeklyTrend),
                                        subtitle: self.model.overviewRecentFourWeeksRangeText,
                                        points: self.model.overviewWeeklyTrendPoints
                                    )
                                }
                            } else {
                                ContentUnavailableView(
                                    self.model.text(.placeholderNoRecentRequests),
                                    systemImage: "chart.line.downtrend.xyaxis"
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct OverviewTrafficAPIKeyFilterBar: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                self.titleBlock(palette: palette)
                Spacer(minLength: 12)
                self.filterMenu
            }

            VStack(alignment: .leading, spacing: 12) {
                self.titleBlock(palette: palette)
                self.filterMenu
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.9 : 0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .help(self.model.text(.helperOverviewTrafficAPIKeyFilter))
    }

    private func titleBlock(palette: AppearancePalette) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.accentSoft)
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.model.text(.labelOverviewTrafficAPIKeyFilter).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textMuted)

                Text(self.model.overviewTrafficAPIKeyFilterDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button {
                Task { await self.model.selectOverviewTrafficAPIKeyFilter(nil) }
            } label: {
                Label(
                    self.model.text(.optionAllProxyAPIKeys),
                    systemImage: self.model.overviewTrafficSelectedAPIKey == nil ? "checkmark.circle.fill" : "circle"
                )
            }

            if self.model.overviewTrafficAPIKeyOptions.isEmpty == false {
                Divider()
            }

            ForEach(self.model.overviewTrafficAPIKeyOptions) { record in
                Button {
                    Task { await self.model.selectOverviewTrafficAPIKeyFilter(record.id) }
                } label: {
                    Label(
                        self.model.proxyAPIKeyDisplayLabel(record),
                        systemImage: self.model.overviewTrafficAPIKeyFilterIsSelected(record)
                            ? "checkmark.circle.fill"
                            : "key.horizontal"
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(self.model.overviewTrafficAPIKeyFilterTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .menuStyle(.button)
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .accessibilityIdentifier("overview-traffic-api-key-filter-menu")
    }
}

private struct OverviewTrafficWeekSelector: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        QuickActionWrapLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(self.model.overviewRecentWeekOptions) { option in
                Button(option.title) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.model.selectedOverviewTrafficWeekOffset = option.offset
                    }
                }
                .buttonStyle(
                    AppActionButtonStyle(
                        kind: self.model.overviewSelectedRecentWeekOption.offset == option.offset ? .primary : .secondary
                    )
                )
            }
        }
    }
}

private struct OverviewTrafficTrendPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    let title: String
    let subtitle: String
    let points: [OverviewTrafficTrendPoint]

    @State private var hoveredBucketStart: Int64?
    @State private var hiddenSeries: Set<OverviewTrafficTrendSeriesKind> = []

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                Text(self.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }

            OverviewTrafficTrendLegend(
                totalLabel: self.model.text(.labelTotalTokens),
                inputLabel: self.model.text(.labelInputTokens),
                outputLabel: self.model.text(.labelOutputTokens),
                cacheHitLabel: self.model.text(.labelCacheHitTokens),
                cacheMissLabel: self.model.text(.labelCacheMissTokens),
                hiddenSeries: self.$hiddenSeries
            )

            Chart {
                ForEach(OverviewTrafficTrendSeriesKind.allCases.filter { !self.hiddenSeries.contains($0) }) { series in
                    self.seriesMarks(for: series, palette: palette)
                }

                if let hoveredPoint {
                    RuleMark(
                        x: .value("Bucket", hoveredPoint.date)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(palette.border.opacity(self.colorScheme == .dark ? 0.95 : 0.9))
                }
            }
            .frame(minHeight: 248)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: self.points.map(\.date)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(palette.border.opacity(0.45))
                    AxisTick(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(palette.border)
                    AxisValueLabel {
                        if let point = self.axisPoint(for: value) {
                            OverviewTrafficTrendAxisLabel(
                                primaryLabel: point.xAxisPrimaryLabel,
                                secondaryLabel: point.xAxisSecondaryLabel
                            )
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(palette.border.opacity(0.45))
                    AxisTick(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(palette.border)
                    AxisValueLabel {
                        if let yValue = self.axisValue(value) {
                            Text(OverviewNumberFormat.abbreviated(yValue))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrameAnchor = proxy.plotFrame {
                        let plotFrame = geometry[plotFrameAnchor]

                        if plotFrame.width > 0, plotFrame.height > 0 {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: plotFrame.width, height: plotFrame.height)
                                .position(x: plotFrame.midX, y: plotFrame.midY)
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        let nextBucketStart = self.model.overviewHoverBucketStart(
                                            current: self.hoveredBucketStart,
                                            plotX: location.x,
                                            plotWidth: plotFrame.width,
                                            points: self.points
                                        )
                                        if nextBucketStart != self.hoveredBucketStart {
                                            self.hoveredBucketStart = nextBucketStart
                                        }
                                    case .ended:
                                        self.hoveredBucketStart = self.model.overviewHoverBucketStart(
                                            current: self.hoveredBucketStart,
                                            plotX: nil,
                                            plotWidth: plotFrame.width,
                                            points: self.points
                                        )
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    if let hoveredPoint,
                                       let hoveredIndex = self.points.firstIndex(where: { $0.bucketStart == hoveredPoint.bucketStart }),
                                       let hoveredX = self.model.overviewTrendPointXPosition(
                                           at: hoveredIndex,
                                           plotWidth: plotFrame.width,
                                           pointCount: self.points.count
                                       )
                                    {
                                        OverviewTrafficTrendTooltip(
                                            model: self.model,
                                            point: hoveredPoint,
                                            hiddenSeries: self.hiddenSeries
                                        )
                                        .frame(width: 208, alignment: .leading)
                                        .offset(
                                            x: self.tooltipOffset(
                                                for: hoveredX,
                                                plotWidth: plotFrame.width,
                                                tooltipWidth: 208
                                            ),
                                            y: 8
                                        )
                                        .allowsHitTesting(false)
                                    }
                                }
                        }
                    } else {
                        Color.clear
                            .onAppear { self.hoveredBucketStart = nil }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.82 : 0.88))
                    )
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.88 : 0.98),
                            palette.panel.opacity(self.colorScheme == .dark ? 0.86 : 0.95),
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
        .onDisappear {
            self.hoveredBucketStart = nil
        }
    }

    private var hoveredPoint: OverviewTrafficTrendPoint? {
        guard let hoveredBucketStart else { return nil }
        return self.points.first(where: { $0.bucketStart == hoveredBucketStart })
    }

    @ChartContentBuilder
    private func seriesMarks(
        for series: OverviewTrafficTrendSeriesKind,
        palette: AppearancePalette
    ) -> some ChartContent {
        ForEach(self.points) { point in
            self.lineMark(
                for: series,
                point: point,
                color: self.seriesColor(series, palette: palette)
            )
        }

        if let hoveredPoint {
            self.highlightMark(
                for: series,
                point: hoveredPoint,
                color: self.seriesColor(series, palette: palette)
            )
        }
    }

    @ChartContentBuilder
    private func lineMark(
        for series: OverviewTrafficTrendSeriesKind,
        point: OverviewTrafficTrendPoint,
        color: Color
    ) -> some ChartContent {
        if let value = self.value(for: series, point: point) {
            LineMark(
                x: .value("Bucket", point.date),
                y: .value("Tokens", value),
                series: .value("Metric", self.seriesLabel(series))
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: series == .total ? 2.8 : (series == .cacheHit || series == .cacheMiss ? 2.2 : 2.4), lineCap: .round, lineJoin: .round))
            .foregroundStyle(color)
        }
    }

    @ChartContentBuilder
    private func highlightMark(
        for series: OverviewTrafficTrendSeriesKind,
        point: OverviewTrafficTrendPoint,
        color: Color
    ) -> some ChartContent {
        if let value = self.value(for: series, point: point) {
            PointMark(
                x: .value("Bucket", point.date),
                y: .value("Tokens", value)
            )
            .symbolSize(series == .total ? 82 : (series == .cacheHit || series == .cacheMiss ? 56 : 64))
            .foregroundStyle(color)
        }
    }

    private func value(
        for series: OverviewTrafficTrendSeriesKind,
        point: OverviewTrafficTrendPoint
    ) -> Int64? {
        switch series {
        case .total:
            return point.totalTokens
        case .input:
            return point.inputTokens
        case .output:
            return point.outputTokens
        case .cacheHit:
            return point.cacheHitTokens
        case .cacheMiss:
            return point.cacheMissTokens
        }
    }

    private func seriesLabel(_ series: OverviewTrafficTrendSeriesKind) -> String {
        switch series {
        case .total:
            return self.model.text(.labelTotalTokens)
        case .input:
            return self.model.text(.labelInputTokens)
        case .output:
            return self.model.text(.labelOutputTokens)
        case .cacheHit:
            return self.model.text(.labelCacheHitTokens)
        case .cacheMiss:
            return self.model.text(.labelCacheMissTokens)
        }
    }

    private func seriesColor(
        _ series: OverviewTrafficTrendSeriesKind,
        palette: AppearancePalette
    ) -> Color {
        switch series {
        case .total:
            return palette.warning
        case .input:
            return palette.accent
        case .output:
            return palette.success
        case .cacheHit:
            return palette.info
        case .cacheMiss:
            return palette.danger
        }
    }

    private func axisPoint(for value: AxisValue) -> OverviewTrafficTrendPoint? {
        guard let date = value.as(Date.self) else { return nil }
        let bucketStart = Int64(date.timeIntervalSince1970)
        return self.points.first(where: { $0.bucketStart == bucketStart })
    }

    private func tooltipOffset(
        for xPosition: CGFloat,
        plotWidth: CGFloat,
        tooltipWidth: CGFloat
    ) -> CGFloat {
        let centeredOffset = xPosition - (tooltipWidth / 2)
        return min(max(centeredOffset, 0), max(plotWidth - tooltipWidth, 0))
    }

    private func axisValue(_ value: AxisValue) -> Int64? {
        if let intValue = value.as(Int.self) {
            return Int64(intValue)
        }
        if let int64Value = value.as(Int64.self) {
            return int64Value
        }
        if let doubleValue = value.as(Double.self) {
            return Int64(doubleValue.rounded())
        }
        return nil
    }
}

private enum OverviewTrafficTrendSeriesKind: String, CaseIterable, Identifiable {
    case total
    case input
    case output
    case cacheHit
    case cacheMiss

    var id: String { self.rawValue }
}

private struct OverviewTrafficTrendAxisLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let primaryLabel: String
    let secondaryLabel: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(spacing: 2) {
            Text(self.primaryLabel)
                .font(.system(size: 11, weight: .semibold))
                .allowsTightening(true)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(palette.textPrimary)

            Text(self.secondaryLabel)
                .font(.system(size: 10, weight: .medium))
                .allowsTightening(true)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(palette.textSecondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
        .frame(minHeight: 42, alignment: .top)
    }
}

private struct OverviewTrafficTrendTooltip: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let point: OverviewTrafficTrendPoint
    let hiddenSeries: Set<OverviewTrafficTrendSeriesKind>

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.point.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                Text(self.point.detailText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(OverviewTrafficTrendSeriesKind.allCases) { series in
                    if !self.hiddenSeries.contains(series) {
                        self.tooltipMetricRow(for: series, palette: palette)
                    }
                }
            }

            if let requestCount = self.point.requestCount {
                Divider()
                    .overlay(palette.border.opacity(self.colorScheme == .dark ? 0.9 : 1.0))

                HStack(spacing: 8) {
                    Text(self.model.text(.labelRequests))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)

                    Spacer(minLength: 0)

                    Text(self.model.overviewTooltipRequestCountText(requestCount))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(palette.textPrimary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.97 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? 0.26 : 0.12),
            radius: 12,
            x: 0,
            y: 8
        )
    }

    @ViewBuilder
    private func tooltipMetricRow(
        for series: OverviewTrafficTrendSeriesKind,
        palette: AppearancePalette
    ) -> some View {
        let value: Int64? = switch series {
        case .total: self.point.totalTokens
        case .input: self.point.inputTokens
        case .output: self.point.outputTokens
        case .cacheHit: self.point.cacheHitTokens
        case .cacheMiss: self.point.cacheMissTokens
        }
        let label: String = switch series {
        case .total: self.model.text(.labelTotalTokens)
        case .input: self.model.text(.labelInputTokens)
        case .output: self.model.text(.labelOutputTokens)
        case .cacheHit: self.model.text(.labelCacheHitTokens)
        case .cacheMiss: self.model.text(.labelCacheMissTokens)
        }
        let color: Color = switch series {
        case .total: palette.warning
        case .input: palette.accent
        case .output: palette.success
        case .cacheHit: palette.info
        case .cacheMiss: palette.danger
        }

        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textSecondary)

            Spacer(minLength: 0)

            Text(self.model.overviewTooltipTokenText(value))
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
        }
    }
}

private struct OverviewTrafficTrendLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    let totalLabel: String
    let inputLabel: String
    let outputLabel: String
    let cacheHitLabel: String
    let cacheMissLabel: String
    @Binding var hiddenSeries: Set<OverviewTrafficTrendSeriesKind>

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: 14) {
            self.legendItem(series: .total, color: palette.warning, label: self.totalLabel, palette: palette)
            self.legendItem(series: .input, color: palette.accent, label: self.inputLabel, palette: palette)
            self.legendItem(series: .output, color: palette.success, label: self.outputLabel, palette: palette)
            self.legendItem(series: .cacheHit, color: palette.info, label: self.cacheHitLabel, palette: palette)
            self.legendItem(series: .cacheMiss, color: palette.danger, label: self.cacheMissLabel, palette: palette)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func legendItem(
        series: OverviewTrafficTrendSeriesKind,
        color: Color,
        label: String,
        palette: AppearancePalette
    ) -> some View {
        let isHidden = self.hiddenSeries.contains(series)

        Button {
            if isHidden {
                self.hiddenSeries.remove(series)
            } else {
                self.hiddenSeries.insert(series)
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)

                    if isHidden {
                        Image(systemName: "minus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                    }
                }

                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
            }
            .opacity(isHidden ? 0.35 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct OverviewNaturalTokenRangeCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let card: OverviewNaturalTokenCard
    let model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            Text(self.card.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            VStack(alignment: .leading, spacing: 4) {
                Text(self.model.text(.labelTotalTokens).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                Text(OverviewNumberFormat.abbreviated(self.card.totalTokens))
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .help(OverviewNumberFormat.full(self.card.totalTokens))
            }

            VStack(spacing: 0) {
                OverviewNaturalTokenBreakdownRow(
                    label: self.model.text(.labelRequests),
                    valueText: OverviewNumberFormat.full(self.card.requestCount),
                    helpText: OverviewNumberFormat.full(self.card.requestCount),
                    tone: .success,
                    symbol: "arrow.triangle.branch"
                )

                Rectangle()
                    .fill(palette.border.opacity(self.colorScheme == .dark ? 0.78 : 1.0))
                    .frame(height: 1)

                OverviewNaturalTokenBreakdownRow(
                    label: self.model.text(.labelInputTokens),
                    valueText: OverviewNumberFormat.abbreviated(self.card.inputTokens),
                    helpText: OverviewNumberFormat.full(self.card.inputTokens),
                    tone: .accent,
                    symbol: "arrow.down.left.circle.fill"
                )

                Rectangle()
                    .fill(palette.border.opacity(self.colorScheme == .dark ? 0.78 : 1.0))
                    .frame(height: 1)

                OverviewNaturalTokenBreakdownRow(
                    label: self.model.text(.labelOutputTokens),
                    valueText: OverviewNumberFormat.abbreviated(self.card.outputTokens),
                    helpText: OverviewNumberFormat.full(self.card.outputTokens),
                    tone: .neutral,
                    symbol: "arrow.up.right.circle.fill"
                )

                Rectangle()
                    .fill(palette.border.opacity(self.colorScheme == .dark ? 0.78 : 1.0))
                    .frame(height: 1)

                OverviewNaturalTokenBreakdownRow(
                    label: self.model.text(.labelCacheHitTokens),
                    valueText: OverviewNumberFormat.abbreviated(self.card.cacheHitTokens),
                    helpText: OverviewNumberFormat.full(self.card.cacheHitTokens),
                    tone: .warning,
                    symbol: "arrow.down.circle.fill"
                )

                Rectangle()
                    .fill(palette.border.opacity(self.colorScheme == .dark ? 0.78 : 1.0))
                    .frame(height: 1)

                OverviewNaturalTokenBreakdownRow(
                    label: self.model.text(.labelCacheMissTokens),
                    valueText: OverviewNumberFormat.abbreviated(self.card.cacheMissTokens),
                    helpText: OverviewNumberFormat.full(self.card.cacheMissTokens),
                    tone: .neutral,
                    symbol: "xmark.circle.fill"
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.78 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.accent, palette.accent.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.88 : 0.98),
                            palette.panel.opacity(self.colorScheme == .dark ? 0.86 : 0.95),
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

private struct OverviewNaturalTokenBreakdownRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let valueText: String
    let helpText: String
    let tone: MetricTile.Tone
    let symbol: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(colors.background)

                Image(systemName: self.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.foreground)
            }
            .frame(width: 26, height: 26)

            Text(self.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textSecondary)

            Spacer(minLength: 0)

            Text(self.valueText)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .help(self.helpText)
    }

    private func colors(palette: AppearancePalette) -> (foreground: Color, background: Color) {
        switch self.tone {
        case .accent:
            return (palette.accent, palette.accentSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.18))
        case .success:
            return (palette.success, palette.successSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.18))
        case .warning:
            return (palette.warning, palette.warningSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.18))
        case .danger:
            return (palette.danger, palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.18))
        case .neutral:
            return (palette.textSecondary, palette.border.opacity(self.colorScheme == .dark ? 0.92 : 1.0))
        }
    }
}

private struct OverviewRecentActivityCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionLatestActivity),
            subtitle: self.model.text(.proxyConnectionHint),
            accessory: StatusPill(text: "\(self.model.stats.latestBuckets.count)", tone: .neutral)
        ) {
            if self.model.stats.latestBuckets.isEmpty {
                EmptyStatePanel(
                    title: self.model.text(.sectionLatestActivity),
                    detail: self.model.text(.placeholderNoRecentRequests)
                )
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(self.model.stats.latestBuckets.prefix(8)) { bucket in
                        OverviewBucketRow(bucket: bucket, model: self.model)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct OverviewBucketRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let bucket: RequestMetricBucket
    let model: DesktopAppModel

    private let metricColumns = [
        GridItem(.adaptive(minimum: 132, maximum: 176), spacing: 8),
    ]

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.bucket.endpoint)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(self.bucket.model)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                StatusPill(
                    text: self.bucket.failureCount == 0 ? self.model.text(.statusOnline) : self.model.text(.labelFailures),
                    tone: self.bucket.failureCount == 0 ? .success : .warning
                )
            }

            LazyVGrid(columns: self.metricColumns, alignment: .leading, spacing: 8) {
                OverviewBucketMetricPill(
                    label: self.model.text(.labelRequests),
                    value: OverviewNumberFormat.abbreviated(Int64(self.bucket.successCount + self.bucket.failureCount)),
                    helpText: OverviewNumberFormat.full(Int64(self.bucket.successCount + self.bucket.failureCount)),
                    tone: .neutral
                )
                OverviewBucketMetricPill(
                    label: self.model.text(.labelFailures),
                    value: OverviewNumberFormat.abbreviated(Int64(self.bucket.failureCount)),
                    helpText: OverviewNumberFormat.full(Int64(self.bucket.failureCount)),
                    tone: self.bucket.failureCount > 0 ? .danger : .neutral
                )
                OverviewBucketMetricPill(
                    label: self.model.text(.labelInputTokens),
                    value: OverviewNumberFormat.abbreviated(self.bucket.totalInputTokens),
                    helpText: OverviewNumberFormat.full(self.bucket.totalInputTokens),
                    tone: .accent
                )
                OverviewBucketMetricPill(
                    label: self.model.text(.labelOutputTokens),
                    value: OverviewNumberFormat.abbreviated(self.bucket.totalOutputTokens),
                    helpText: OverviewNumberFormat.full(self.bucket.totalOutputTokens),
                    tone: .neutral
                )
            }

            if let error = self.bucket.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.panelMuted.opacity(0.92), palette.panel.opacity(0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct OverviewBucketMetricPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    var helpText: String? = nil
    let tone: MetricTile.Tone

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(self.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(self.value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(colors.foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
        .help(self.helpText ?? self.value)
    }

    private func colors(palette: AppearancePalette) -> (foreground: Color, background: Color, border: Color) {
        switch self.tone {
        case .accent:
            return (
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.34 : 0.72),
                palette.accent.opacity(0.20)
            )
        case .success:
            return (
                palette.success,
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.34 : 0.72),
                palette.success.opacity(0.20)
            )
        case .warning:
            return (
                palette.warning,
                palette.warningSoft.opacity(self.colorScheme == .dark ? 0.34 : 0.72),
                palette.warning.opacity(0.20)
            )
        case .danger:
            return (
                palette.danger,
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.34 : 0.72),
                palette.danger.opacity(0.20)
            )
        case .neutral:
            return (
                palette.textPrimary,
                palette.panel.opacity(self.colorScheme == .dark ? 0.72 : 0.92),
                palette.border
            )
        }
    }
}
#endif
