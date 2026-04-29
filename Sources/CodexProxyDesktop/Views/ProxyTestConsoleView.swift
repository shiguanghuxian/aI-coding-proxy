#if os(macOS)
import SwiftUI

struct ProxyTestConsoleView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    private let metricColumns = [
        GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 14),
    ]

    var body: some View {
        GeometryReader { proxy in
            let palette = AppearanceStore.palette(for: self.colorScheme)

            ZStack {
                ShellBackground()

                VStack(alignment: .leading, spacing: 18) {
                    self.header(palette: palette)

                    HSplitView {
                        ScrollView {
                            self.requestColumn
                                .padding(.trailing, 9)
                        }
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        ScrollView {
                            self.resultColumn
                                .padding(.leading, 9)
                        }
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(24)
            }
            .overlay(alignment: .topTrailing) {
                ToastStackView(
                    banners: self.model.proxyTestBanners,
                    dismissTitle: self.model.text(.commonDismiss),
                    topPadding: proxy.safeAreaInsets.top + 18,
                    trailingPadding: 20
                ) { id in
                    self.model.dismissProxyTestBanner(id: id)
                }
            }
        }
        .frame(minWidth: 1260, minHeight: 820)
        .compactOverlayScrollbars()
    }

    @ViewBuilder
    private func header(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(self.model.text(.proxyTestTitle))
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        Text(self.model.proxyTestSubtitleText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 20)

                    HStack(spacing: 10) {
                        StatusPill(
                            text: self.model.proxyTestStatusText(),
                            tone: self.model.proxyTestStatusTone()
                        )

                        if self.model.proxyTestRunState == .loadingModels || self.model.proxyTestRunState == .running {
                            ProgressView()
                                .controlSize(.small)
                                .tint(palette.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(palette.panelMuted.opacity(0.95)))
                                .overlay(Capsule().stroke(palette.border, lineWidth: 1))
                        }

                        Button(self.model.text(.commonReload)) {
                            Task { await self.model.refreshProxyTestConsole() }
                        }
                        .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent))
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(self.model.text(.proxyTestTitle))
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        Text(self.model.proxyTestSubtitleText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        StatusPill(
                            text: self.model.proxyTestStatusText(),
                            tone: self.model.proxyTestStatusTone()
                        )

                        Button(self.model.text(.commonReload)) {
                            Task { await self.model.refreshProxyTestConsole() }
                        }
                        .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent))
                    }
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
                    .frame(width: 168, height: 4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var requestColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard(
                title: self.model.text(.sectionAccessInfo),
                subtitle: self.model.proxyTestHealthHintText,
                accessory: StatusPill(
                    text: self.model.proxyTestStatusText(),
                    tone: self.model.proxyTestStatusTone()
                )
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ProxyTestCompactAccessRow(
                        label: self.model.text(.labelEndpoint),
                        value: self.model.displayValue(self.model.proxyTestDraft.endpointURL),
                        actionTitle: self.model.text(.actionCopyEndpoint)
                    ) {
                        self.model.copyCurrentProxyTestEndpoint()
                    }

                    ProxyTestCompactAccessRow(
                        label: self.model.text(.labelAPIKey),
                        value: self.model.displayValue(self.model.proxyTestDraft.apiKey),
                        actionTitle: self.model.text(.actionCopyAPIKey)
                    ) {
                        self.model.copyCurrentProxyTestAPIKey()
                    }
                }
            }

            SectionCard(
                title: self.model.text(.sectionTestRequest),
                subtitle: self.model.text(.proxyTestRequestHint)
            ) {
                if let compatibilityIssue = self.model.proxyTestCompatibilityIssueText {
                    ProxyTestCompatibilityHint(text: compatibilityIssue)
                }

                self.testAccountField

                FormFieldPanel(title: self.model.text(.labelInterface)) {
                    Picker(
                        self.model.text(.labelInterface),
                        selection: Binding(
                            get: { self.model.proxyTestDraft.endpoint },
                            set: { self.model.updateProxyTestEndpoint($0) }
                        )
                    ) {
                        ForEach(ProxyTestEndpoint.allCases) { endpoint in
                            Text(self.model.label(for: endpoint)).tag(endpoint)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(self.model.proxyTestRunState == .running)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        self.modelField
                        self.streamField
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        self.modelField
                        self.streamField
                    }
                }

                FormFieldPanel(title: self.model.text(.labelSystemPrompt)) {
                    PromptEditor(
                        text: Binding(
                            get: { self.model.proxyTestDraft.systemPrompt },
                            set: { self.model.proxyTestDraft.systemPrompt = $0 }
                        ),
                        placeholder: self.model.text(.placeholderProxyTestSystem)
                    )
                    .disabled(self.model.proxyTestRunState == .running)
                }

                FormFieldPanel(title: self.model.text(.labelUserPrompt)) {
                    PromptEditor(
                        text: Binding(
                            get: { self.model.proxyTestDraft.userPrompt },
                            set: { self.model.proxyTestDraft.userPrompt = $0 }
                        ),
                        placeholder: self.model.text(.placeholderProxyTestPrompt)
                    )
                    .disabled(self.model.proxyTestRunState == .running)
                }

                if self.model.proxyTestDraft.endpoint == .anthropicMessages
                    || self.model.proxyTestDraft.endpoint == .geminiGenerateContent
                {
                    FormFieldPanel(title: self.model.text(.labelToolsJSON)) {
                        PromptEditor(
                            text: Binding(
                                get: { self.model.proxyTestDraft.toolsJSON },
                                set: { self.model.proxyTestDraft.toolsJSON = $0 }
                            ),
                            placeholder: self.model.text(.placeholderProxyTestTools)
                        )
                        .disabled(self.model.proxyTestRunState == .running)
                    }
                }

                HStack(spacing: 10) {
                    Button(self.model.text(.actionSendTest)) {
                        self.model.startProxyTest()
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .primary))
                    .disabled(!self.model.proxyTestCanSend)

                    Button(self.model.text(.actionCancelTest)) {
                        self.model.cancelProxyTest()
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    .disabled(self.model.proxyTestRunState != .running)
                }

                ConsoleTextPanel(
                    title: self.model.text(.labelRequestPreview),
                    value: self.model.proxyTestRequestPreview
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var resultColumn: some View {
        SectionCard(
            title: self.model.text(.sectionTestResult),
            subtitle: self.model.proxyTestResultHintText
        ) {
            LazyVGrid(columns: self.metricColumns, spacing: 14) {
                MetricTile(
                    label: self.model.text(.labelStatus),
                    value: self.model.proxyTestStatusText(),
                    footnote: self.model.text(.labelHTTPStatus),
                    tone: self.model.proxyTestStatusTone() == .danger ? .danger : (self.model.proxyTestStatusTone() == .warning ? .warning : .accent),
                    symbol: "bolt.badge.checkmark"
                )

                MetricTile(
                    label: self.model.text(.labelHTTPStatus),
                    value: self.statusValue(self.model.proxyTestResult?.httpStatus),
                    footnote: self.model.text(.sectionRuntime),
                    tone: self.httpTone(self.model.proxyTestResult?.httpStatus),
                    symbol: "network"
                )

                MetricTile(
                    label: self.model.text(.labelLatency),
                    value: self.latencyValue(self.model.proxyTestResult?.latencyMilliseconds),
                    footnote: self.model.text(.sectionTraffic),
                    tone: .neutral,
                    symbol: "timer"
                )

                MetricTile(
                    label: self.model.text(.labelOutputTokens),
                    value: self.tokenValue(self.model.proxyTestResult?.usage?.totalTokens),
                    footnote: self.model.text(.labelInputTokens),
                    tone: .success,
                    symbol: "sum"
                )
                .help(
                    self.model.proxySummaryTokenHelp(self.model.proxyTestResult?.usage?.totalTokens)
                    ?? self.model.text(.statusNoData)
                )
            }

            if let result = self.model.proxyTestResult {
                if let summary = result.errorSummary, !summary.isEmpty {
                    FormFieldPanel(title: self.model.text(.labelLastError)) {
                        Text(summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .dashboardFieldChrome()
                    }
                }

                ConsoleTextPanel(
                    title: self.model.text(.labelResponseText),
                    value: result.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? self.model.text(.placeholderProxyTestResult)
                        : result.assistantText,
                    minHeight: 180
                )

                if !result.rawResponseJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ConsoleTextPanel(
                        title: self.model.text(.labelRawResponse),
                        value: result.rawResponseJSON,
                        minHeight: 200
                    )
                }

                if !result.rawSSETranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ConsoleTextPanel(
                        title: self.model.text(.labelStreamTranscript),
                        value: result.rawSSETranscript,
                        minHeight: 200
                    )
                }

                if let rawError = result.rawError, !rawError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ConsoleTextPanel(
                        title: self.model.text(.labelLastError),
                        value: rawError,
                        minHeight: 120
                    )
                }
            } else {
                EmptyStatePanel(
                    title: self.model.text(.sectionTestResult),
                    detail: self.model.text(.placeholderProxyTestResult)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var testAccountField: some View {
        FormFieldPanel(title: self.model.text(.labelTestAccount)) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    self.model.text(.labelTestAccount),
                    selection: Binding(
                        get: { self.model.proxyTestDraft.selectedAccountKey },
                        set: { self.model.setProxyTestSelectedAccountKey($0) }
                    )
                ) {
                    ForEach(self.model.proxyTestAccountOptions) { option in
                        Text(option.title).tag(option.accountKey)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dashboardFieldChrome()
                .disabled(self.model.proxyTestRunState == .running)

                if !self.model.proxyTestSelectedAccountKey.isEmpty {
                    ProxyTestSelectedAccountHint(
                        authText: self.model.proxyTestSelectedAccount.map { self.model.accountAuthModeText($0) },
                        authTone: self.model.proxyTestSelectedAccount?.authMode.isManualAPIKey == true ? .warning : .accent,
                        statusText: self.model.proxyTestSelectedAccountStatusText(),
                        statusTone: self.model.proxyTestSelectedAccountStatusTone(),
                        detail: self.model.proxyTestSelectedAccountDetailText()
                    )
                }
            }
        }
    }

    private var modelField: some View {
        FormFieldPanel(title: self.model.text(.labelModel)) {
            Group {
                if self.model.proxyTestDraft.endpoint.supportsCustomModelEntry {
                    HStack(spacing: 10) {
                        TextField(
                            self.model.text(.labelModel),
                            text: Binding(
                                get: { self.model.proxyTestDraft.model },
                                set: { self.model.proxyTestDraft.model = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).textPrimary)

                        Menu {
                            ForEach(self.model.proxyTestAvailableModels, id: \.self) { candidate in
                                Button(candidate) {
                                    self.model.proxyTestDraft.model = candidate
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppearanceStore.palette(for: self.colorScheme).accent)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(AppearanceStore.palette(for: self.colorScheme).panelMuted.opacity(0.96))
                                )
                                .overlay(
                                    Circle()
                                        .stroke(self.paletteBorder, lineWidth: 1)
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .interactiveCursor(isEnabled: self.model.proxyTestRunState != .running)
                    }
                    .dashboardFieldChrome()
                } else {
                    Picker(
                        self.model.text(.labelModel),
                        selection: Binding(
                            get: { self.model.proxyTestDraft.model },
                            set: { self.model.proxyTestDraft.model = $0 }
                        )
                    ) {
                        ForEach(self.model.proxyTestAvailableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dashboardFieldChrome()
                }
            }
            .disabled(self.model.proxyTestRunState == .running)
        }
    }

    private var streamField: some View {
        FormFieldPanel(title: self.model.text(.labelStream)) {
            Toggle(
                self.model.text(.labelStream),
                isOn: Binding(
                    get: { self.model.proxyTestDraft.stream },
                    set: { self.model.proxyTestDraft.stream = $0 }
                )
            )
            .toggleStyle(.switch)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(paletteFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(self.paletteBorder, lineWidth: 1)
            )
            .disabled(self.model.proxyTestRunState == .running)
        }
    }

    private var paletteFieldBackground: Color {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        return palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.84 : 0.90)
    }

    private var paletteBorder: Color {
        AppearanceStore.palette(for: self.colorScheme).border
    }

    private func statusValue(_ statusCode: Int?) -> String {
        guard let statusCode else { return self.model.text(.statusNoData) }
        return "\(statusCode)"
    }

    private func latencyValue(_ latencyMilliseconds: Int?) -> String {
        guard let latencyMilliseconds else { return self.model.text(.statusNoData) }
        return "\(latencyMilliseconds) ms"
    }

    private func tokenValue(_ totalTokens: Int64?) -> String {
        self.model.proxySummaryTokenText(totalTokens)
    }

    private func httpTone(_ statusCode: Int?) -> MetricTile.Tone {
        guard let statusCode else { return .neutral }
        switch statusCode {
        case 200..<300:
            return .success
        case 400..<500:
            return .warning
        case 500...:
            return .danger
        default:
            return .neutral
        }
    }
}

private struct ProxyTestCompactAccessRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                self.content(palette: palette)
                Spacer(minLength: 12)
                self.copyButton(palette: palette)
            }

            VStack(alignment: .leading, spacing: 10) {
                self.content(palette: palette)
                HStack {
                    Spacer()
                    self.copyButton(palette: palette)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.84 : 0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func content(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textMuted)
            Text(self.value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyButton(palette: AppearancePalette) -> some View {
        Button(self.actionTitle, action: self.action)
            .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent))
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ProxyTestCompatibilityHint: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.warning)
                .padding(.top, 2)

            Text(self.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("proxy-test-legacy-transport-hint-text")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.warningSoft.opacity(self.colorScheme == .dark ? 0.52 : 0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.warning.opacity(self.colorScheme == .dark ? 0.30 : 0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.text)
        .accessibilityIdentifier("proxy-test-legacy-transport-hint")
    }
}

private struct ProxyTestSelectedAccountHint: View {
    @Environment(\.colorScheme) private var colorScheme

    let authText: String?
    let authTone: StatusPill.Tone
    let statusText: String
    let statusTone: StatusPill.Tone
    let detail: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let authText, !authText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    StatusPill(text: authText, tone: self.authTone)
                }
                StatusPill(text: self.statusText, tone: self.statusTone)
            }

            Text(self.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.panelMuted.opacity(self.colorScheme == .dark ? 0.88 : 0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct PromptEditor: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var text: String
    let placeholder: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ZStack(alignment: .topLeading) {
            TextEditor(text: self.$text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: 112)

            if self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(self.placeholder)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.84 : 0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct ConsoleTextPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String
    var minHeight: CGFloat = 160

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            Text(self.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            ScrollView {
                Text(self.value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(minHeight: self.minHeight)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.consoleBackground.opacity(self.colorScheme == .dark ? 0.92 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
        }
    }
}
#endif
