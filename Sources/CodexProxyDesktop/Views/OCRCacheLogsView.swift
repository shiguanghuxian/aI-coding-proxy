#if os(macOS)
import CodexProxyCore
import SwiftUI

struct OCRCacheLogsView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ShellBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        self.header
                        self.cachePanel
                        self.recognitionLogPanel
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }

                ToastStackView(
                    banners: self.model.banners,
                    dismissTitle: self.model.text(.commonDismiss),
                    topPadding: proxy.safeAreaInsets.top + 18,
                    trailingPadding: 24
                ) { id in
                    self.model.dismissBanner(id: id)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 700)
        .compactOverlayScrollbars()
        .sheet(isPresented: self.$model.isOCRRecognitionResultPresented) {
            OCRRecognitionResultSheet(model: self.model)
        }
    }

    private var header: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                self.headerText(palette: palette)
                Spacer(minLength: 12)
                self.refreshButton(palette: palette)
            }

            VStack(alignment: .leading, spacing: 10) {
                self.headerText(palette: palette)
                self.refreshButton(palette: palette)
            }
        }
        .padding(.horizontal, 2)
    }

    private func headerText(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.model.text(.ocrCacheLogsWindowTitle))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.text(.ocrCacheLogsWindowSubtitle))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshButton(palette: AppearancePalette) -> some View {
        Button(self.model.text(.actionRefreshOCRCache)) {
            Task { await self.model.refreshOCRCacheLogsWindowData() }
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, symbol: "arrow.clockwise"))
        .disabled(self.model.ocrCacheIsRefreshing || self.model.ocrRecognitionLogsIsRefreshing)
    }

    private var cachePanel: some View {
        SectionCard(
            title: self.model.text(.sectionOCRCache),
            subtitle: self.model.text(.helperOCRCache)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                self.privacyNotice
                self.metrics
                self.actions
            }
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

    private var recognitionLogPanel: some View {
        SectionCard(
            title: self.model.text(.sectionOCRRecognitionLogs),
            subtitle: self.model.text(.helperOCRRecognitionLogs)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                self.recognitionLogPrivacyNotice
                self.recognitionLogControls
                self.recognitionLogList
            }
        }
    }

    private var recognitionLogPrivacyNotice: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "list.bullet.rectangle.portrait.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.info)
                .frame(width: 16, height: 16)
            Text(self.model.text(.helperOCRRecognitionLogPrivacy))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.infoSoft.opacity(self.colorScheme == .dark ? 0.28 : 0.52))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.infoBorder.opacity(self.colorScheme == .dark ? 0.36 : 0.50), lineWidth: 1)
        )
    }

    private var recognitionLogControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                self.recognitionStatusPicker
                self.refreshRecognitionLogsButton
            }
            VStack(alignment: .leading, spacing: 10) {
                self.recognitionStatusPicker
                self.refreshRecognitionLogsButton
            }
        }
        .onChange(of: self.model.ocrRecognitionLogStatusFilter) { _, _ in
            Task { await self.model.loadOCRRecognitionLogs() }
        }
    }

    private var recognitionStatusPicker: some View {
        Picker(
            self.model.text(.labelOCRRecognitionStatus),
            selection: self.$model.ocrRecognitionLogStatusFilter
        ) {
            Text(self.model.text(.statusOCRAll)).tag(OCRRecognitionLogStatus?.none)
            ForEach(OCRRecognitionLogStatus.allCases, id: \.self) { status in
                Text(self.ocrStatusText(status)).tag(Optional(status))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(self.model.ocrRecognitionLogsIsRefreshing)
    }

    private var refreshRecognitionLogsButton: some View {
        Button(self.model.text(.actionRefreshOCRRecognitionLogs)) {
            Task { await self.model.loadOCRRecognitionLogs() }
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary))
        .disabled(self.model.ocrRecognitionLogsIsRefreshing)
    }

    private var recognitionLogList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.model.ocrRecognitionLogPage.entries.isEmpty {
                Text(self.model.text(.placeholderNoOCRRecognitionLogs))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(self.model.ocrRecognitionLogPage.entries) { entry in
                    OCRRecognitionLogRow(
                        model: self.model,
                        entry: entry,
                        statusText: self.ocrStatusText(entry.status),
                        hashText: self.ocrHashText(entry.imageHash)
                    )
                }
            }
        }
    }

    private let metricColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10),
    ]

    private func ocrStatusText(_ status: OCRRecognitionLogStatus) -> String {
        switch status {
        case .skipped:
            return self.model.text(.statusOCRSkipped)
        case .cacheHit:
            return self.model.text(.statusOCRCacheHit)
        case .recognized:
            return self.model.text(.statusOCRRecognized)
        case .failed:
            return self.model.text(.statusOCRFailed)
        }
    }

    private func ocrHashText(_ hash: String?) -> String {
        guard let hash, hash.isEmpty == false else { return "-" }
        return String(hash.prefix(12))
    }
}

private struct OCRRecognitionLogRow: View {
    @ObservedObject var model: DesktopAppModel
    let entry: OCRRecognitionLogEntry
    let statusText: String
    let hashText: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(self.statusText)
                        .font(.system(size: 11, weight: .semibold))
                    Text("#\(self.entry.imageIndex)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(self.entry.endpoint.isEmpty ? "-" : self.entry.endpoint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Text(DesktopDateTimeFormat.string(fromUnixSeconds: self.entry.createdAt))
                    Text(self.entry.accountLabel.isEmpty ? self.entry.accountKey : self.entry.accountLabel)
                    Text(self.entry.requestedModel.isEmpty ? "-" : self.entry.requestedModel)
                    Text("\(self.entry.latencyMS)ms")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                HStack(spacing: 10) {
                    Text("\(self.model.text(.labelOCRImageHash)): \(self.hashText)")
                    Text("\(self.model.text(.labelOCRCacheHit)): \(self.entry.cacheHit ? "Y" : "N")")
                    if let error = self.entry.errorSummary, error.isEmpty == false {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Button(self.model.text(.actionViewOCRResult)) {
                Task { await self.model.loadOCRRecognitionResult(for: self.entry) }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.entry.imageHash == nil || self.model.ocrRecognitionResultIsLoading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}

private struct OCRRecognitionResultSheet: View {
    @ObservedObject var model: DesktopAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(self.model.text(.labelOCRResult))
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Button(self.model.text(.commonDismiss)) {
                    self.dismiss()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }

            ScrollView {
                Text(self.resultText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: 560, height: 360)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .padding(18)
    }

    private var resultText: String {
        guard let result = self.model.ocrRecognitionResult else {
            return self.model.text(.statusLoadingLogs)
        }
        if result.available, let text = result.text, text.isEmpty == false {
            return text
        }
        return result.message ?? self.model.text(.helperOCRResultUnavailable)
    }
}
#endif
