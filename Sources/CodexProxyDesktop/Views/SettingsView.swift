#if os(macOS)
import CodexProxyCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: DesktopAppModel
    @SceneStorage("settings.selectedTab") private var selectedTabRawValue = SettingsTab.appearance.rawValue

    private var selectedTabBinding: Binding<SettingsTab> {
        Binding(
            get: { self.model.selectedSettingsTab },
            set: { self.model.selectedSettingsTab = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsAppearanceSummaryCard(model: self.model)

            DashboardTabStrip(
                items: SettingsTab.allCases,
                selection: self.selectedTabBinding,
                title: { self.model.text($0.tabTitleKey) },
                symbol: { $0.symbolName }
            )

            Group {
                switch self.selectedTab {
                case .appearance:
                    SettingsAppearancePanel(model: self.model)
                case .general:
                    SettingsGeneralPanel(model: self.model)
                case .ocr:
                    SettingsOCRPanel(model: self.model)
                case .proxy:
                    SettingsProxyPanel(model: self.model)
                case .service:
                    SettingsServicePanel(model: self.model)
                case .cleanup:
                    SettingsCleanupPanel(model: self.model)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.18), value: self.selectedTab)
        }
        .onAppear {
            let stored = SettingsTab(rawValue: self.selectedTabRawValue) ?? .appearance
            if self.model.selectedSettingsTab == .appearance {
                self.model.selectedSettingsTab = stored
            } else if self.selectedTabRawValue != self.model.selectedSettingsTab.rawValue {
                self.selectedTabRawValue = self.model.selectedSettingsTab.rawValue
            }
        }
        .onChange(of: self.selectedTabRawValue) { _, rawValue in
            let stored = SettingsTab(rawValue: rawValue) ?? .appearance
            if self.model.selectedSettingsTab != stored {
                self.model.selectedSettingsTab = stored
            }
        }
        .onChange(of: self.model.selectedSettingsTab) { _, tab in
            if self.selectedTabRawValue != tab.rawValue {
                self.selectedTabRawValue = tab.rawValue
            }
        }
    }

    private var selectedTab: SettingsTab {
        self.model.selectedSettingsTab
    }
}

struct SettingsAppearanceSummaryCard: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.sectionAppearance),
            subtitle: self.model.text(.helperAppearanceAppliesImmediately),
            compact: true
        ) {
            LazyVGrid(columns: self.summaryColumns, spacing: 8) {
                MetricTile(
                    label: self.model.text(.labelLanguage),
                    value: self.model.label(for: self.model.preferences.languageMode),
                    footnote: self.model.settingsAppearanceLanguageSubtitle(self.model.preferences.languageMode),
                    tone: .accent,
                    symbol: "character.bubble.fill",
                    compact: true
                )
                MetricTile(
                    label: self.model.text(.labelTheme),
                    value: self.model.label(for: self.model.preferences.themeMode),
                    footnote: self.model.settingsAppearanceThemeSubtitle(self.model.preferences.themeMode),
                    tone: .neutral,
                    symbol: "circle.lefthalf.filled",
                    compact: true
                )
                MetricTile(
                    label: self.model.text(.labelCloseAction),
                    value: self.model.label(for: self.model.settings.windowCloseBehavior),
                    footnote: self.model.text(.sectionBehavior),
                    tone: .warning,
                    symbol: "macwindow.on.rectangle",
                    compact: true
                )
            }
        }
    }

    private let summaryColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 10),
    ]
}

private extension DesktopAppModel {
    func settingsAppearanceLanguageSubtitle(_ mode: DesktopLanguageMode) -> String {
        switch mode {
        case .system:
            return self.text(.helperLanguageOptionSystem)
        case .zhHans:
            return self.text(.helperLanguageOptionChinese)
        case .english:
            return self.text(.helperLanguageOptionEnglish)
        }
    }

    func settingsAppearanceThemeSubtitle(_ mode: DesktopThemeMode) -> String {
        switch mode {
        case .system:
            return self.text(.helperThemeOptionSystem)
        case .light:
            return self.text(.helperThemeOptionLight)
        case .dark:
            return self.text(.helperThemeOptionDark)
        }
    }
}

