#if os(macOS)
import CodexProxyCore
import SwiftUI

struct RequestLogsView: View {
    enum PresentationMode {
        case window
        case embedded
    }

    struct EmbeddedDisplay {
        var showsHeader = true
        var usesControlsDisclosure = false

        static let standard = Self()
        static let remoteAdmin = Self(showsHeader: false, usesControlsDisclosure: true)
    }

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    var presentationMode: PresentationMode = .window
    var embeddedDisplay: EmbeddedDisplay = .standard

    @State private var isEmbeddedControlsExpanded = false
    @State private var hasInitializedEmbeddedControls = false

    var body: some View {
        GeometryReader { proxy in
            let palette = AppearanceStore.palette(for: self.colorScheme)
            let layout = RequestLogsLayoutMetrics(proxy: proxy)

            ZStack {
                if self.presentationMode == .window {
                    ShellBackground()
                }

                VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                    if self.presentationMode == .window || self.embeddedDisplay.showsHeader {
                        self.header(palette: palette, layout: layout)
                    }

                    if self.usesControlsDisclosure {
                        self.embeddedControlsDisclosure(layout: layout)
                    } else {
                        self.filtersCard(layout: layout)
                    }

                    self.tableCard(layout: layout, showsToolbar: !self.usesControlsDisclosure)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, layout.outerHorizontalPadding)
                .padding(.bottom, layout.outerBottomPadding)
                .padding(.top, layout.outerTopPadding)
            }
            .overlay(alignment: .topTrailing) {
                ToastStackView(
                    banners: self.model.requestLogsBanners,
                    dismissTitle: self.model.text(.commonDismiss),
                    topPadding: proxy.safeAreaInsets.top + 18,
                    trailingPadding: layout.outerHorizontalPadding
                ) { id in
                    self.model.dismissRequestLogsBanner(id: id)
                }
            }
        }
        .frame(minWidth: self.presentationMode == .window ? 1200 : nil, minHeight: 760)
        .compactOverlayScrollbars()
        .sheet(isPresented: self.$model.isDiagnosticRequestBodyPresented) {
            DiagnosticRequestBodyDetailSheet(model: self.model)
        }
    }

    private var usesControlsDisclosure: Bool {
        self.presentationMode == .embedded && self.embeddedDisplay.usesControlsDisclosure
    }

    @ViewBuilder
    private func header(palette: AppearancePalette, layout: RequestLogsLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: layout.headerSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    self.headerTitleBlock(palette: palette, layout: layout)
                    Spacer(minLength: 12)
                    self.headerActions(palette: palette, layout: layout)
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.headerTitleBlock(palette: palette, layout: layout)
                    self.headerActions(palette: palette, layout: layout)
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
                    .frame(width: layout.isCompact ? 132 : 164, height: 3)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityIdentifier("request-logs-header")
    }

    private func headerTitleBlock(palette: AppearancePalette, layout: RequestLogsLayoutMetrics) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(self.model.text(.requestLogsTitle))
                .font(.system(size: layout.titleFontSize, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)

            RequestLogsInfoGlyph(helpText: self.model.text(.requestLogsSubtitle))
        }
    }

    private func headerActions(palette: AppearancePalette, layout: RequestLogsLayoutMetrics) -> some View {
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
        HStack(spacing: 10) {
            StatusPill(
                text: self.model.requestLogsStatusText,
                tone: self.model.requestLogsStatusTone
            )

            if self.model.requestLogsIsRefreshing || self.model.requestLogsIsExporting {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(palette.panelMuted.opacity(0.95)))
                    .overlay(Capsule().stroke(palette.border, lineWidth: 1))
            }
        }
    }

    private func headerButtons(palette: AppearancePalette) -> some View {
        HStack(spacing: 8) {
            Button(self.model.text(.commonReload)) {
                self.model.scheduleRequestLogsRefresh()
            }
            .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent))
        }
    }

    private func embeddedControlsDisclosure(layout: RequestLogsLayoutMetrics) -> some View {
        RequestLogsPanel(
            title: self.model.localized(zh: "筛选与导出", en: "Filters & Export"),
            subtitle: self.model.localized(
                zh: "默认收起；需要调整筛选、排序或导出范围时再展开。",
                en: "Collapsed by default. Expand only when you need to adjust filters, sort order, or export scope."
            ),
            compact: true
        ) {
            DisclosureGroup(
                isExpanded: self.$isEmbeddedControlsExpanded,
                content: {
                    VStack(alignment: .leading, spacing: layout.cardContentSpacing) {
                        self.filtersCard(layout: layout)
                        self.tableToolbar(layout: layout)
                    }
                    .padding(.top, 8)
                },
                label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 8) {
                            self.embeddedControlsDisclosureLabel

                            if self.model.requestLogsHasPendingFilterChanges {
                                self.pendingFiltersHint
                            }

                            Spacer(minLength: 0)

                            StatusPill(
                                text: self.model.requestLogsStatusText,
                                tone: self.model.requestLogsStatusTone,
                                compact: true
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            self.embeddedControlsDisclosureLabel

                            HStack(spacing: 8) {
                                if self.model.requestLogsHasPendingFilterChanges {
                                    self.pendingFiltersHint
                                }

                                StatusPill(
                                    text: self.model.requestLogsStatusText,
                                    tone: self.model.requestLogsStatusTone,
                                    compact: true
                                )
                            }
                        }
                    }
                }
            )
            .accessibilityIdentifier("request-logs-embedded-controls-disclosure")
            .onAppear {
                self.initializeEmbeddedControlsDisclosureIfNeeded()
            }
            .onChange(of: self.shouldAutoExpandEmbeddedControls) { _, shouldExpand in
                if shouldExpand {
                    self.isEmbeddedControlsExpanded = true
                }
            }
        }
        .accessibilityIdentifier("request-logs-embedded-controls-panel")
    }

    private func filtersCard(layout: RequestLogsLayoutMetrics) -> some View {
        RequestLogsPanel(
            title: self.model.text(.sectionRequestLogFilters),
            subtitle: self.model.text(.requestLogsFilterHint),
            compact: true
        ) {
            VStack(alignment: .leading, spacing: layout.cardContentSpacing) {
                if self.model.requestLogsDraftFilterState.timePreset == .custom {
                    self.customFiltersContent
                } else {
                    self.standardFiltersContent
                }
            }
        }
        .accessibilityIdentifier("request-logs-filters-card")
    }

    private var embeddedControlsDisclosureLabel: some View {
        Text(
            self.model.localized(
                zh: self.isEmbeddedControlsExpanded ? "收起筛选与导出" : "展开筛选与导出",
                en: self.isEmbeddedControlsExpanded ? "Hide Filters & Export" : "Show Filters & Export"
            )
        )
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private var queryButton: some View {
        Button(self.model.text(.actionQueryRequestLogs)) {
            self.model.applyRequestLogsFiltersAndRefresh()
        }
        .buttonStyle(RequestLogsCompactButtonStyle(kind: .primary))
        .disabled(self.model.requestLogsIsRefreshing)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var pendingFiltersHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 10, weight: .semibold))

            Text(self.model.text(.requestLogsPendingFiltersCompactHint))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).warning)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(AppearanceStore.palette(for: self.colorScheme).warning.opacity(self.colorScheme == .dark ? 0.16 : 0.12))
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var standardFiltersContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                self.standardFilterFields
                    .frame(maxWidth: .infinity, alignment: .leading)
                self.standardFilterActions
            }

            VStack(alignment: .leading, spacing: 8) {
                self.standardFilterFields
                self.standardFilterActions
            }
        }
    }

    private var customFiltersContent: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    self.customPrimaryFilterFields
                        .frame(maxWidth: .infinity, alignment: .leading)
                    self.queryButton
                }

                HStack(alignment: .center, spacing: 10) {
                    self.fromField
                    self.toField
                    if self.model.requestLogsHasPendingFilterChanges {
                        self.pendingFiltersHint
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                self.customPrimaryFilterFields

                HStack(alignment: .center, spacing: 10) {
                    self.fromField
                    self.toField
                }

                HStack(alignment: .center, spacing: 8) {
                    if self.model.requestLogsHasPendingFilterChanges {
                        self.pendingFiltersHint
                    }
                    Spacer(minLength: 0)
                    self.queryButton
                }
            }
        }
    }

    private var standardFilterFields: some View {
        HStack(alignment: .center, spacing: 10) {
            self.timePresetField
            self.clientSourceField
            self.apiKeyField
            self.accountLabelField
            self.modelField
        }
    }

    private var standardFilterActions: some View {
        HStack(alignment: .center, spacing: 8) {
            if self.model.requestLogsHasPendingFilterChanges {
                self.pendingFiltersHint
            }
            self.queryButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var customPrimaryFilterFields: some View {
        HStack(alignment: .center, spacing: 10) {
            self.timePresetField
            self.clientSourceField
            self.apiKeyField
            self.accountLabelField
            self.modelField
        }
    }

    private func tableCard(
        layout: RequestLogsLayoutMetrics,
        showsToolbar: Bool
    ) -> some View {
        RequestLogsPanel(
            title: self.model.text(.sectionRequestLogs),
            subtitle: self.model.text(.requestLogsTableHint),
            accessory: StatusPill(
                text: self.model.requestLogsSummaryText,
                tone: self.model.requestLogsStatusTone
            ),
            compact: true
        ) {
            VStack(alignment: .leading, spacing: layout.cardContentSpacing) {
                if showsToolbar {
                    self.tableToolbar(layout: layout)
                }

                ZStack {
                    self.tableContent(layout: layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    if self.model.requestLogPage.entries.isEmpty && self.model.requestLogsIsRefreshing == false {
                        ContentUnavailableView(
                            self.model.text(.placeholderNoRequestLogs),
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(self.model.text(.requestLogsEmptyHint))
                        )
                        .frame(maxWidth: .infinity, minHeight: layout.minimumTableViewportHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minHeight: layout.minimumTableViewportHeight)

                self.tableFooter(layout: layout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("request-logs-table-card")
    }

    @ViewBuilder
    private func tableToolbar(layout: RequestLogsLayoutMetrics) -> some View {
        if layout.isCompact {
            VStack(alignment: .leading, spacing: 8) {
                self.sortControls
                self.tableToolbarActions
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    self.sortControls

                    Spacer(minLength: 0)
                    self.tableToolbarActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    self.sortControls
                    HStack(alignment: .center, spacing: 8) {
                        self.tableToolbarActions
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var sortControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                self.sortFieldPicker
                self.sortDirectionButton
            }

            VStack(alignment: .leading, spacing: 6) {
                self.sortFieldPicker
                self.sortDirectionButton
            }
        }
    }

    private var sortFieldPicker: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelSortBy),
            minWidth: 220,
            idealWidth: 220,
            maxWidth: 240
        ) {
            Picker(
                self.model.text(.labelSortBy),
                selection: Binding(
                    get: { self.model.requestLogsDraftFilterState.sortBy },
                    set: { self.model.setRequestLogsSortField($0) }
                )
            ) {
                ForEach(RequestLogSortField.allCases, id: \.self) { field in
                    Text(self.model.label(for: field)).tag(field)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .requestLogsCompactFieldChrome()
        }
    }

    private var sortDirectionButton: some View {
        Button {
            self.model.toggleRequestLogsSortDirection()
        } label: {
            Label(
                self.model.label(for: self.model.requestLogsDraftFilterState.sortDirection),
                systemImage: self.model.requestLogsDraftFilterState.sortDirection == .descending ? "arrow.down" : "arrow.up"
            )
        }
        .buttonStyle(RequestLogsCompactButtonStyle(kind: .secondary, tint: AppearanceStore.palette(for: self.colorScheme).accent))
        .help(self.model.text(.labelSortDirection))
    }

    private var tableToolbarActions: some View {
        HStack(spacing: 8) {
            Button(self.model.text(.actionExportRequestLogs)) {
                Task { await self.model.exportRequestLogs() }
            }
            .buttonStyle(RequestLogsCompactButtonStyle(kind: .secondary))
            .disabled(!self.model.requestLogsCanExport)
        }
    }

    @ViewBuilder
    private func tableFooter(layout: RequestLogsLayoutMetrics) -> some View {
        if layout.isCompact {
            VStack(alignment: .leading, spacing: 10) {
                self.summaryRow
                self.lastRefreshRow
                self.paginationButtons
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    self.summaryRow
                    Spacer(minLength: 10)
                    self.lastRefreshRow
                    self.paginationButtons
                }

                VStack(alignment: .leading, spacing: 10) {
                    self.summaryRow
                    HStack(alignment: .center, spacing: 12) {
                        self.lastRefreshRow
                        Spacer(minLength: 0)
                        self.paginationButtons
                    }
                }
            }
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusPill(
                text: self.model.text(.labelFilteredResults),
                tone: .neutral
            )

            Text(self.model.requestLogsSummaryText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastRefreshRow: some View {
        Text("\(self.model.text(.labelLastRefreshed)): \(self.model.requestLogsLastRefreshedText)")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var paginationButtons: some View {
        HStack(spacing: 8) {
            Button(self.model.text(.actionPreviousPage)) {
                self.model.previousRequestLogsPage()
            }
            .buttonStyle(RequestLogsCompactButtonStyle(kind: .secondary))
            .disabled(!self.model.requestLogsHasPreviousPage || self.model.requestLogsIsRefreshing)

            Button(self.model.text(.actionNextPage)) {
                self.model.nextRequestLogsPage()
            }
            .buttonStyle(RequestLogsCompactButtonStyle(kind: .secondary))
            .disabled(!self.model.requestLogsHasMorePages || self.model.requestLogsIsRefreshing)
        }
    }

    private func tableContent(layout: RequestLogsLayoutMetrics) -> some View {
        Table(self.model.requestLogPage.entries) {
            Group {
                TableColumn(self.model.text(.labelTime)) { entry in
                    self.selectableTextCell(
                        self.model.requestLogTimeText(entry.timestamp),
                        font: .system(size: 11, weight: .medium, design: .monospaced),
                        help: self.model.requestLogTimeText(entry.timestamp),
                        entry: entry
                    )
                }
                .width(min: 160, ideal: 176)

                TableColumn(self.model.text(.labelInterface)) { entry in
                    self.selectableTextCell(
                        entry.endpoint,
                        font: .system(size: 11, weight: .semibold, design: .monospaced),
                        foreground: AppearanceStore.palette(for: self.colorScheme).accent,
                        help: entry.endpoint,
                        entry: entry
                    )
                }
                .width(min: 132, ideal: 150)

                TableColumn(self.model.text(.labelUpstreamURL)) { entry in
                    let upstreamURL = self.model.displayValue(entry.upstreamURL)
                    self.selectableTextCell(
                        upstreamURL,
                        font: .system(size: 11, weight: .semibold, design: .monospaced),
                        help: upstreamURL,
                        entry: entry
                    )
                }
                .width(min: 260, ideal: 340)

                TableColumn(self.model.text(.labelClientSource)) { entry in
                    let sourceText = self.model.requestLogClientSourceText(entry.clientSource)

                    self.selectableTextCell(
                        sourceText,
                        font: .system(size: 11, weight: .semibold),
                        help: sourceText,
                        entry: entry
                    )
                }
                .width(min: 112, ideal: 128)

                TableColumn(self.model.text(.labelModel)) { entry in
                    let actualModel = self.model.displayValue(entry.actualModel)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.model)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)

                        Text(actualModel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).textSecondary)
                    }
                    .help("\(self.model.text(.labelRequestedModel)): \(entry.model)\n\(self.model.text(.labelActualModel)): \(actualModel)")
                    .contextMenu {
                        self.requestLogContextMenu(for: entry)
                    }
                }
                .width(min: 214, ideal: 236)

                TableColumn(self.model.text(.labelReasoningEffort)) { entry in
                    let effort = self.model.displayValue(entry.reasoningEffort)

                    self.selectableTextCell(
                        effort,
                        font: .system(size: 11, weight: .semibold, design: .monospaced),
                        help: effort,
                        entry: entry
                    )
                }
                .width(min: 96, ideal: 112)

                TableColumn(self.model.text(.labelAPIKey)) { entry in
                    self.apiKeyCell(for: entry)
                }
                .width(min: 168, ideal: 188)
            }

            Group {
                TableColumn(self.model.text(.labelAccountLabel)) { entry in
                    self.selectableTextCell(
                        self.model.displayValue(entry.accountLabel),
                        font: .system(size: 12, weight: .semibold),
                        help: self.model.displayValue(entry.accountLabel),
                        entry: entry
                    )
                }
                .width(min: 144, ideal: 160)

                TableColumn(self.model.text(.labelStatus)) { entry in
                    StatusPill(
                        text: self.model.requestLogStatusText(entry),
                        tone: self.model.requestLogStatusTone(entry)
                    )
                    .contextMenu {
                        self.requestLogContextMenu(for: entry)
                    }
                }
                .width(min: 94, ideal: 104)

                TableColumn(self.model.text(.labelLatency)) { entry in
                    self.selectableTextCell(
                        self.model.requestLogLatencyText(entry.latencyMS),
                        font: .system(size: 11, weight: .medium, design: .monospaced),
                        help: self.model.requestLogLatencyText(entry.latencyMS),
                        entry: entry
                    )
                }
                .width(min: 90, ideal: 102)

                TableColumn(self.model.text(.labelTotalTokens)) { entry in
                    let summary = self.model.requestLogTokenSummary(entry)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.primaryLine)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()

                        Text(summary.secondaryLine)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).textSecondary)
                    }
                    .contextMenu {
                        self.requestLogContextMenu(for: entry)
                    }
                }
                .width(min: 214, ideal: 226)

                TableColumn(self.model.text(.labelErrorSummary)) { entry in
                    self.errorSummaryCell(for: entry)
                }
                .width(min: 300, ideal: 380)
            }
        }
    }

    private func selectableTextCell(
        _ value: String,
        font: Font,
        foreground: Color? = nil,
        help: String,
        entry: RequestLogEntry
    ) -> some View {
        Text(value)
            .font(font)
            .foregroundStyle(foreground ?? AppearanceStore.palette(for: self.colorScheme).textPrimary)
            .lineLimit(1)
            .textSelection(.enabled)
            .help(help)
            .contextMenu {
                self.requestLogContextMenu(for: entry)
            }
    }

    private func apiKeyCell(for entry: RequestLogEntry) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let masked = self.model.requestLogMaskedAPIKeyText(entry.apiKey)
        let fullValue = self.model.displayValue(entry.apiKey)
        let hasValue = entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        return HStack(alignment: .center, spacing: 8) {
            Text(masked)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if hasValue {
                Button {
                    self.model.copyRequestLogValue(entry.apiKey, successTitle: self.model.text(.successCopiedAPIKey))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(palette.accentSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.88))
                        )
                }
                .buttonStyle(.plain)
                .interactiveCursor()
                .help(self.model.text(.actionCopyAPIKey))
            }
        }
        .help(fullValue)
        .contextMenu {
            self.requestLogContextMenu(for: entry)
        }
    }

    private func errorSummaryCell(for entry: RequestLogEntry) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let visibleText = self.model.displayValue(entry.errorSummary)
        let copyValue = RequestLogErrorSummaryCopySupport.copyValue(from: entry.errorSummary)

        return HStack(alignment: .top, spacing: 8) {
            Text(visibleText)
                .font(.system(size: 11, weight: .regular))
                .lineLimit(2)
                .textSelection(.enabled)
                .foregroundStyle(entry.success ? palette.textSecondary : palette.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if let copyValue {
                Button {
                    self.model.copyRequestLogErrorSummary(copyValue)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(palette.accentSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.88))
                        )
                }
                .buttonStyle(.plain)
                .interactiveCursor()
                .help(self.model.text(.actionCopyErrorSummary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(copyValue ?? visibleText)
        .contextMenu {
            self.requestLogContextMenu(for: entry)
        }
    }

    @ViewBuilder
    private func requestLogContextMenu(for entry: RequestLogEntry) -> some View {
        RequestLogContextMenuContent(model: self.model, entry: entry)
    }

    private var timePresetField: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelTimeRange),
            minWidth: 180,
            idealWidth: 180,
            maxWidth: 180
        ) {
            Picker(
                self.model.text(.labelTimeRange),
                selection: Binding(
                    get: { self.model.requestLogsDraftFilterState.timePreset },
                    set: { self.model.setRequestLogsTimePreset($0) }
                )
            ) {
                ForEach(RequestLogTimePreset.allCases, id: \.self) { preset in
                    Text(self.model.label(for: preset)).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .requestLogsCompactFieldChrome()
        }
    }

    private var fromField: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelFrom),
            minWidth: 240,
            idealWidth: 240,
            maxWidth: 240
        ) {
            FixedDateTimeField(
                value: Binding(
                    get: { self.model.requestLogsDraftFilterState.fromDate },
                    set: { self.model.setRequestLogsFromDate($0) }
                ),
                title: self.model.text(.labelFrom)
            )
        }
    }

    private var toField: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelTo),
            minWidth: 240,
            idealWidth: 240,
            maxWidth: 240
        ) {
            FixedDateTimeField(
                value: Binding(
                    get: { self.model.requestLogsDraftFilterState.toDate },
                    set: { self.model.setRequestLogsToDate($0) }
                ),
                title: self.model.text(.labelTo)
            )
        }
    }

    private var apiKeyField: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelAPIKey),
            minWidth: 280,
            idealWidth: 320,
            maxWidth: 380,
            layoutPriority: 1
        ) {
            Picker(
                self.model.text(.labelAPIKey),
                selection: Binding(
                    get: { self.model.requestLogsDraftFilterState.selectedAPIKey },
                    set: { self.model.setRequestLogsAPIKey($0) }
                )
            ) {
                Text(self.model.text(.commonAll)).tag("")
                ForEach(self.model.requestLogsAPIKeyOptions, id: \.self) { apiKey in
                    Text(apiKey).tag(apiKey)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .requestLogsCompactFieldChrome()
        }
    }

    private var clientSourceField: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelClientSource),
            minWidth: 180,
            idealWidth: 180,
            maxWidth: 180
        ) {
            Picker(
                self.model.text(.labelClientSource),
                selection: Binding(
                    get: { self.model.requestLogsDraftFilterState.selectedClientSource },
                    set: { self.model.setRequestLogsClientSource($0) }
                )
            ) {
                Text(self.model.text(.commonAll)).tag(nil as RequestLogClientSource?)
                ForEach(RequestLogClientSource.allCases, id: \.self) { source in
                    Text(self.model.requestLogClientSourceText(source)).tag(Optional(source))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .requestLogsCompactFieldChrome()
        }
    }

    private var modelField: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelRequestedModel),
            minWidth: 220,
            idealWidth: 220,
            maxWidth: 220
        ) {
            Picker(
                self.model.text(.labelRequestedModel),
                selection: Binding(
                    get: { self.model.requestLogsDraftFilterState.selectedModel },
                    set: { self.model.setRequestLogsModel($0) }
                )
            ) {
                Text(self.model.text(.commonAll)).tag("")
                ForEach(self.model.requestLogsModelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .requestLogsCompactFieldChrome()
        }
    }

    private var accountLabelField: some View {
        RequestLogsInlineField(
            title: self.model.text(.labelAccountLabel),
            minWidth: 260,
            idealWidth: 300,
            maxWidth: 360,
            layoutPriority: 1
        ) {
            Picker(
                self.model.text(.labelAccountLabel),
                selection: Binding(
                    get: { self.model.requestLogsDraftFilterState.selectedAccountKey },
                    set: { self.model.setRequestLogsAccountKey($0) }
                )
            ) {
                Text(self.model.text(.commonAll)).tag("")
                ForEach(self.model.requestLogsAccountOptions) { option in
                    Text(option.title).tag(option.accountKey)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .requestLogsCompactFieldChrome()
        }
    }

    private var shouldAutoExpandEmbeddedControls: Bool {
        self.model.requestLogsHasPendingFilterChanges ||
            self.model.requestLogPage.entries.isEmpty ||
            self.model.requestLogsIsRefreshing ||
            self.model.requestLogsDraftFilterState.timePreset == .custom
    }

    private func initializeEmbeddedControlsDisclosureIfNeeded() {
        guard self.hasInitializedEmbeddedControls == false else { return }
        self.hasInitializedEmbeddedControls = true
        self.isEmbeddedControlsExpanded = self.shouldAutoExpandEmbeddedControls
    }
}

private struct RequestLogsLayoutMetrics {
    let isCompact: Bool
    let outerHorizontalPadding: CGFloat
    let outerTopPadding: CGFloat
    let outerBottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let headerSpacing: CGFloat
    let cardContentSpacing: CGFloat
    let panelPadding: CGFloat
    let panelCornerRadius: CGFloat
    let titleFontSize: CGFloat
    let subtitleFontSize: CGFloat
    let minimumTableViewportHeight: CGFloat

    init(proxy: GeometryProxy) {
        let width = proxy.size.width
        let height = proxy.size.height
        self.isCompact = width < 1380 || height < 900
        self.outerHorizontalPadding = self.isCompact ? 14 : 18
        self.outerTopPadding = max(self.isCompact ? 10 : 14, proxy.safeAreaInsets.top + (self.isCompact ? 4 : 6))
        self.outerBottomPadding = self.isCompact ? 14 : 18
        self.sectionSpacing = self.isCompact ? 8 : 10
        self.headerSpacing = self.isCompact ? 8 : 10
        self.cardContentSpacing = self.isCompact ? 8 : 10
        self.panelPadding = self.isCompact ? 10 : 12
        self.panelCornerRadius = self.isCompact ? 16 : 18
        self.titleFontSize = self.isCompact ? 22 : 26
        self.subtitleFontSize = self.isCompact ? 11 : 12
        self.minimumTableViewportHeight = self.isCompact ? 220 : 300
    }
}

private struct RequestLogsPanel<Accessory: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String?
    let accessory: Accessory
    let compact: Bool
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        accessory: Accessory,
        compact: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 8 : 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    self.titleBlock(palette: palette)
                    Spacer(minLength: 0)
                    self.accessory
                }

                VStack(alignment: .leading, spacing: 6) {
                    self.titleBlock(palette: palette)
                    self.accessory
                }
            }

            self.content
        }
        .padding(self.compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.94),
                            palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.90),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 16 : 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [palette.border, Color.white.opacity(self.colorScheme == .dark ? 0.04 : 0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: palette.shadow.opacity(self.colorScheme == .dark ? 0.22 : 0.08), radius: 14, x: 0, y: 8)
    }

    private func titleBlock(palette: AppearancePalette) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(self.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)

            if let subtitle, !subtitle.isEmpty {
                RequestLogsInfoGlyph(helpText: subtitle)
            }
        }
    }
}

