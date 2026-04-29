#if os(macOS)
import CodexProxyCore
import SwiftUI

struct ManagedProxySummaryMetricsGrid: View {
    @ObservedObject var model: DesktopAppModel
    var showsMixedPort: Bool
    var compact = false

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: self.compact ? 156 : 180,
                    maximum: self.compact ? 220 : 260
                ),
                spacing: self.compact ? 10 : 12
            ),
        ]
    }

    var body: some View {
        LazyVGrid(columns: self.columns, spacing: self.compact ? 10 : 12) {
            MetricTile(
                label: self.model.localizedManagedProxyText(zh: "当前节点", en: "Current Node"),
                value: self.model.managedProxyCurrentNodeText,
                footnote: self.model.localizedManagedProxyText(
                    zh: "当前实际出口节点",
                    en: "Active egress node"
                ),
                tone: .accent,
                symbol: "location.fill",
                compact: self.compact
            )
            MetricTile(
                label: self.model.localizedManagedProxyText(zh: "固定默认节点", en: "Pinned Default"),
                value: self.model.managedProxyPinnedNodeText,
                footnote: self.model.localizedManagedProxyText(
                    zh: "持久保存的默认出口节点",
                    en: "Persisted default egress node"
                ),
                tone: self.model.managedProxySnapshot.pinnedNodeAvailable
                    ? .success
                    : (self.model.managedProxySnapshot.pinnedNodeName == nil ? .neutral : .warning),
                symbol: "pin.fill",
                compact: self.compact
            )
            MetricTile(
                label: self.model.localizedManagedProxyText(zh: "节点数", en: "Node Count"),
                value: self.model.managedProxyNodeCountText,
                footnote: self.model.localizedManagedProxyText(
                    zh: "当前 provider 返回的节点总量",
                    en: "Total nodes returned by the provider"
                ),
                tone: self.model.managedProxySnapshot.nodes.isEmpty ? .warning : .neutral,
                symbol: "list.bullet.rectangle.portrait.fill",
                compact: self.compact
            )
            MetricTile(
                label: self.model.localizedManagedProxyText(zh: "最近更新", en: "Last Updated"),
                value: self.model.managedProxyProviderUpdatedText,
                footnote: self.model.localizedManagedProxyText(
                    zh: "provider 最近刷新时间",
                    en: "Most recent provider refresh time"
                ),
                tone: .neutral,
                symbol: "clock.fill",
                compact: self.compact
            )
            if self.showsMixedPort {
                MetricTile(
                    label: self.model.localizedManagedProxyText(zh: "Mixed Port", en: "Mixed Port"),
                    value: self.model.managedProxySnapshot.mixedPort.map(String.init) ?? self.model.text(.statusNoData),
                    footnote: self.model.localizedManagedProxyText(
                        zh: "daemon 接入 sidecar 的本地端口",
                        en: "Local sidecar ingress used by the daemon"
                    ),
                    tone: .neutral,
                    symbol: "arrow.triangle.branch",
                    compact: self.compact
                )
            }
        }
    }
}

struct ManagedProxyManagerLayoutMetrics: Equatable {
    let isCompact: Bool
    let outerHorizontalPadding: CGFloat
    let outerTopPadding: CGFloat
    let outerBottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let headerSpacing: CGFloat
    let titleFontSize: CGFloat
    let titleAccentWidth: CGFloat
    let pageContentMinHeight: CGFloat
    let runtimeSummaryLineLimit: Int
    let runtimeMetricColumnCount: Int
    let runtimeMetricSpacing: CGFloat
    let runtimeMetricHorizontalPadding: CGFloat
    let runtimeMetricVerticalPadding: CGFloat
    let runtimeMetricLabelFontSize: CGFloat
    let runtimeMetricValueFontSize: CGFloat
    let nodeTableViewportHeight: CGFloat
    let nodeDrawerWidth: CGFloat
    let nodeDrawerScrimOpacity: Double
    let nodeDrawerHeaderSpacing: CGFloat
    let nodeDrawerSummaryPadding: CGFloat
    let nodeDrawerListMinHeight: CGFloat

    init(proxy: GeometryProxy) {
        self.init(
            width: proxy.size.width,
            height: proxy.size.height,
            safeAreaTop: proxy.safeAreaInsets.top,
            safeAreaBottom: proxy.safeAreaInsets.bottom
        )
    }

    init(width: CGFloat, height: CGFloat, safeAreaTop: CGFloat, safeAreaBottom: CGFloat) {
        self.isCompact = width < 1200 || height < 820
        self.outerHorizontalPadding = self.isCompact ? 16 : 22
        self.outerTopPadding = max(self.isCompact ? 12 : 18, safeAreaTop + (self.isCompact ? 4 : 6))
        self.outerBottomPadding = max(self.isCompact ? 16 : 20, safeAreaBottom + (self.isCompact ? 6 : 8))
        self.sectionSpacing = self.isCompact ? 10 : 14
        self.headerSpacing = self.isCompact ? 10 : 12
        self.titleFontSize = self.isCompact ? 26 : 30
        self.titleAccentWidth = self.isCompact ? 148 : 170
        self.pageContentMinHeight = max(height, 0)
        self.runtimeSummaryLineLimit = 2
        self.runtimeMetricColumnCount = width < 1180 ? 1 : 2
        self.runtimeMetricSpacing = self.isCompact ? 8 : 10
        self.runtimeMetricHorizontalPadding = self.isCompact ? 10 : 12
        self.runtimeMetricVerticalPadding = self.isCompact ? 8 : 10
        self.runtimeMetricLabelFontSize = self.isCompact ? 9 : 10
        self.runtimeMetricValueFontSize = self.isCompact ? 16 : 18
        self.nodeTableViewportHeight = min(max(height * 0.36, 240), 360)
        self.nodeDrawerWidth = min(
            max(width * (self.isCompact ? 0.46 : 0.42), 380),
            min(560, max(width - 88, 380))
        )
        self.nodeDrawerScrimOpacity = self.isCompact ? 0.20 : 0.16
        self.nodeDrawerHeaderSpacing = self.isCompact ? 8 : 10
        self.nodeDrawerSummaryPadding = self.isCompact ? 8 : 10
        self.nodeDrawerListMinHeight = max(height * 0.58, self.isCompact ? 360 : 420)
    }
}

private struct ManagedProxyRuntimeMetricTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    let tone: StatusPill.Tone
    let symbol: String
    let layout: ManagedProxyManagerLayoutMetrics

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        VStack(alignment: .leading, spacing: self.layout.isCompact ? 4 : 5) {
            HStack(spacing: 6) {
                Image(systemName: self.symbol)
                    .font(.system(size: self.layout.isCompact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(colors.icon)

                Text(self.label.uppercased())
                    .font(.system(size: self.layout.runtimeMetricLabelFontSize, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Text(self.value)
                .font(.system(size: self.layout.runtimeMetricValueFontSize, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .monospacedDigit()
        }
        .padding(.horizontal, self.layout.runtimeMetricHorizontalPadding)
        .padding(.vertical, self.layout.runtimeMetricVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [colors.backgroundTop, colors.backgroundBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
    }

    private func colors(palette: AppearancePalette) -> (
        backgroundTop: Color,
        backgroundBottom: Color,
        border: Color,
        icon: Color
    ) {
        switch self.tone {
        case .accent:
            return (
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.94 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.accent.opacity(0.20),
                palette.accent
            )
        case .success:
            return (
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.94 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.success.opacity(0.20),
                palette.success
            )
        case .warning:
            return (
                palette.warningSoft.opacity(self.colorScheme == .dark ? 0.94 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.warning.opacity(0.20),
                palette.warning
            )
        case .danger:
            return (
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.94 : 0.98),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.danger.opacity(0.20),
                palette.danger
            )
        case .neutral:
            return (
                palette.panelMuted.opacity(self.colorScheme == .dark ? 0.92 : 0.90),
                palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                palette.border,
                palette.textSecondary
            )
        }
    }
}

private struct ManagedProxyRuntimeMetricsGrid: View {
    @ObservedObject var model: DesktopAppModel
    let layout: ManagedProxyManagerLayoutMetrics

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: self.layout.runtimeMetricSpacing, alignment: .top),
            count: self.layout.runtimeMetricColumnCount
        )
    }

    var body: some View {
        LazyVGrid(columns: self.columns, alignment: .leading, spacing: self.layout.runtimeMetricSpacing) {
            ManagedProxyRuntimeMetricTile(
                label: self.model.localizedManagedProxyText(zh: "当前节点", en: "Current Node"),
                value: self.model.managedProxyCurrentNodeText,
                tone: .accent,
                symbol: "location.fill",
                layout: self.layout
            )

            ManagedProxyRuntimeMetricTile(
                label: self.model.localizedManagedProxyText(zh: "固定默认节点", en: "Pinned Default"),
                value: self.model.managedProxyPinnedNodeText,
                tone: self.model.managedProxySnapshot.pinnedNodeAvailable
                    ? .success
                    : (self.model.managedProxySnapshot.pinnedNodeName == nil ? .neutral : .warning),
                symbol: "pin.fill",
                layout: self.layout
            )

            ManagedProxyRuntimeMetricTile(
                label: self.model.localizedManagedProxyText(zh: "节点数", en: "Node Count"),
                value: self.model.managedProxyNodeCountText,
                tone: self.model.managedProxySnapshot.nodes.isEmpty ? .warning : .neutral,
                symbol: "list.bullet.rectangle.portrait.fill",
                layout: self.layout
            )

            ManagedProxyRuntimeMetricTile(
                label: self.model.localizedManagedProxyText(zh: "最近更新", en: "Last Updated"),
                value: self.model.managedProxyProviderUpdatedText,
                tone: .neutral,
                symbol: "clock.fill",
                layout: self.layout
            )
        }
    }
}

struct ManagedProxyManagerView: View {
    enum PresentationMode {
        case window
        case embedded
    }

    enum EmbeddedScope {
        case full
        case runtime
        case diagnostics
    }

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    var presentationMode: PresentationMode = .window
    var embeddedScope: EmbeddedScope = .full
    var showsEmbeddedHeader = true

    var body: some View {
        GeometryReader { proxy in
            let palette = AppearanceStore.palette(for: self.colorScheme)
            let layout = ManagedProxyManagerLayoutMetrics(proxy: proxy)
            let toastTrailingPadding = layout.outerHorizontalPadding
                + (self.model.isManagedProxyNodesDrawerPresented ? layout.nodeDrawerWidth + 18 : 0)

            ZStack(alignment: .trailing) {
                if self.presentationMode == .window {
                    ShellBackground()
                }

                Group {
                    if self.presentationMode == .window {
                        ScrollView {
                            self.content(palette: palette, layout: layout)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, layout.outerHorizontalPadding)
                                .padding(.top, layout.outerTopPadding)
                                .padding(.bottom, layout.outerBottomPadding)
                                .frame(maxWidth: .infinity, minHeight: layout.pageContentMinHeight, alignment: .topLeading)
                        }
                    } else {
                        self.content(palette: palette, layout: layout)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, layout.outerHorizontalPadding)
                            .padding(.vertical, layout.isCompact ? 12 : 14)
                    }
                }

                if self.model.isManagedProxyNodesDrawerPresented {
                    self.nodesDrawerBackdrop(layout: layout)
                    self.nodesDrawer(palette: palette, layout: layout)
                        .padding(.trailing, layout.outerHorizontalPadding)
                        .padding(.top, layout.outerTopPadding)
                        .padding(.bottom, layout.outerBottomPadding)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if self.presentationMode == .window {
                    ToastStackView(
                        banners: self.model.banners,
                        dismissTitle: self.model.text(.commonDismiss),
                        topPadding: proxy.safeAreaInsets.top + 18,
                        trailingPadding: toastTrailingPadding
                    ) { id in
                        self.model.dismissBanner(id: id)
                    }
                }
            }
        }
        .frame(minWidth: self.presentationMode == .window ? 1060 : nil, minHeight: self.presentationMode == .window ? 680 : nil)
        .animation(.spring(response: 0.26, dampingFraction: 0.88), value: self.model.isManagedProxyNodesDrawerPresented)
        .onChange(of: self.model.isManagedProxyNodesDrawerPresented) { _, isPresented in
            if isPresented {
                self.model.syncManagedProxyFocus()
            }
        }
        .compactOverlayScrollbars()
    }

    @ViewBuilder
    private func content(
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            if self.presentationMode == .window || self.showsEmbeddedHeader {
                self.header(palette: palette, layout: layout)
                    .accessibilityIdentifier("managed-proxy-header")
            } else if self.embeddedScope == .runtime || self.embeddedScope == .full {
                self.embeddedRuntimeActionStrip(palette: palette)
            }

            if self.showsStatusStrip {
                self.statusStrip(layout: layout)
            }

            if self.showsControlsCard {
                self.controlsCard(layout: layout)
            }

            if self.showsListenerPortsCard {
                self.listenerPortsCard(palette: palette, layout: layout)
            }

            if self.showsWebsiteProbeCard {
                self.websiteProbeCard(palette: palette, layout: layout)
            }

            if self.showsLogsCard {
                self.logsCard
            }
        }
    }

    @ViewBuilder
    private func header(palette: AppearancePalette, layout: ManagedProxyManagerLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: layout.headerSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    self.headerTitleBlock(palette: palette, layout: layout)
                    Spacer(minLength: 12)
                    self.headerActions(palette: palette)
                }

                VStack(alignment: .leading, spacing: layout.headerSpacing) {
                    self.headerTitleBlock(palette: palette, layout: layout)
                    self.headerActions(palette: palette)
                }
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.border.opacity(self.colorScheme == .dark ? 0.95 : 0.85))
                    .frame(height: 1)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [palette.accent.opacity(0.92), palette.accent.opacity(0.18)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: layout.titleAccentWidth, height: 3)
            }
        }
    }

    private func headerTitleBlock(
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.model.managedProxyManagerWindowTitle)
                .font(.system(size: layout.titleFontSize, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.managedProxyManagerWindowSubtitle)
                .font(.system(size: layout.isCompact ? 11 : 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headerActions(palette: AppearancePalette) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                self.headerStatusRow(palette: palette)
                self.headerButtons(palette: palette)
            }

            VStack(alignment: .leading, spacing: 8) {
                self.headerStatusRow(palette: palette)
                self.headerButtons(palette: palette)
            }
        }
    }

    private func headerStatusRow(palette: AppearancePalette) -> some View {
        HStack(spacing: 8) {
            StatusPill(
                text: self.model.managedProxyRuntimeStatusText,
                tone: self.model.managedProxyRuntimeTone,
                compact: true
            )

            if self.model.isManagedProxyOperationRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(palette.panelMuted.opacity(0.95)))
                    .overlay(Capsule().stroke(palette.border, lineWidth: 1))
            }
        }
    }

    private func headerButtons(palette: AppearancePalette) -> some View {
        HStack(spacing: 8) {
            Button {
                self.toggleNodesDrawer()
            } label: {
                Label(self.model.managedProxyNodesDrawerTitle, systemImage: "sidebar.right")
            }
            .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))

            Button(self.model.text(.commonReload)) {
                Task { await self.model.refreshManagedProxySnapshot(showLoading: true) }
            }
            .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, compact: true))
            .disabled(self.model.managedProxyOperation == .loading)
        }
    }

    private func embeddedRuntimeActionStrip(palette: AppearancePalette) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                self.headerStatusRow(palette: palette)
                Spacer(minLength: 0)
                self.embeddedRuntimeButtons(palette: palette)
            }

            VStack(alignment: .leading, spacing: 8) {
                self.headerStatusRow(palette: palette)
                self.embeddedRuntimeButtons(palette: palette)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelMuted.opacity(self.colorScheme == .dark ? 0.92 : 0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("managed-proxy-embedded-runtime-strip")
    }

    private func embeddedRuntimeButtons(palette: AppearancePalette) -> some View {
        HStack(spacing: 8) {
            Button {
                self.toggleNodesDrawer()
            } label: {
                Label(self.model.managedProxyNodesDrawerTitle, systemImage: "sidebar.right")
            }
            .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))

            Button(self.model.text(.commonReload)) {
                Task { await self.model.refreshManagedProxySnapshot(showLoading: true) }
            }
            .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, compact: true))
            .disabled(self.model.managedProxyOperation == .loading)
        }
    }

    private var showsStatusStrip: Bool {
        switch self.presentationMode {
        case .window:
            return true
        case .embedded:
            return self.embeddedScope == .runtime || self.embeddedScope == .full
        }
    }

    private var showsControlsCard: Bool {
        switch self.presentationMode {
        case .window:
            return true
        case .embedded:
            return self.embeddedScope == .runtime || self.embeddedScope == .full
        }
    }

    private var showsListenerPortsCard: Bool {
        switch self.presentationMode {
        case .window:
            return true
        case .embedded:
            return self.embeddedScope == .diagnostics || self.embeddedScope == .full
        }
    }

    private var showsWebsiteProbeCard: Bool {
        guard self.model.adminCapabilities.supportsWebsiteProbes else { return false }
        switch self.presentationMode {
        case .window:
            return true
        case .embedded:
            return self.embeddedScope == .diagnostics || self.embeddedScope == .full
        }
    }

    private var showsLogsCard: Bool {
        switch self.presentationMode {
        case .window:
            return true
        case .embedded:
            return self.embeddedScope == .diagnostics || self.embeddedScope == .full
        }
    }

    private func statusStrip(layout: ManagedProxyManagerLayoutMetrics) -> some View {
        SectionCard(
            title: self.model.localizedManagedProxyText(zh: "订阅运行态", en: "Subscription Runtime"),
            accessory: StatusPill(
                text: self.model.managedProxyRuntimeStatusText,
                tone: self.model.managedProxyRuntimeTone,
                compact: true
            ),
            compact: true
        ) {
            VStack(alignment: .leading, spacing: layout.runtimeMetricSpacing) {
                Text(self.model.managedProxyManagerSummaryText)
                    .font(.system(size: layout.isCompact ? 10 : 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(layout.runtimeSummaryLineLimit)
                    .fixedSize(horizontal: false, vertical: true)

                ManagedProxyRuntimeMetricsGrid(model: self.model, layout: layout)
            }
        }
        .accessibilityIdentifier("managed-proxy-status-strip")
    }

    private func controlsCard(layout: ManagedProxyManagerLayoutMetrics) -> some View {
        SectionCard(
            title: self.model.localizedManagedProxyText(zh: "订阅控制", en: "Subscription Controls"),
            subtitle: self.model.localizedManagedProxyText(
                zh: "订阅地址和测速目标分别保存；节点切换、固定默认和节点测速仍在右侧节点抽屉。",
                en: "Save the subscription URL and the health-check target separately here. Current-node switching, pinned defaults, and node health checks stay in the right-side drawer."
            ),
            compact: true
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: layout.isCompact ? 12 : 14) {
                    self.subscriptionControlsGroup(layout: layout)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    self.healthcheckControlsGroup(layout: layout)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: layout.isCompact ? 10 : 12) {
                    self.subscriptionControlsGroup(layout: layout)
                    self.healthcheckControlsGroup(layout: layout)
                }
            }
        }
        .accessibilityIdentifier("managed-proxy-controls-card")
    }

    private func subscriptionControlsGroup(layout: ManagedProxyManagerLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: layout.isCompact ? 10 : 12) {
            self.subscriptionURLField
            self.runtimeControls
        }
    }

    private func healthcheckControlsGroup(layout: ManagedProxyManagerLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: layout.isCompact ? 10 : 12) {
            self.healthcheckURLField
            self.healthcheckControls
        }
    }

    private var subscriptionURLField: some View {
        FormFieldPanel(
            title: self.model.localizedManagedProxyText(zh: "订阅地址", en: "Subscription URL"),
            footer: self.model.localizedManagedProxyText(
                zh: "仅接受有效的 HTTP/HTTPS 绝对地址；内容只保存在本地安全存储。",
                en: "Only valid absolute HTTP/HTTPS URLs are accepted, and the value stays in local secure storage."
            ),
            compact: true
        ) {
            TextField(
                self.model.localizedManagedProxyText(zh: "输入订阅地址", en: "Enter subscription URL"),
                text: self.$model.managedProxySubscriptionURLDraft
            )
            .textFieldStyle(.plain)
            .dashboardFieldChrome()
        }
    }

    private var healthcheckURLField: some View {
        FormFieldPanel(
            title: self.model.localizedManagedProxyText(zh: "测速目标 URL", en: "Healthcheck Target URL"),
            footer: self.model.managedProxyHealthcheckURLFieldFooterText,
            compact: true
        ) {
            TextField(
                self.model.localizedManagedProxyText(zh: "输入测速目标 URL", en: "Enter healthcheck target URL"),
                text: self.$model.managedProxyHealthcheckURLDraft
            )
            .textFieldStyle(.plain)
            .dashboardFieldChrome()
        }
    }

    private var runtimeControls: some View {
        FormFieldPanel(
            title: self.model.localizedManagedProxyText(zh: "订阅操作", en: "Subscription Actions"),
            footer: self.model.managedProxyActionHelperText,
            compact: true
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    self.primaryControlButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.primaryControlButtons
                }
            }
        }
    }

    private var healthcheckControls: some View {
        FormFieldPanel(
            title: self.model.localizedManagedProxyText(zh: "测速目标操作", en: "Healthcheck Target Actions"),
            footer: self.model.managedProxyHealthcheckActionHelperText,
            compact: true
        ) {
            Button(self.model.localizedManagedProxyText(zh: "保存测速目标", en: "Save Healthcheck Target")) {
                Task { await self.model.saveManagedProxyHealthcheckURL() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.model.isManagedProxyOperationRunning || self.model.isBusy)
        }
    }

    private var primaryControlButtons: some View {
        Group {
            Button(self.model.localizedManagedProxyText(zh: "保存并应用", en: "Save & Apply")) {
                Task { await self.model.saveProxySettings() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
            .disabled(self.model.isManagedProxyOperationRunning || self.model.isBusy)

            Button(self.model.localizedManagedProxyText(zh: "更新订阅", en: "Refresh Provider")) {
                Task { await self.model.updateManagedProxySubscription() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(!self.model.managedProxyCanRunRuntimeActions || self.model.isManagedProxyUpdating)
        }
    }

    private func listenerPortsCard(
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        SectionCard(
            title: self.model.localizedManagedProxyText(zh: "监听端口", en: "Listener Ports"),
            subtitle: self.model.localizedManagedProxyText(
                zh: "展示 mihomo 当前全部真实代理监听地址和端口，包括 mixed-port 与已应用的节点 listener。",
                en: "Show every live mihomo proxy listener address and port, including the mixed-port and applied node listeners."
            ),
            compact: true
        ) {
            if self.model.managedProxyListeners.isEmpty {
                EmptyStatePanel(
                    title: self.model.localizedManagedProxyText(zh: "暂无监听端口", en: "No Listener Ports"),
                    detail: self.model.managedProxyListenerEmptyStateText
                )
            } else {
                VStack(alignment: .leading, spacing: layout.isCompact ? 10 : 12) {
                    ForEach(self.model.managedProxyListeners) { listener in
                        self.listenerPortRow(listener, palette: palette)
                    }
                }
            }
        }
        .accessibilityIdentifier("managed-proxy-listener-ports-card")
    }

    private func listenerPortRow(
        _ listener: ManagedProxyListener,
        palette: AppearancePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    self.listenerPortRowHeader(listener, palette: palette)
                    Spacer(minLength: 0)
                    self.listenerPortCopyButton(listener)
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.listenerPortRowHeader(listener, palette: palette)
                    self.listenerPortCopyButton(listener)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    self.listenerPortMetric(
                        label: self.model.localizedManagedProxyText(zh: "地址", en: "Address"),
                        value: self.model.managedProxyListenerAddressText(listener),
                        palette: palette
                    )
                    self.listenerPortMetric(
                        label: self.model.localizedManagedProxyText(zh: "节点", en: "Node"),
                        value: self.model.managedProxyListenerNodeText(listener),
                        palette: palette
                    )
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.listenerPortMetric(
                        label: self.model.localizedManagedProxyText(zh: "地址", en: "Address"),
                        value: self.model.managedProxyListenerAddressText(listener),
                        palette: palette
                    )
                    self.listenerPortMetric(
                        label: self.model.localizedManagedProxyText(zh: "节点", en: "Node"),
                        value: self.model.managedProxyListenerNodeText(listener),
                        palette: palette
                    )
                }
            }

            Text(self.model.managedProxyListenerTerminalCommand(listener))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.panelMuted.opacity(self.colorScheme == .dark ? 0.82 : 0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.78 : 0.86),
                            palette.panel.opacity(self.colorScheme == .dark ? 0.84 : 0.92),
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

    private func listenerPortRowHeader(
        _ listener: ManagedProxyListener,
        palette: AppearancePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.model.managedProxyListenerTitle(listener))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.managedProxyListenerDescription(listener))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listenerPortMetric(
        label: String,
        value: String,
        palette: AppearancePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
    }

    private func listenerPortCopyButton(_ listener: ManagedProxyListener) -> some View {
        Button(self.model.localizedManagedProxyText(zh: "复制终端代理命令", en: "Copy Terminal Proxy Command")) {
            self.model.copyManagedProxyListenerTerminalCommand(listener)
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
    }

    private func nodesDrawerBackdrop(layout: ManagedProxyManagerLayoutMetrics) -> some View {
        Color.black
            .opacity(layout.nodeDrawerScrimOpacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                self.toggleNodesDrawer(forcePresented: false)
            }
            .transition(.opacity)
    }

    private func nodesDrawer(
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        let visibleNodes = self.model.visibleManagedProxyNodes
        let isFiltering = self.model.managedProxyNodeSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let countText = self.model.localizedManagedProxyText(
            zh: isFiltering
                ? "筛选后 \(visibleNodes.count) / \(self.model.managedProxySnapshot.nodes.count) 个节点"
                : "\(visibleNodes.count) 个节点",
            en: isFiltering
                ? "\(visibleNodes.count) of \(self.model.managedProxySnapshot.nodes.count) nodes"
                : "\(visibleNodes.count) nodes"
        )

        return VStack(alignment: .leading, spacing: layout.nodeDrawerHeaderSpacing) {
            VStack(alignment: .leading, spacing: layout.nodeDrawerHeaderSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(self.model.managedProxyNodesDrawerTitle)
                            .font(.system(size: layout.isCompact ? 18 : 20, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        Text(countText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Button {
                        self.toggleNodesDrawer(forcePresented: false)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(TopBarCompactActionButtonStyle(kind: .secondary))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        self.drawerHealthcheckButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        self.drawerHealthcheckButtons
                    }
                }

                if let feedbackText = self.model.managedProxyHealthcheckFeedbackText {
                    self.drawerHealthcheckFeedback(feedbackText, palette: palette)
                }

                TextField(
                    self.model.localizedManagedProxyText(zh: "输入节点名或协议类型", en: "Filter by node name or protocol"),
                    text: self.$model.managedProxyNodeSearchQuery
                )
                .textFieldStyle(.plain)
                .dashboardFieldChrome()

                if let focusedNode = self.model.managedProxyFocusedNode, visibleNodes.isEmpty == false {
                    self.focusedNodeSummaryRow(node: focusedNode, palette: palette, layout: layout)
                } else {
                    EmptyStatePanel(
                        title: self.model.localizedManagedProxyText(zh: "暂无可显示节点", en: "No Nodes to Display"),
                        detail: self.drawerEmptyNodesDetail
                    )
                }
            }

            if visibleNodes.isEmpty {
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleNodes) { node in
                            self.nodesDrawerRow(node: node, palette: palette, layout: layout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minHeight: layout.nodeDrawerListMinHeight, alignment: .topLeading)
                .layoutPriority(1)
                .accessibilityIdentifier("managed-proxy-drawer-node-list")
            }
        }
        .padding(layout.isCompact ? 16 : 18)
        .frame(width: layout.nodeDrawerWidth)
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
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? 0.32 : 0.12),
            radius: 20,
            x: -8,
            y: 12
        )
    }

    private var drawerHealthcheckButtons: some View {
        Group {
            Button(self.model.localizedManagedProxyText(zh: "测速当前节点", en: "Check Current")) {
                Task { await self.model.healthcheckCurrentManagedProxyNode() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(!self.model.canHealthcheckCurrentManagedProxyNode)
            .accessibilityIdentifier("managed-proxy-drawer-check-current")

            Button(self.model.localizedManagedProxyText(zh: "全量测速", en: "Check All")) {
                Task { await self.model.healthcheckAllManagedProxyNodes() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(!self.model.canHealthcheckAllManagedProxyNodes)
            .accessibilityIdentifier("managed-proxy-drawer-check-all")
        }
    }

    private func drawerHealthcheckFeedback(
        _ text: String,
        palette: AppearancePalette
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            StatusPill(
                text: self.model.localizedManagedProxyText(zh: "测速结果", en: "Latest"),
                tone: self.model.managedProxyHealthcheckFeedbackTone,
                compact: true
            )

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.panelMuted.opacity(self.colorScheme == .dark ? 0.86 : 0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border.opacity(0.8), lineWidth: 1)
        )
        .accessibilityIdentifier("managed-proxy-drawer-healthcheck-feedback")
    }

    private func focusedNodeSummaryRow(
        node: ManagedProxyNode,
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        HStack(alignment: .center, spacing: layout.isCompact ? 8 : 10) {
            Text(node.name)
                .font(.system(size: layout.isCompact ? 13 : 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            self.nodeRolePills(node)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)

            StatusPill(
                text: self.model.managedProxyNodeAvailabilityText(node),
                tone: self.model.managedProxyNodeAvailabilityTone(node),
                compact: true
            )

            Text(self.model.managedProxyNodeDelayText(node))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(self.summaryValueColor(for: self.model.managedProxyNodeDelayTone(node), palette: palette))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, layout.isCompact ? 2 : 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("managed-proxy-drawer-focused-node-summary")
    }

    private func nodesDrawerRow(
        node: ManagedProxyNode,
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        let isFocused = self.model.managedProxyFocusedNode?.name == node.name
        let tint = AppearanceStore.palette(for: self.colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        Text(node.type.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }

                    self.nodeRolePills(node)

                    StatusPill(
                        text: self.model.managedProxyNodeAvailabilityText(node),
                        tone: self.model.managedProxyNodeAvailabilityTone(node),
                        compact: true
                    )
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(self.model.localizedManagedProxyText(zh: "延迟", en: "Latency"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                        .textCase(.uppercase)
                    Text(self.model.managedProxyNodeDelayText(node))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(self.summaryValueColor(for: self.model.managedProxyNodeDelayTone(node), palette: palette))
                        .lineLimit(1)
                    Text(self.model.managedProxyNodeLastHealthcheckText(node))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    self.nodeActionButtons(node, tint: tint)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.nodeActionButtons(node, tint: tint)
                }
            }
        }
        .padding(layout.isCompact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isFocused
                            ? [
                                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.92 : 0.98),
                                palette.panel.opacity(self.colorScheme == .dark ? 0.90 : 0.95),
                            ]
                            : [
                                palette.panelMuted.opacity(self.colorScheme == .dark ? 0.78 : 0.86),
                                palette.panel.opacity(self.colorScheme == .dark ? 0.84 : 0.92),
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isFocused ? palette.accent.opacity(0.28) : palette.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            self.model.focusManagedProxyNode(node.name)
        }
    }

    @ViewBuilder
    private func nodeRolePills(_ node: ManagedProxyNode) -> some View {
        HStack(spacing: 6) {
            if node.isCurrent {
                StatusPill(
                    text: self.model.localizedManagedProxyText(zh: "当前", en: "Current"),
                    tone: .accent,
                    compact: true
                )
            }
            if node.isPinned {
                StatusPill(
                    text: self.model.localizedManagedProxyText(zh: "固定默认", en: "Pinned Default"),
                    tone: self.model.managedProxySnapshot.pinnedNodeAvailable ? .success : .warning,
                    compact: true
                )
            }
            if !node.isCurrent && !node.isPinned {
                Text(self.model.localizedManagedProxyText(zh: "候选", en: "Candidate"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func nodeActionButtons(
        _ node: ManagedProxyNode,
        tint: AppearancePalette
    ) -> some View {
        Button(self.model.managedProxyNodeSwitchCurrentTitle(node)) {
            self.model.focusManagedProxyNode(node.name)
            Task { await self.model.switchManagedProxyCurrentNode(node.name) }
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: tint.accent, compact: true))
        .disabled(!self.model.managedProxyCanSwitchCurrentNode(node))

        Button(self.model.managedProxyNodePinnedActionTitle(node)) {
            self.model.focusManagedProxyNode(node.name)
            Task { await self.model.updateManagedProxyPinnedNode(node.isPinned ? nil : node.name) }
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: tint.success, compact: true))
        .disabled(!self.model.managedProxyCanUpdatePinnedNode(node))

        Button(self.model.localizedManagedProxyText(zh: "测速", en: "Check")) {
            self.model.focusManagedProxyNode(node.name)
            Task { await self.model.healthcheckManagedProxy(nodeName: node.name) }
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: tint.textSecondary, compact: true))
        .disabled(
            !self.model.managedProxyCanRunRuntimeActions
                || self.model.isManagedProxyHealthchecking(node.name)
        )
    }

    private func summaryValueColor(
        for tone: StatusPill.Tone,
        palette: AppearancePalette
    ) -> Color {
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
            return palette.textPrimary
        }
    }

    private var drawerEmptyNodesDetail: String {
        let query = self.model.managedProxyNodeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty == false, self.model.managedProxySnapshot.nodes.isEmpty == false {
            return self.model.localizedManagedProxyText(
                zh: "没有匹配当前筛选条件的节点，请调整关键词后再试。",
                en: "No nodes match the current filter. Adjust the keyword and try again."
            )
        }
        return self.emptyNodesDetail
    }

    private func toggleNodesDrawer(forcePresented: Bool? = nil) {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            let shouldPresent = forcePresented ?? !self.model.isManagedProxyNodesDrawerPresented
            if shouldPresent {
                self.model.presentManagedProxyNodesDrawer()
            } else {
                self.model.dismissManagedProxyNodesDrawer()
            }
        }
    }

    private var emptyNodesDetail: String {
        if self.model.managedProxySnapshot.subscriptionConfigured == false {
            return self.model.localizedManagedProxyText(
                zh: "先保存一个有效的订阅地址，然后点击“更新订阅”加载节点。",
                en: "Save a valid subscription URL first, then refresh the provider to load nodes."
            )
        }
        if self.model.status?.running != true {
            return self.model.localizedManagedProxyText(
                zh: "启动本地服务后，才可以加载节点和执行测速。",
                en: "Start the local service before loading nodes and running health checks."
            )
        }
        return self.model.localizedManagedProxyText(
            zh: "provider 暂时没有返回节点，请尝试更新订阅或查看日志定位问题。",
            en: "The provider is not returning nodes yet. Refresh the provider or inspect the logs for details."
        )
    }

    private func websiteProbeCard(
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        SectionCard(
            title: self.model.localizedManagedProxyText(zh: "网站连通性测试", en: "Website Connectivity Probes"),
            subtitle: self.model.localizedManagedProxyText(
                zh: "第一项会测试当前保存的统一测速目标，后面保留 4 个固定站点；全部只会走本地 mihomo mixed-port。",
                en: "The first row probes the saved unified health-check target, followed by four fixed sites. Every probe only uses the local mihomo mixed-port."
            ),
            compact: true
        ) {
            VStack(alignment: .leading, spacing: layout.isCompact ? 10 : 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        self.websiteProbeStatusSummary(palette: palette)
                        Spacer(minLength: 0)
                        self.websiteProbeRunAllButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        self.websiteProbeStatusSummary(palette: palette)
                        self.websiteProbeRunAllButton
                    }
                }

                if let unavailableReason = self.model.managedProxyWebsiteProbeUnavailableReason {
                    self.websiteProbeDisabledNotice(reason: unavailableReason, palette: palette)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(self.model.managedProxyWebsiteProbeTargets) { target in
                        self.websiteProbeRow(target: target, palette: palette, layout: layout)
                    }
                }
                .opacity(self.model.canRunManagedProxyWebsiteProbes ? 1 : 0.68)
            }
        }
    }

    private func websiteProbeStatusSummary(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.model.managedProxyWebsiteProbeLastBatchText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)

            Text(
                self.model.localizedManagedProxyText(
                    zh: "成功不会弹额外提示，结果会直接更新在每一行。",
                    en: "Successful probes stay inline and update directly in each row."
                )
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(palette.textMuted)
            .lineLimit(2)
        }
    }

    private var websiteProbeRunAllButton: some View {
        Button(
            self.model.isManagedProxyWebsiteProbeBatchRunning
                ? self.model.localizedManagedProxyText(zh: "测试中…", en: "Testing…")
                : self.model.localizedManagedProxyText(zh: "全部测试", en: "Run All")
        ) {
            Task { await self.model.runAllManagedProxyWebsiteProbes() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(!self.model.canRunManagedProxyWebsiteProbes || self.model.isManagedProxyWebsiteProbeBatchRunning)
    }

    private func websiteProbeDisabledNotice(
        reason: String,
        palette: AppearancePalette
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.warning)

            Text(reason)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.70 : 0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.warning.opacity(0.28), lineWidth: 1)
        )
    }

    private func websiteProbeRow(
        target: ManagedProxyWebsiteProbeTarget,
        palette: AppearancePalette,
        layout: ManagedProxyManagerLayoutMetrics
    ) -> some View {
        let isRunning = self.model.managedProxyWebsiteProbeState(for: target) == .running

        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    self.websiteProbeRowHeader(target: target, palette: palette)
                    Spacer(minLength: 0)
                    StatusPill(
                        text: self.model.managedProxyWebsiteProbeStatusText(target),
                        tone: self.model.managedProxyWebsiteProbeTone(target),
                        compact: true
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.websiteProbeRowHeader(target: target, palette: palette)
                    StatusPill(
                        text: self.model.managedProxyWebsiteProbeStatusText(target),
                        tone: self.model.managedProxyWebsiteProbeTone(target),
                        compact: true
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    self.websiteProbeMetric(label: self.model.localizedManagedProxyText(zh: "HTTP", en: "HTTP"), value: self.model.managedProxyWebsiteProbeHTTPStatusText(target), palette: palette)
                    self.websiteProbeMetric(label: self.model.localizedManagedProxyText(zh: "耗时", en: "Latency"), value: self.model.managedProxyWebsiteProbeLatencyText(target), palette: palette)
                    self.websiteProbeMetric(label: self.model.localizedManagedProxyText(zh: "最近测试", en: "Last Checked"), value: self.model.managedProxyWebsiteProbeTestedAtText(target), palette: palette)
                    Spacer(minLength: 0)
                    self.websiteProbeRetryButton(target: target, isRunning: isRunning)
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.websiteProbeMetric(label: self.model.localizedManagedProxyText(zh: "HTTP", en: "HTTP"), value: self.model.managedProxyWebsiteProbeHTTPStatusText(target), palette: palette)
                    self.websiteProbeMetric(label: self.model.localizedManagedProxyText(zh: "耗时", en: "Latency"), value: self.model.managedProxyWebsiteProbeLatencyText(target), palette: palette)
                    self.websiteProbeMetric(label: self.model.localizedManagedProxyText(zh: "最近测试", en: "Last Checked"), value: self.model.managedProxyWebsiteProbeTestedAtText(target), palette: palette)
                    self.websiteProbeRetryButton(target: target, isRunning: isRunning)
                }
            }

            Text(self.model.managedProxyWebsiteProbeDetailText(target))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
        }
        .padding(layout.isCompact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.78 : 0.86),
                            palette.panel.opacity(self.colorScheme == .dark ? 0.84 : 0.92),
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

    private func websiteProbeRowHeader(
        target: ManagedProxyWebsiteProbeTarget,
        palette: AppearancePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.model.managedProxyWebsiteProbeDisplayName(target))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.managedProxyWebsiteProbeHostText(target))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
        }
    }

    private func websiteProbeMetric(
        label: String,
        value: String,
        palette: AppearancePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
    }

    private func websiteProbeRetryButton(
        target: ManagedProxyWebsiteProbeTarget,
        isRunning: Bool
    ) -> some View {
        Button(
            isRunning
                ? self.model.localizedManagedProxyText(zh: "测试中…", en: "Running…")
                : self.model.localizedManagedProxyText(zh: "重试", en: "Retry")
        ) {
            Task { await self.model.runManagedProxyWebsiteProbe(target) }
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: AppearanceStore.palette(for: self.colorScheme).accent, compact: true))
        .disabled(!self.model.canRunManagedProxyWebsiteProbes || isRunning)
    }

    private var logsCard: some View {
        SectionCard(
            title: self.model.localizedManagedProxyText(zh: "代理内核日志", en: "Mihomo Logs"),
            subtitle: self.model.localizedManagedProxyText(
                zh: "默认折叠；只有排障时再展开查看即可。",
                en: "Collapsed by default. Expand only when you need runtime diagnostics."
            ),
            compact: true
        ) {
            DisclosureGroup(
                isExpanded: self.$model.isManagedProxyLogsExpanded,
                content: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(self.model.localizedManagedProxyText(zh: "加载日志", en: "Load Logs")) {
                                Task { await self.model.loadManagedProxyLogs() }
                            }
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                            .disabled(self.model.managedProxyOperation == .loadingLogs)

                            Spacer(minLength: 0)
                        }

                        FormFieldPanel(
                            title: self.model.localizedManagedProxyText(zh: "日志输出", en: "Logs"),
                            compact: true
                        ) {
                            ScrollView {
                                Text(
                                    self.model.managedProxyLogs.isEmpty
                                        ? self.model.localizedManagedProxyText(
                                            zh: "暂无 mihomo 日志，点击上方按钮手动加载。",
                                            en: "No mihomo logs loaded yet. Use the button above to fetch them."
                                        )
                                        : self.model.managedProxyLogs
                                )
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(12)
                            }
                            .frame(minHeight: 200, maxHeight: 260)
                            .background(Color.clear)
                            .dashboardFieldChrome()
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    HStack {
                        Text(
                            self.model.localizedManagedProxyText(
                                zh: self.model.isManagedProxyLogsExpanded ? "收起日志" : "展开日志",
                                en: self.model.isManagedProxyLogsExpanded ? "Hide Logs" : "Show Logs"
                            )
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        if self.model.managedProxyLogs.isEmpty == false {
                            Text(self.model.localizedManagedProxyText(zh: "已加载", en: "Loaded"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            )
            .disclosureGroupStyle(.automatic)
        }
        .accessibilityIdentifier("managed-proxy-logs-card")
    }
}
#endif