private struct SettingsAppearancePanel: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(SettingsTab.appearance.panelTitleKey),
            subtitle: self.model.text(SettingsTab.appearance.subtitleKey)
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    self.languagePanel
                    self.themePanel
                }

                VStack(alignment: .leading, spacing: 12) {
                    self.languagePanel
                    self.themePanel
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var languagePanel: some View {
        SettingsInsetPanel(
            title: self.model.text(.labelLanguage),
            subtitle: self.model.settingsAppearanceLanguageSubtitle(self.model.preferences.languageMode)
        ) {
            SettingsOptionCardSelector(
                selection: Binding(
                    get: { self.model.preferences.languageMode },
                    set: { self.model.updateLanguage($0) }
                ),
                items: self.languageItems,
                currentTitle: self.model.text(.statusCurrent)
            )
        }
    }

    private var themePanel: some View {
        SettingsInsetPanel(
            title: self.model.text(.labelTheme),
            subtitle: self.model.settingsAppearanceThemeSubtitle(self.model.preferences.themeMode)
        ) {
            SettingsOptionCardSelector(
                selection: Binding(
                    get: { self.model.preferences.themeMode },
                    set: { self.model.updateTheme($0) }
                ),
                items: self.themeItems,
                currentTitle: self.model.text(.statusCurrent)
            )
        }
    }

    private var languageItems: [SettingsOptionCardSelector<DesktopLanguageMode>.Item] {
        [
            .init(
                value: .system,
                symbol: "globe",
                title: self.model.label(for: DesktopLanguageMode.system),
                subtitle: self.model.settingsAppearanceLanguageSubtitle(DesktopLanguageMode.system)
            ) {
                SettingsLanguagePreview(mode: .system)
            },
            .init(
                value: .zhHans,
                symbol: "character.book.closed",
                title: self.model.label(for: .zhHans),
                subtitle: self.model.settingsAppearanceLanguageSubtitle(.zhHans)
            ) {
                SettingsLanguagePreview(mode: .zhHans)
            },
            .init(
                value: .english,
                symbol: "textformat.abc",
                title: self.model.label(for: .english),
                subtitle: self.model.settingsAppearanceLanguageSubtitle(.english)
            ) {
                SettingsLanguagePreview(mode: .english)
            },
        ]
    }

    private var themeItems: [SettingsOptionCardSelector<DesktopThemeMode>.Item] {
        [
            .init(
                value: .system,
                symbol: "circle.lefthalf.filled",
                title: self.model.label(for: DesktopThemeMode.system),
                subtitle: self.model.settingsAppearanceThemeSubtitle(DesktopThemeMode.system)
            ) {
                SettingsThemePreview(mode: .system)
            },
            .init(
                value: .light,
                symbol: "sun.max.fill",
                title: self.model.label(for: .light),
                subtitle: self.model.settingsAppearanceThemeSubtitle(.light)
            ) {
                SettingsThemePreview(mode: .light)
            },
            .init(
                value: .dark,
                symbol: "moon.fill",
                title: self.model.label(for: .dark),
                subtitle: self.model.settingsAppearanceThemeSubtitle(.dark)
            ) {
                SettingsThemePreview(mode: .dark)
            },
        ]
    }
}

private struct SettingsLanguagePreview: View {
    @Environment(\.colorScheme) private var colorScheme

    let mode: DesktopLanguageMode

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: 4) {
            switch self.mode {
            case .system:
                self.token("文", tone: .accent)
                self.token("A", tone: .neutral)
            case .zhHans:
                self.token("你好", tone: .accent)
            case .english:
                self.token("Hello", tone: .neutral)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minWidth: 68, alignment: .trailing)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.border.opacity(0.9), lineWidth: 1)
        )
    }

    private enum TokenTone {
        case accent
        case neutral
    }

    private func token(_ text: String, tone: TokenTone) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let foreground: Color
        let background: Color
        let border: Color

        switch tone {
        case .accent:
            foreground = palette.accent
            background = palette.accentSoft.opacity(self.colorScheme == .dark ? 0.92 : 1.0)
            border = palette.accent.opacity(self.colorScheme == .dark ? 0.28 : 0.18)
        case .neutral:
            foreground = palette.textSecondary
            background = palette.panelMuted.opacity(self.colorScheme == .dark ? 0.9 : 1.0)
            border = palette.border.opacity(0.84)
        }

        return Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
            .overlay(Capsule().stroke(border, lineWidth: 1))
    }
}