private extension RequestLogsPanel where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        compact: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, accessory: EmptyView(), compact: compact, content: content)
    }
}

private struct RequestLogsInfoGlyph: View {
    @Environment(\.colorScheme) private var colorScheme

    let helpText: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).textMuted)
            .help(self.helpText)
    }
}

private struct RequestLogsInlineField<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var minWidth: CGFloat? = nil
    var idealWidth: CGFloat? = nil
    var maxWidth: CGFloat? = nil
    var layoutPriority: Double = 0
    @ViewBuilder var content: Content

    init(
        title: String,
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        layoutPriority: Double = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.layoutPriority = layoutPriority
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Text(self.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            self.content
        }
        .frame(
            minWidth: self.minWidth,
            idealWidth: self.idealWidth ?? self.minWidth,
            maxWidth: self.maxWidth,
            alignment: .leading
        )
        .layoutPriority(self.layoutPriority)
    }
}

private struct RequestLogsCompactFieldChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.82 : 0.90))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
    }
}

private struct RequestLogsCompactButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let kind: Kind
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let pressed = configuration.isPressed && self.isEnabled
        let accent = self.tint ?? palette.accent
        let fillTop: Color
        let fillBottom: Color
        let foreground: Color
        let border: Color

        if self.kind == .primary {
            fillTop = accent
            fillBottom = accent.opacity(self.colorScheme == .dark ? 0.74 : 0.88)
            foreground = .white
            border = accent.opacity(0.28)
        } else {
            fillTop = palette.panelRaised
            fillBottom = palette.panelMuted
            foreground = self.tint ?? palette.textPrimary
            border = palette.border
        }

        return configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(self.isEnabled ? foreground : palette.textSecondary.opacity(0.75))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                fillTop.opacity(pressed ? 0.88 : 1.0),
                                fillBottom.opacity(pressed ? 0.88 : 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .opacity(self.isEnabled ? 1.0 : 0.92)
            .scaleEffect(pressed ? 0.985 : 1.0)
            .interactiveCursor(isEnabled: self.isEnabled)
    }
}

