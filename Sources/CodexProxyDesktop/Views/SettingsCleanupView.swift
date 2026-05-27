#if os(macOS)
import CodexProxyCore
import SwiftUI

struct SettingsCleanupPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(SettingsTab.cleanup.panelTitleKey),
            subtitle: self.model.text(SettingsTab.cleanup.subtitleKey),
            accessory: Button(self.model.text(.actionRefreshReasoningCache)) {
                self.refresh()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.model.reasoningCacheIsRefreshing)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsInsetPanel(
                    title: self.model.text(.sectionReasoningCache),
                    subtitle: self.model.text(.helperReasoningCache)
                ) {
                    self.reasoningCacheIsolationNotice
                    self.metrics
                    self.actions
                    self.accountSummary
                }

                SettingsInsetPanel(
                    title: self.model.text(.sectionDiagnosticRequestBodies),
                    subtitle: self.model.text(.helperDiagnosticRequestBodiesCleanup)
                ) {
                    self.diagnosticRequestBodyNotice
                    self.diagnosticMetrics
                    self.diagnosticActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            if self.model.reasoningCacheSummary.totalCount == 0 {
                self.refresh()
            }
            if self.model.diagnosticRequestBodySummary.totalCount == 0 {
                Task { await self.model.loadDiagnosticRequestBodySummary() }
            }
        }
    }

    private var reasoningCacheIsolationNotice: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.info)
                .frame(width: 16, height: 16)
            Text(self.model.text(.helperReasoningCacheAccountIsolation))
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
                value: "\(self.model.reasoningCacheSummary.totalCount)",
                footnote: self.model.text(.sectionReasoningCache),
                tone: .accent,
                symbol: "brain.head.profile",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelReasoningCacheExpired),
                value: "\(self.model.reasoningCacheSummary.expiredCount)",
                footnote: self.model.text(.actionClearExpiredReasoningCache),
                tone: self.model.reasoningCacheSummary.expiredCount > 0 ? .warning : .neutral,
                symbol: "clock.badge.exclamationmark",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelReasoningCacheNewest),
                value: self.model.reasoningCacheTimestampText(self.model.reasoningCacheSummary.newestTouchedAt),
                footnote: self.model.text(.labelLastRefreshed),
                tone: .neutral,
                symbol: "clock.arrow.circlepath",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelReasoningCacheOldest),
                value: self.model.reasoningCacheTimestampText(self.model.reasoningCacheSummary.oldestTouchedAt),
                footnote: self.model.text(.labelTime),
                tone: .neutral,
                symbol: "clock",
                compact: true
            )
        }
    }

    private var diagnosticRequestBodyNotice: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.warning)
                .frame(width: 16, height: 16)
            Text(self.model.text(.helperDiagnosticRequestBodySensitiveData))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.34 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.warning.opacity(self.colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1)
        )
    }

    private var diagnosticMetrics: some View {
        LazyVGrid(columns: self.metricColumns, spacing: 10) {
            MetricTile(
                label: self.model.text(.labelDiagnosticRequestBodiesTotal),
                value: "\(self.model.diagnosticRequestBodySummary.totalCount)",
                footnote: self.model.text(.sectionDiagnosticRequestBodies),
                tone: .warning,
                symbol: "doc.text.magnifyingglass",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelDiagnosticRequestBodiesSize),
                value: self.model.diagnosticRequestBodySizeText(self.model.diagnosticRequestBodySummary.totalBytes),
                footnote: self.model.text(.labelDiagnosticRequestBodiesSize),
                tone: .neutral,
                symbol: "internaldrive",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelDiagnosticRequestBodiesExpired),
                value: "\(self.model.diagnosticRequestBodySummary.expiredCount)",
                footnote: self.model.text(.actionClearExpiredDiagnosticRequestBodies),
                tone: self.model.diagnosticRequestBodySummary.expiredCount > 0 ? .warning : .neutral,
                symbol: "clock.badge.exclamationmark",
                compact: true
            )
            MetricTile(
                label: self.model.text(.labelDiagnosticRequestBodiesNewest),
                value: self.model.reasoningCacheTimestampText(self.model.diagnosticRequestBodySummary.newestCreatedAt),
                footnote: self.model.text(.labelLastRefreshed),
                tone: .neutral,
                symbol: "clock.arrow.circlepath",
                compact: true
            )
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    self.accountPicker
                    self.olderThanPicker
                }

                VStack(alignment: .leading, spacing: 12) {
                    self.accountPicker
                    self.olderThanPicker
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    self.clearExpiredButton
                    self.clearOlderButton
                    self.clearAccountButton
                    self.clearAllButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    self.clearExpiredButton
                    self.clearOlderButton
                    self.clearAccountButton
                    self.clearAllButton
                }
            }
        }
        .padding(.top, 2)
    }

    private var diagnosticActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormFieldPanel(title: self.model.text(.labelDiagnosticRequestBodiesOlderThan)) {
                Picker(
                    self.model.text(.labelDiagnosticRequestBodiesOlderThan),
                    selection: self.$model.diagnosticRequestBodyOlderThanSeconds
                ) {
                    ForEach(ReasoningCacheOlderThanPreset.allCases) { preset in
                        Text(self.model.reasoningCacheOlderThanLabel(preset.rawValue)).tag(preset.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(self.model.diagnosticRequestBodyIsClearing)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    self.clearExpiredDiagnosticButton
                    self.clearOlderDiagnosticButton
                    self.clearAllDiagnosticButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    self.clearExpiredDiagnosticButton
                    self.clearOlderDiagnosticButton
                    self.clearAllDiagnosticButton
                }
            }
        }
        .padding(.top, 2)
    }

    private var accountPicker: some View {
        FormFieldPanel(title: self.model.text(.labelReasoningCacheAccount)) {
            Picker(
                self.model.text(.labelReasoningCacheAccount),
                selection: self.$model.reasoningCacheSelectedAccountKey
            ) {
                if self.model.reasoningCacheAccountOptions.isEmpty {
                    Text(self.model.text(.statusNoData)).tag("")
                } else {
                    ForEach(self.model.reasoningCacheAccountOptions) { account in
                        Text("\(account.accountLabel) · \(account.entryCount)").tag(account.accountKey)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(self.model.reasoningCacheAccountOptions.isEmpty || self.model.reasoningCacheIsClearing)
        }
    }

    private var olderThanPicker: some View {
        FormFieldPanel(title: self.model.text(.labelReasoningCacheOlderThan)) {
            Picker(
                self.model.text(.labelReasoningCacheOlderThan),
                selection: self.$model.reasoningCacheOlderThanSeconds
            ) {
                ForEach(ReasoningCacheOlderThanPreset.allCases) { preset in
                    Text(self.model.reasoningCacheOlderThanLabel(preset.rawValue)).tag(preset.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(self.model.reasoningCacheIsClearing)
        }
    }

    private var clearExpiredButton: some View {
        Button(self.model.text(.actionClearExpiredReasoningCache)) {
            Task { await self.model.clearExpiredReasoningCache() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(self.model.reasoningCacheIsClearing)
    }

    private var clearOlderButton: some View {
        Button(self.model.text(.actionClearReasoningCacheOlderThan)) {
            Task { await self.model.clearReasoningCacheOlderThanSelectedPreset() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(!self.model.reasoningCacheHasEntries || self.model.reasoningCacheIsClearing)
    }

    private var clearAccountButton: some View {
        Button(self.model.text(.actionClearReasoningCacheByAccount)) {
            Task { await self.model.clearSelectedAccountReasoningCache() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(!self.model.reasoningCacheSelectedAccountCanClear || self.model.reasoningCacheIsClearing)
    }

    private var clearAllButton: some View {
        Button(self.model.text(.actionClearAllReasoningCache)) {
            Task { await self.model.clearAllReasoningCache() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .danger))
        .disabled(!self.model.reasoningCacheHasEntries || self.model.reasoningCacheIsClearing)
    }

    private var clearExpiredDiagnosticButton: some View {
        Button(self.model.text(.actionClearExpiredDiagnosticRequestBodies)) {
            Task { await self.model.clearExpiredDiagnosticRequestBodies() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(self.model.diagnosticRequestBodyIsClearing)
    }

    private var clearOlderDiagnosticButton: some View {
        Button(self.model.text(.actionClearDiagnosticRequestBodiesOlderThan)) {
            Task { await self.model.clearDiagnosticRequestBodiesOlderThanSelectedPreset() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(!self.model.diagnosticRequestBodyHasEntries || self.model.diagnosticRequestBodyIsClearing)
    }

    private var clearAllDiagnosticButton: some View {
        Button(self.model.text(.actionClearAllDiagnosticRequestBodies)) {
            Task { await self.model.clearAllDiagnosticRequestBodies() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .danger))
        .disabled(!self.model.diagnosticRequestBodyHasEntries || self.model.diagnosticRequestBodyIsClearing)
    }

    private var accountSummary: some View {
        FormFieldPanel(title: self.model.text(.labelAccounts)) {
            if self.model.reasoningCacheAccountOptions.isEmpty {
                Text(self.model.text(.helperReasoningCacheNoEntries))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .dashboardFieldChrome()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.model.reasoningCacheAccountOptions) { account in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(account.accountLabel)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(account.entryCount)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Text(self.model.reasoningCacheTimestampText(account.newestTouchedAt))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(12)
                .dashboardFieldChrome()
            }
        }
    }

    private let metricColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10),
    ]

    private func refresh() {
        Task {
            await self.model.loadReasoningCacheSummary()
            await self.model.loadDiagnosticRequestBodySummary()
        }
    }
}
#endif