private struct SettingsThemePreview: View {
    @Environment(\.colorScheme) private var colorScheme

    let mode: DesktopThemeMode

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: 4) {
            switch self.mode {
            case .system:
                self.previewWindow(self.lightWindowColors, width: 22)
                self.previewWindow(self.darkWindowColors, width: 22)
            case .light:
                self.previewWindow(self.lightWindowColors, width: 48)
            case .dark:
                self.previewWindow(self.darkWindowColors, width: 48)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.border.opacity(0.9), lineWidth: 1)
        )
    }

    private var lightWindowColors: ThemePreviewColors {
        ThemePreviewColors(
            background: Color(.sRGB, red: 0.98, green: 0.99, blue: 1.0, opacity: 1.0),
            topBar: Color(.sRGB, red: 0.91, green: 0.95, blue: 1.0, opacity: 1.0),
            primaryLine: Color(.sRGB, red: 0.29, green: 0.45, blue: 0.73, opacity: 1.0),
            secondaryLine: Color(.sRGB, red: 0.72, green: 0.79, blue: 0.89, opacity: 1.0),
            border: Color(.sRGB, red: 0.79, green: 0.85, blue: 0.94, opacity: 1.0)
        )
    }

    private var darkWindowColors: ThemePreviewColors {
        ThemePreviewColors(
            background: Color(.sRGB, red: 0.13, green: 0.17, blue: 0.24, opacity: 1.0),
            topBar: Color(.sRGB, red: 0.19, green: 0.25, blue: 0.34, opacity: 1.0),
            primaryLine: Color(.sRGB, red: 0.49, green: 0.67, blue: 1.0, opacity: 1.0),
            secondaryLine: Color(.sRGB, red: 0.45, green: 0.52, blue: 0.62, opacity: 1.0),
            border: Color(.sRGB, red: 0.28, green: 0.34, blue: 0.43, opacity: 1.0)
        )
    }

    @ViewBuilder
    private func previewWindow(_ colors: ThemePreviewColors, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.background)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.topBar)
                .frame(height: 6)

            VStack(alignment: .leading, spacing: 3) {
                Capsule(style: .continuous)
                    .fill(colors.primaryLine)
                    .frame(width: width * 0.45, height: 4)

                Capsule(style: .continuous)
                    .fill(colors.secondaryLine)
                    .frame(width: width * 0.28, height: 4)
            }
            .padding(.horizontal, 5)
            .padding(.top, 11)
        }
        .frame(width: width, height: 28)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
    }

    private struct ThemePreviewColors {
        let background: Color
        let topBar: Color
        let primaryLine: Color
        let secondaryLine: Color
        let border: Color
    }
}