private extension View {
    func requestLogsCompactFieldChrome() -> some View {
        self.modifier(RequestLogsCompactFieldChromeModifier())
    }
}

struct RequestLogContextMenuContent: View {
    @ObservedObject var model: DesktopAppModel
    let entry: RequestLogEntry

    var actionTitles: [String] {
        var titles = [
            self.model.text(.actionCopyTime),
            self.model.text(.actionCopyEndpoint),
            self.model.text(.actionCopyRequestedModel),
        ]

        if let upstreamURL = self.entry.upstreamURL?.trimmingCharacters(in: .whitespacesAndNewlines), !upstreamURL.isEmpty {
            titles.append(self.model.text(.actionCopyUpstreamURL))
        }

        if let actualModel = self.entry.actualModel?.trimmingCharacters(in: .whitespacesAndNewlines), !actualModel.isEmpty {
            titles.append(self.model.text(.actionCopyActualModel))
        }

        if let reasoningEffort = self.entry.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoningEffort.isEmpty {
            titles.append(self.model.text(.actionCopyReasoningEffort))
        }

        titles.append(self.model.text(.actionCopyAccountLabel))

        if self.entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            titles.append(self.model.text(.actionCopyAPIKey))
        }

        if RequestLogErrorSummaryCopySupport.copyValue(from: self.entry.errorSummary) != nil {
            titles.append(self.model.text(.actionCopyErrorSummary))
        }

        if self.entry.hasDiagnosticRequestBody {
            titles.append(self.model.text(.actionViewDiagnosticRequestBody))
        }

        titles.append(self.model.text(.actionCopyRowCSV))
        return titles
    }

    var body: some View {
        Group {
            Button(self.model.text(.actionCopyTime)) {
                self.model.copyRequestLogValue(
                    self.model.requestLogTimeText(self.entry.timestamp),
                    successTitle: self.model.text(.successCopiedTime)
                )
            }

            Button(self.model.text(.actionCopyEndpoint)) {
                self.model.copyRequestLogValue(
                    self.entry.endpoint,
                    successTitle: self.model.text(.successCopiedEndpoint)
                )
            }

            if let upstreamURL = self.entry.upstreamURL?.trimmingCharacters(in: .whitespacesAndNewlines), !upstreamURL.isEmpty {
                Button(self.model.text(.actionCopyUpstreamURL)) {
                    self.model.copyRequestLogValue(
                        upstreamURL,
                        successTitle: self.model.text(.successCopiedUpstreamURL)
                    )
                }
            }

            Button(self.model.text(.actionCopyRequestedModel)) {
                self.model.copyRequestLogValue(
                    self.entry.model,
                    successTitle: self.model.text(.successCopiedRequestedModel)
                )
            }

            if let actualModel = self.entry.actualModel?.trimmingCharacters(in: .whitespacesAndNewlines), !actualModel.isEmpty {
                Button(self.model.text(.actionCopyActualModel)) {
                    self.model.copyRequestLogValue(
                        actualModel,
                        successTitle: self.model.text(.successCopiedActualModel)
                    )
                }
            }

            if let reasoningEffort = self.entry.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoningEffort.isEmpty {
                Button(self.model.text(.actionCopyReasoningEffort)) {
                    self.model.copyRequestLogValue(
                        reasoningEffort,
                        successTitle: self.model.text(.successCopiedReasoningEffort)
                    )
                }
            }

            Button(self.model.text(.actionCopyAccountLabel)) {
                self.model.copyRequestLogValue(
                    self.entry.accountLabel,
                    successTitle: self.model.text(.successCopiedAccountLabel)
                )
            }

            if self.entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Button(self.model.text(.actionCopyAPIKey)) {
                    self.model.copyRequestLogValue(
                        self.entry.apiKey,
                        successTitle: self.model.text(.successCopiedAPIKey)
                    )
                }
            }

            if let errorSummary = RequestLogErrorSummaryCopySupport.copyValue(from: self.entry.errorSummary) {
                Button(self.model.text(.actionCopyErrorSummary)) {
                    self.model.copyRequestLogErrorSummary(errorSummary)
                }
            }

            if self.entry.hasDiagnosticRequestBody {
                Button(self.model.text(.actionViewDiagnosticRequestBody)) {
                    Task { await self.model.loadDiagnosticRequestBody(for: self.entry) }
                }
            }

            Divider()

            Button(self.model.text(.actionCopyRowCSV)) {
                self.model.copyRequestLogRowCSV(self.entry)
            }
        }
    }
}