private struct SettingsGeneralPanel: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(SettingsTab.general.panelTitleKey),
            subtitle: self.model.text(SettingsTab.general.subtitleKey)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        self.generalPanel
                        self.behaviorPanel
                        self.geminiOAuthPanel
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        self.generalPanel
                        self.behaviorPanel
                        self.geminiOAuthPanel
                    }
                }
            }

            HStack {
                Button(self.model.text(.actionSaveGeneralSettings), action: self.saveSettings)
                    .buttonStyle(AppActionButtonStyle(kind: .primary))
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var generalPanel: some View {
        SettingsInsetPanel(title: self.model.text(.sectionGeneral)) {
            FormFieldPanel(title: self.model.text(.labelChatGPTBaseURL)) {
                TextField(self.model.text(.labelChatGPTBaseURL), text: self.$model.settings.chatGPTBaseURL)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelDaemonBinaryOverride)) {
                TextField(self.model.text(.labelDaemonBinaryOverride), text: self.$model.settings.daemonBinaryOverride)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelStatsRetentionDays)) {
                TextField(
                    self.model.text(.labelStatsRetentionDays),
                    value: self.$model.settings.statsRetentionDays,
                    formatter: NumberFormatter()
                )
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
            }
        }
    }

    private var behaviorPanel: some View {
        SettingsInsetPanel(title: self.model.text(.sectionBehavior)) {
            FormFieldPanel(title: self.model.text(.labelCloseAction)) {
                Picker(self.model.text(.labelCloseAction), selection: self.$model.settings.windowCloseBehavior) {
                    Text(self.model.label(for: WindowCloseBehavior.hideToMenuBar)).tag(WindowCloseBehavior.hideToMenuBar)
                    Text(self.model.label(for: WindowCloseBehavior.quit)).tag(WindowCloseBehavior.quit)
                }
                .pickerStyle(.segmented)
            }

            FormFieldPanel(title: self.model.text(.labelAutoStart)) {
                Toggle(self.model.text(.labelAutoStart), isOn: self.$model.settings.autoStart)
                    .toggleStyle(.switch)
            }

            FormFieldPanel(
                title: self.model.text(.labelMenuBarTokenUsage),
                footer: self.model.text(.helperMenuBarTokenUsage)
            ) {
                Toggle(
                    self.model.text(.labelMenuBarTokenUsage),
                    isOn: Binding(
                        get: { self.model.preferences.showsMenuBarTokenUsage },
                        set: { self.model.updateShowsMenuBarTokenUsage($0) }
                    )
                )
                .toggleStyle(.switch)
            }

            FormFieldPanel(
                title: self.model.localized(zh: "自动检查更新", en: "Automatic Update Checks"),
                footer: self.model.localized(
                    zh: "启动时每天最多检查一次 GitHub Releases，有新版本才会提示。",
                    en: "Checks GitHub Releases at launch at most once per day and only prompts when a new version is available."
                )
            ) {
                Toggle(
                    self.model.localized(zh: "启动时自动检查更新", en: "Check for updates at launch"),
                    isOn: Binding(
                        get: { self.model.preferences.automaticUpdateChecksEnabled },
                        set: { self.model.updateAutomaticUpdateChecksEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
            }
        }
    }

    private var geminiOAuthPanel: some View {
        SettingsInsetPanel(
            title: self.model.text(.sectionGeminiOAuth),
            subtitle: self.model.text(.helperGeminiOAuthSettings)
        ) {
            FormFieldPanel(title: self.model.text(.labelGeminiOAuthClientID)) {
                TextField(self.model.text(.labelGeminiOAuthClientID), text: self.$model.settings.geminiOAuth.clientID)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelGeminiOAuthClientSecret)) {
                SecureField(self.model.text(.labelGeminiOAuthClientSecret), text: self.$model.settings.geminiOAuth.clientSecret)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }
        }
    }

    private func saveSettings() {
        Task { await self.model.saveSettings() }
    }
}

private struct SettingsOCRPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(SettingsTab.ocr.panelTitleKey),
            subtitle: self.model.text(SettingsTab.ocr.subtitleKey),
            accessory: Button(self.model.text(.actionRefreshOCRCache)) {
                self.refresh()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.model.ocrCacheIsRefreshing)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OCRSettingsPanel(model: self.model)
                self.cachePanel

                HStack {
                    Button(self.model.text(.actionSaveOCRSettings), action: self.saveSettings)
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            if self.model.ocrCacheSummary.totalCount == 0 {
                self.refresh()
            }
        }
    }

    private var cachePanel: some View {
        SettingsInsetPanel(
            title: self.model.text(.sectionOCRCache),
            subtitle: self.model.text(.helperOCRCache)
        ) {
            self.privacyNotice
            self.metrics
            self.actions
        }
    }

    private var privacyNotice: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.info)
                .frame(width: 16, height: 16)
            Text(self.model.text(.helperOCRCachePrivacy))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.infoSoft.opacity(self.colorScheme == .dark ? 0.34 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.infoBorder.opacity(self.colorScheme == .dark ? 0.40 : 0.55), lineWidth: 1)
        )
    }

    private var metrics: some View {
        LazyVGrid(columns: self.metricColumns, spacing: 10) {
            MetricTile(
                label: self.model.text(.labelReasoningCacheTotal),
                value: "\(self.model.ocrCacheSummary.totalCount)",
                footnote: self.model.text(.sectionOCRCache),
                tone: .accent,
                symbol: "text.viewfinder",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelReasoningCacheExpired),
                value: "\(self.model.ocrCacheSummary.expiredCount)",
                footnote: self.model.text(.actionClearExpiredOCRCache),
                tone: self.model.ocrCacheSummary.expiredCount > 0 ? .warning : .neutral,
                symbol: "clock.badge.exclamationmark",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelReasoningCacheNewest),
                value: self.model.ocrCacheTimestampText(self.model.ocrCacheSummary.newestTouchedAt),
                footnote: self.model.text(.labelLastRefreshed),
                tone: .neutral,
                symbol: "clock.arrow.circlepath",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelReasoningCacheOldest),
                value: self.model.ocrCacheTimestampText(self.model.ocrCacheSummary.oldestTouchedAt),
                footnote: self.model.text(.labelTime),
                tone: .neutral,
                symbol: "clock",
                compact: true
            )
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormFieldPanel(title: self.model.text(.labelReasoningCacheOlderThan)) {
                Picker(
                    self.model.text(.labelReasoningCacheOlderThan),
                    selection: self.$model.ocrCacheOlderThanSeconds
                ) {
                    ForEach(ReasoningCacheOlderThanPreset.allCases) { preset in
                        Text(self.model.reasoningCacheOlderThanLabel(preset.rawValue)).tag(preset.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(self.model.ocrCacheIsClearing)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    self.clearExpiredButton
                    self.clearOlderButton
                    self.clearAllButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    self.clearExpiredButton
                    self.clearOlderButton
                    self.clearAllButton
                }
            }
        }
        .padding(.top, 2)
    }

    private var clearExpiredButton: some View {
        Button(self.model.text(.actionClearExpiredOCRCache)) {
            Task { await self.model.clearExpiredOCRCache() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(self.model.ocrCacheIsClearing)
    }

    private var clearOlderButton: some View {
        Button(self.model.text(.actionClearOCRCacheOlderThan)) {
            Task { await self.model.clearOCRCacheOlderThanSelectedPreset() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(!self.model.ocrCacheHasEntries || self.model.ocrCacheIsClearing)
    }

    private var clearAllButton: some View {
        Button(self.model.text(.actionClearAllOCRCache)) {
            Task { await self.model.clearAllOCRCache() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .danger))
        .disabled(!self.model.ocrCacheHasEntries || self.model.ocrCacheIsClearing)
    }

    private let metricColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10),
    ]

    private func refresh() {
        Task { await self.model.loadOCRCacheSummary() }
    }

    private func saveSettings() {
        Task { await self.model.saveSettings() }
    }
}

struct SettingsProxyPanel: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(SettingsTab.proxy.panelTitleKey),
            subtitle: self.model.text(SettingsTab.proxy.subtitleKey),
            accessory: Button(self.model.managedProxyManagerWindowTitle) {
                self.model.openManagedProxyManagerWindow()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
        ) {
            FormFieldPanel(
                title: self.model.localizedManagedProxyText(zh: "代理模式", en: "Proxy Mode"),
                footer: self.model.text(.helperOutboundProxyGlobalModeDisabled)
            ) {
                Picker(
                    self.model.localizedManagedProxyText(zh: "代理模式", en: "Proxy Mode"),
                    selection: Binding(
                        get: { self.model.settingsOutboundProxyDraft.mode },
                        set: { self.model.setSettingsOutboundProxyDraftMode($0) }
                    )
                ) {
                    ForEach(OutboundProxyMode.allCases, id: \.self) { mode in
                        Text(self.model.label(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(alignment: .center, spacing: 10) {
                StatusPill(text: self.model.managedProxyRuntimeStatusText, tone: self.model.managedProxyRuntimeTone)
                Text(self.model.managedProxySummaryText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)

            if self.model.settingsOutboundProxyModeNeedsConfirmation {
                SettingsInsetPanel(
                    title: self.model.text(.labelPendingProxyMode),
                    subtitle: self.model.localizedManagedProxyText(
                        zh: "当前不会立即切换，点击“确认切换模式”后才会真正生效。",
                        en: "The active mode will stay unchanged until you confirm the switch."
                    )
                ) {
                    DetailRow(
                        label: self.model.text(.labelCurrentEffectiveProxyMode),
                        value: self.model.label(for: self.model.settings.outboundProxyMode),
                        labelWidth: 106
                    )
                    DetailRow(
                        label: self.model.text(.labelPendingProxyMode),
                        value: self.model.label(for: self.model.settingsOutboundProxyDraft.mode),
                        labelWidth: 106
                    )

                    if let requirementText = self.model.settingsOutboundProxyModeConfirmationRequirementText {
                        Text(requirementText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(self.model.text(.actionConfirmProxyModeChange), action: self.confirmModeChange)
                            .buttonStyle(AppActionButtonStyle(kind: .primary))
                            .disabled(self.model.isBusy || self.model.settingsOutboundProxyCanConfirmModeChange == false)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                }
            }

            switch self.model.settingsOutboundProxyDraft.mode {
            case .disabled:
                SettingsInsetPanel(
                    title: self.model.localizedManagedProxyText(zh: "已禁用", en: "Disabled"),
                    subtitle: self.model.localizedManagedProxyText(
                        zh: "daemon 将直接连出，不使用任何本地或手工出站代理。",
                        en: "The daemon connects directly without a manual or managed outbound proxy."
                    )
                ) {}
            case .manual:
                SettingsInsetPanel(
                    title: self.model.localizedManagedProxyText(zh: "手工代理", en: "Manual Proxy"),
                    subtitle: self.model.localizedManagedProxyText(
                        zh: "保持兼容现有出站代理配置，适合接入你自己的代理端口。",
                        en: "Keeps the existing outbound proxy configuration for an external proxy endpoint."
                    )
                ) {
                    FormFieldPanel(title: self.model.text(.labelScheme)) {
                        Picker(self.model.text(.labelScheme), selection: self.$model.settingsOutboundProxyDraft.outboundProxy.scheme) {
                            ForEach([OutboundProxyScheme.http, .https, .socks5], id: \.self) { scheme in
                                Text(self.model.label(for: scheme)).tag(scheme)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            self.hostField
                            self.portField
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            self.hostField
                            self.portField
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            self.usernameField
                            self.passwordField
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            self.usernameField
                            self.passwordField
                        }
                    }

                    Text(self.model.text(.helperSaveManualProxyDoesNotSwitchMode))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(self.model.text(.actionSaveManualProxy), action: self.saveManualProxy)
                            .buttonStyle(AppActionButtonStyle(kind: .primary))
                            .disabled(self.model.isBusy || self.model.settingsOutboundProxyManualNeedsSave == false)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                }
            case .subscription:
                self.subscriptionPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            self.model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded()
        }
    }

    private var hostField: some View {
        FormFieldPanel(title: self.model.text(.labelHost)) {
            TextField(self.model.text(.labelHost), text: self.$model.settingsOutboundProxyDraft.outboundProxy.host)
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
        }
    }

    private var portField: some View {
        FormFieldPanel(title: self.model.text(.labelPublicPort)) {
            TextField(
                self.model.text(.labelPublicPort),
                value: self.$model.settingsOutboundProxyDraft.outboundProxy.port,
                formatter: NumberFormatter()
            )
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
        }
    }

    private var usernameField: some View {
        FormFieldPanel(title: self.model.text(.labelUsername)) {
            TextField(self.model.text(.labelUsername), text: self.$model.settingsOutboundProxyDraft.outboundProxy.username)
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
        }
    }

    private var passwordField: some View {
        FormFieldPanel(title: self.model.text(.labelPassword)) {
            SecureField(self.model.text(.labelPassword), text: self.$model.settingsOutboundProxyDraft.outboundProxy.password)
                .textFieldStyle(.plain)
                .dashboardFieldChrome()
        }
    }

    private func confirmModeChange() {
        Task { await self.model.confirmSettingsOutboundProxyModeChange() }
    }

    private func saveManualProxy() {
        Task { await self.model.saveSettingsOutboundProxyManualConfiguration() }
    }

    private var subscriptionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsInsetPanel(
                title: self.model.localizedManagedProxyText(zh: "订阅概览", en: "Subscription Overview"),
                subtitle: self.model.localizedManagedProxyText(
                    zh: "切到订阅节点模式后，daemon 会默认使用已保存的订阅配置；即使不切到这个模式，账号页里已设置的自定义出站节点也能单独覆盖。订阅更新、节点切换、测速和日志仍在“管理订阅”窗口里完成。",
                    en: "When you switch to Subscription mode, the daemon uses the saved subscription configuration as the default egress. Even without switching globally, saved account-level outbound nodes can still override it. Provider refreshes, node pinning, health checks, and logs still happen in Manage Subscription."
                )
            ) {
                Text(self.model.managedProxySummaryText(for: self.model.settingsOutboundProxyDraft.mode))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ManagedProxySummaryMetricsGrid(model: self.model, showsMixedPort: false, compact: true)
            }
        }
    }
}

private struct SettingsServicePanel: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(SettingsTab.service.panelTitleKey),
            subtitle: self.model.text(SettingsTab.service.subtitleKey),
            accessory: StatusPill(text: self.model.localLaunchctlStateText(), tone: self.model.localServiceTone())
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    self.diagnosticsPanel
                    self.logsPanel
                }

                VStack(alignment: .leading, spacing: 16) {
                    self.diagnosticsPanel
                    self.logsPanel
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var diagnosticsPanel: some View {
        SettingsInsetPanel(
            title: self.model.text(.sectionServiceDiagnostics),
            subtitle: self.model.text(.helperServiceDiagnostics)
        ) {
            if let local = self.model.localServiceStatus {
                VStack(alignment: .leading, spacing: 4) {
                    DetailRow(
                        label: self.model.text(.labelInstalled),
                        value: local.installed ? self.model.text(.statusOnline) : self.model.text(.statusOffline)
                    )
                    DetailRow(
                        label: self.model.text(.labelRunning),
                        value: local.running ? self.model.text(.statusRunning) : self.model.text(.statusStopped)
                    )
                    DetailRow(label: self.model.text(.labelLaunchctlState), value: self.model.localLaunchctlStateText())
                    DetailRow(label: self.model.text(.labelStdoutLog), value: local.stdoutPath)
                    DetailRow(label: self.model.text(.labelStderrLog), value: local.stderrPath)
                    DetailRow(
                        label: self.model.text(.labelLastError),
                        value: local.lastErrorSummary ?? self.model.text(.statusNoData)
                    )
                }
            } else {
                EmptyStatePanel(
                    title: self.model.text(.sectionServiceDiagnostics),
                    detail: self.model.text(.helperServiceDiagnostics)
                )
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
                helperText: self.model.localServiceSummaryText,
                helperTone: self.model.localServiceSummaryTone
            )
        }
    }

    private var logsPanel: some View {
        SettingsInsetPanel(
            title: self.model.text(.sectionLogs),
            subtitle: self.model.text(.helperServiceDiagnostics)
        ) {
            Button(self.model.text(.actionLoadLocalLogs), action: self.loadLogs)
                .buttonStyle(AppActionButtonStyle(kind: .secondary))

            FormFieldPanel(title: self.model.text(.sectionLogs)) {
                ScrollView {
                    Text(self.model.localDaemonLogs.isEmpty ? self.model.text(.placeholderNoLocalLogs) : self.model.localDaemonLogs)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(minHeight: 220, maxHeight: 320)
                .background(Color.clear)
                .dashboardFieldChrome()
            }
        }
    }

    private func startDaemon() {
        Task { await self.model.startDaemon() }
    }

    private func stopDaemon() {
        Task { await self.model.stopDaemon() }
    }

    private func loadLogs() {
        Task { await self.model.loadLocalDaemonLogs() }
    }
}

struct SettingsInsetPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textMuted)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            self.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
                            palette.panel.opacity(self.colorScheme == .dark ? 0.86 : 0.94),
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
#endif