private struct DiagnosticRequestBodyDetailSheet: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.model.text(.sectionDiagnosticRequestBodies))
                        .font(.system(size: 16, weight: .semibold))
                    if let entry = self.model.diagnosticRequestBodyDetail?.entry {
                        Text("\(entry.endpoint) · \(entry.actualModel ?? entry.model)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(self.model.text(.commonDismiss)) {
                    self.model.isDiagnosticRequestBodyPresented = false
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }

            if let detail = self.model.diagnosticRequestBodyDetail {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(self.model.text(.labelDiagnosticBodyHash)): \(detail.entry.bodySHA256)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(self.model.text(.labelDiagnosticPrefixHash)): \(detail.entry.prefixSHA256)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

                if detail.available, let bodyText = detail.bodyText {
                    ScrollView {
                        Text(bodyText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                    .frame(width: 760, height: 480)
                    .dashboardFieldChrome()

                    HStack {
                        Button(self.model.text(.actionCopyDiagnosticRequestBody)) {
                            self.model.copyDiagnosticRequestBody()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary))

                        Button(self.model.text(.actionSaveDiagnosticRequestBody)) {
                            self.model.saveDiagnosticRequestBody()
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))

                        Spacer(minLength: 0)
                    }
                } else {
                    Text(detail.message ?? self.model.text(.helperDiagnosticRequestBodyUnavailable))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 560, alignment: .leading)
                        .padding(12)
                        .dashboardFieldChrome()
                }
            } else {
                ProgressView()
                    .frame(width: 420, height: 120)
            }
        }
        .padding(18)
    }
}
#endif
