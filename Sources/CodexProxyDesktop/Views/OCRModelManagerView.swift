#if os(macOS)
import CodexProxyCore
import SwiftUI

struct OCRModelManagerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DesktopAppModel
    @State private var editingOnlineProfile: OnlineOCRModelProfile?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ShellBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        self.header
                        self.commonSettingsPanel
                        self.onlineModelsPanel
                        self.localModelsPanel
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
        .task {
            await self.model.refreshLocalOCRModels()
        }
        .sheet(item: self.$editingOnlineProfile) { profile in
            OnlineOCRProfileEditorSheet(
                model: self.model,
                profile: profile,
                onSave: { updated in
                    self.model.upsertOnlineOCRProfile(updated)
                    self.editingOnlineProfile = nil
                },
                onCancel: {
                    self.editingOnlineProfile = nil
                }
            )
        }
        .sheet(isPresented: self.ocrTestSheetBinding) {
            OCRModelTestSheet(model: self.model)
        }
    }

    private var ocrTestSheetBinding: Binding<Bool> {
        Binding(
            get: { self.model.ocrModelTestDraft != nil },
            set: { isPresented in
                if isPresented == false {
                    self.model.dismissOCRModelTest()
                }
            }
        )
    }

    private var header: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                self.headerText(palette: palette)
                Spacer(minLength: 12)
                self.headerActions
            }

            VStack(alignment: .leading, spacing: 10) {
                self.headerText(palette: palette)
                self.headerActions
            }
        }
        .padding(.horizontal, 2)
    }

    private func headerText(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.model.text(.ocrModelManagerWindowTitle))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Text(self.model.text(.ocrModelManagerWindowSubtitle))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button(self.model.text(.actionOpenOCRCacheLogs)) {
                self.model.openOCRCacheLogsWindow()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))

            Button(self.model.text(.actionSaveOCRSettings)) {
                Task { await self.model.saveSettings() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        }
    }

    private var commonSettingsPanel: some View {
        SectionCard(
            title: self.model.text(.sectionOCRCommonSettings),
            subtitle: self.model.text(.helperOCRModelManager)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    FormFieldPanel(title: self.model.text(.labelOCRTimeout)) {
                        TextField(
                            self.model.text(.labelOCRTimeout),
                            value: self.$model.settings.ocrModel.timeout,
                            formatter: NumberFormatter()
                        )
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                    }

                    FormFieldPanel(title: self.model.text(.labelOCRMaxImageSize)) {
                        TextField(
                            self.model.text(.labelOCRMaxImageSize),
                            value: self.$model.settings.ocrModel.maxImageSize,
                            formatter: NumberFormatter()
                        )
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                    }
                }

                FormFieldPanel(title: self.model.text(.labelOCRPrompt)) {
                    TextEditor(text: self.$model.settings.ocrModel.prompt)
                        .font(.system(size: 11, weight: .medium))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 128)
                        .dashboardFieldChrome()
                }

                FormFieldPanel(title: self.model.text(.labelOCRDebugMode)) {
                    Toggle(self.model.text(.labelOCRDebugMode), isOn: self.$model.settings.ocrModel.debugMode)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var onlineModelsPanel: some View {
        SectionCard(
            title: self.model.text(.sectionOnlineOCRModels),
            subtitle: self.model.text(.helperOnlineOCRModels),
            accessory: Button(self.model.text(.actionAddOnlineOCRModel)) {
                self.editingOnlineProfile = OnlineOCRModelProfile(
                    label: self.model.localized(zh: "新在线 OCR", en: "New Online OCR")
                )
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if self.model.settings.ocrModel.onlineProfiles.isEmpty {
                    EmptyStatePanel(
                        title: self.model.localized(zh: "还没有在线 OCR 配置", en: "No online OCR profiles yet"),
                        detail: self.model.localized(zh: "新增一个 OpenAI 兼容配置后，就可以在设置页选择它作为当前 OCR 模型。", en: "Add an OpenAI-compatible profile, then select it from the OCR settings tab.")
                    )
                } else {
                    ForEach(self.model.settings.ocrModel.onlineProfiles) { profile in
                        OnlineOCRProfileRow(
                            model: self.model,
                            profile: profile,
                            onEdit: { self.editingOnlineProfile = profile }
                        )
                    }
                }
            }
        }
    }

    private var localModelsPanel: some View {
        SectionCard(
            title: self.model.text(.sectionLocalOCRModels),
            subtitle: self.model.text(.helperLocalOCRModels)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                self.localRuntimeBar
                Text(self.model.text(.helperLocalOCRLowResourceMode))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                self.localConfigFields
                self.localModelList
                Text(self.model.text(.helperLocalOCRPrivacy))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localRuntimeBar: some View {
        HStack(alignment: .center, spacing: 10) {
            let runtime = self.model.localOCRModelsResponse.runtime
            StatusPill(
                text: runtime.running ? self.model.text(.statusRunning) : self.model.text(.statusStopped),
                tone: runtime.running ? .success : .neutral,
                compact: true
            )
            if let modelID = runtime.modelID, modelID.isEmpty == false {
                Text(modelID)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(self.model.text(.actionOpenLocalModelCacheDirectory)) {
                self.model.openLocalOCRModelCacheDirectory()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            Button(self.model.text(.actionRefreshLocalOCRModels)) {
                Task { await self.model.refreshLocalOCRModels() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.model.localOCRModelsIsRefreshing)
            Button(self.model.text(.actionStopLocalOCRRuntime)) {
                Task { await self.model.stopLocalOCRRuntime() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(!runtime.running || self.model.localOCRRuntimeIsStopping)
        }
    }

    private var localConfigFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                FormFieldPanel(title: self.model.text(.labelOCRHFBaseURL)) {
                    TextField(self.model.text(.labelOCRHFBaseURL), text: self.$model.settings.ocrModel.localMLX.hfBaseURL)
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                }
                FormFieldPanel(title: self.model.text(.labelOCRHFToken)) {
                    SecureField(self.model.text(.labelOCRHFToken), text: self.$model.settings.ocrModel.localMLX.hfToken)
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                }
            }

            HStack(alignment: .top, spacing: 10) {
                FormFieldPanel(title: self.model.text(.labelOCRModelCachePath)) {
                    TextField(self.model.text(.labelOCRModelCachePath), text: self.$model.settings.ocrModel.localMLX.modelCachePath)
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                }
                FormFieldPanel(title: self.model.text(.labelOCRRuntimePath)) {
                    TextField(self.model.text(.labelOCRRuntimePath), text: self.$model.settings.ocrModel.localMLX.runtimePath)
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                }
            }

            HStack(alignment: .top, spacing: 10) {
                FormFieldPanel(title: self.model.text(.labelOCRCustomHFRepo)) {
                    TextField(self.model.text(.labelOCRCustomHFRepo), text: self.$model.settings.ocrModel.localMLX.customHFRepo)
                        .textFieldStyle(.plain)
                        .dashboardFieldChrome()
                }
                FormFieldPanel(title: self.model.text(.labelOCRMaxTokens)) {
                    TextField(
                        self.model.text(.labelOCRMaxTokens),
                        value: self.$model.settings.ocrModel.localMLX.maxTokens,
                        formatter: NumberFormatter()
                    )
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
                }
            }

            HStack(alignment: .top, spacing: 10) {
                FormFieldPanel(title: self.model.text(.labelOCRIdleShutdownSeconds)) {
                    TextField(
                        self.model.text(.labelOCRIdleShutdownSeconds),
                        value: self.$model.settings.ocrModel.localMLX.idleShutdownSeconds,
                        formatter: NumberFormatter()
                    )
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
                }
                FormFieldPanel(title: self.model.text(.labelOCRLocalConcurrency)) {
                    Stepper(
                        "\(self.model.settings.ocrModel.localMLX.maxConcurrentRecognitions)",
                        value: self.$model.settings.ocrModel.localMLX.maxConcurrentRecognitions,
                        in: 1...8
                    )
                    .dashboardFieldChrome()
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Toggle(self.model.text(.labelAutoStart), isOn: self.$model.settings.ocrModel.localMLX.autoStart)
                    .toggleStyle(.switch)
                Spacer(minLength: 0)
                Button(self.model.text(.actionUseLowResourceOCRPreset)) {
                    self.model.applyLowResourceLocalOCRPreset()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }
        }
    }

    private var localModelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if self.model.localOCRModelsIsRefreshing, self.model.localOCRModelsResponse.models.isEmpty {
                ProgressView()
            }

            ForEach(self.model.localOCRModelsResponse.models) { status in
                LocalOCRModelManagerRow(model: self.model, status: status)
            }
        }
    }
}

private struct OnlineOCRProfileRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DesktopAppModel
    let profile: OnlineOCRModelProfile
    let onEdit: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(self.profile.displayLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        if self.isSelected {
                            StatusPill(text: self.model.text(.statusCurrent), tone: .success, compact: true)
                        }
                        if self.profile.isReadyForRecognition == false {
                            StatusPill(text: self.model.text(.statusUnavailable), tone: .warning, compact: true)
                        }
                    }
                    Text(self.profile.model.isEmpty ? self.model.text(.statusNoData) : self.profile.model)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(self.profile.baseURL)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                self.actions
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.68 : 0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(self.isSelected ? palette.accent.opacity(0.45) : palette.border, lineWidth: 1)
        )
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(self.model.text(.actionUseLocalOCRModel)) {
                self.model.selectOnlineOCRProfile(id: self.profile.id)
            }
            .buttonStyle(AppActionButtonStyle(kind: self.isSelected ? .secondary : .primary))
            .disabled(self.isSelected)

            Button(self.model.text(.actionEditOnlineOCRModel)) {
                self.onEdit()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))

            Button(self.model.text(.actionTestOCRModel)) {
                self.model.beginOnlineOCRModelTest(profileID: self.profile.id)
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.profile.isReadyForRecognition == false)

            Button(self.model.text(.actionDeleteLocalOCRModel)) {
                self.model.deleteOnlineOCRProfile(id: self.profile.id)
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
        }
    }

    private var isSelected: Bool {
        self.model.settings.ocrModel.selectedOnlineProfileID == self.profile.id
    }
}

private struct LocalOCRModelManagerRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DesktopAppModel
    let status: LocalOCRModelStatus

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(self.status.descriptor.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        if self.status.descriptor.recommended {
                            StatusPill(text: self.model.text(.statusLocalOCRRecommended), tone: .success, compact: true)
                        }
                        if self.status.descriptor.id == "mlx-community/Qwen2.5-VL-3B-Instruct-4bit" {
                            StatusPill(text: self.model.text(.statusLocalOCRLowResource), tone: .accent, compact: true)
                        }
                        if self.status.descriptor.experimental {
                            StatusPill(text: self.model.text(.statusLocalOCRExperimental), tone: .warning, compact: true)
                        }
                    }
                    Text(self.status.descriptor.huggingFaceRepo)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                StatusPill(
                    text: self.model.localOCRModelPhaseText(self.status.phase),
                    tone: self.phaseTone,
                    compact: true
                )
            }

            if self.status.phase == .downloading {
                ProgressView(value: self.status.progress)
            }

            HStack(alignment: .center, spacing: 8) {
                Text(self.metadataText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                self.actions
            }

            if self.status.detail.isEmpty == false {
                Text(self.status.detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.68 : 0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(self.isSelected ? palette.accent.opacity(0.45) : palette.border, lineWidth: 1)
        )
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(self.model.text(.actionUseLocalOCRModel)) {
                self.model.selectLocalOCRModel(self.status.descriptor)
            }
            .buttonStyle(AppActionButtonStyle(kind: self.isSelected ? .secondary : .primary))
            .disabled(self.isSelected)

            Button(self.model.text(.actionTestOCRModel)) {
                self.model.beginLocalOCRModelTest(modelID: self.status.descriptor.id)
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.status.phase != .installed)

            Button(self.model.text(.actionOpenLocalModelDirectory)) {
                self.model.openLocalOCRModelDirectory(self.status)
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.status.phase != .installed)

            Button(self.model.text(.actionDownloadLocalOCRModel)) {
                Task { await self.model.downloadLocalOCRModel(self.status.descriptor) }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.operationDisabled)

            Button(self.model.text(.actionVerifyLocalOCRModel)) {
                Task { await self.model.verifyLocalOCRModel(self.status.descriptor) }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.operationDisabled || self.status.phase == .notInstalled)

            Button(self.model.text(.actionDeleteLocalOCRModel)) {
                Task { await self.model.deleteLocalOCRModel(self.status.descriptor) }
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.operationDisabled || self.status.phase == .notInstalled)
        }
    }

    private var isSelected: Bool {
        self.model.settings.ocrModel.localMLX.selectedModelID == self.status.descriptor.id
    }

    private var operationDisabled: Bool {
        self.model.localOCRModelOperationInProgress(self.status.descriptor)
            || self.status.phase == .downloading
    }

    private var phaseTone: StatusPill.Tone {
        switch self.status.phase {
        case .installed:
            return .success
        case .downloading:
            return .accent
        case .failed:
            return .danger
        case .notInstalled:
            return .neutral
        }
    }

    private var metadataText: String {
        let size = self.status.descriptor.sizeBytes > 0
            ? ByteCountFormatter.string(fromByteCount: self.status.descriptor.sizeBytes, countStyle: .file)
            : self.model.localized(zh: "未知大小", en: "Unknown size")
        return [
            self.status.descriptor.quantization,
            size,
            self.model.localized(
                zh: "建议内存 \(self.status.descriptor.minimumMemoryGB)GB+",
                en: "\(self.status.descriptor.minimumMemoryGB)GB+ memory"
            ),
        ].filter { $0.isEmpty == false }.joined(separator: " · ")
    }
}

private struct OnlineOCRProfileEditorSheet: View {
    @ObservedObject var model: DesktopAppModel
    @State private var draft: OnlineOCRModelProfile
    let onSave: (OnlineOCRModelProfile) -> Void
    let onCancel: () -> Void

    init(
        model: DesktopAppModel,
        profile: OnlineOCRModelProfile,
        onSave: @escaping (OnlineOCRModelProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self._draft = State(initialValue: profile)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.model.text(.sectionOnlineOCRModels))
                    .font(.system(size: 18, weight: .bold))
                Text(self.model.text(.helperOnlineOCRModels))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FormFieldPanel(title: self.model.text(.labelOCRModelProfileName)) {
                TextField(self.model.text(.labelOCRModelProfileName), text: self.$draft.label)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelOCRModel)) {
                TextField(self.model.text(.labelOCRModel), text: self.$draft.model)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelOCRBaseURL)) {
                TextField(self.model.text(.labelOCRBaseURL), text: self.$draft.baseURL)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelOCRAPIKey)) {
                SecureField(self.model.text(.labelOCRAPIKey), text: self.$draft.apiKey)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            HStack {
                Spacer(minLength: 0)
                Button(self.model.text(.commonCancel)) {
                    self.onCancel()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                Button(self.model.localized(zh: "保存", en: "Save")) {
                    self.onSave(self.draft)
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct OCRModelTestSheet: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.header
            self.imagePicker
            self.promptEditor
            self.actions
            self.resultView
        }
        .padding(22)
        .frame(width: 680)
        .frame(minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.model.text(.actionTestOCRModel))
                .font(.system(size: 18, weight: .bold))
            Text(self.model.text(.helperOCRTest))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let draft = self.model.ocrModelTestDraft {
                Text(draft.title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var imagePicker: some View {
        FormFieldPanel(title: self.model.text(.labelOCRTestImage)) {
            HStack(spacing: 10) {
                Text(self.model.ocrModelTestDraft?.imageFilename.isEmpty == false ? self.model.ocrModelTestDraft?.imageFilename ?? "" : self.model.text(.statusNoData))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(self.model.text(.actionChooseOCRTestImage)) {
                    self.model.chooseOCRModelTestImage()
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }
        }
    }

    private var promptEditor: some View {
        FormFieldPanel(title: self.model.text(.labelOCRTestPrompt)) {
            TextEditor(
                text: Binding(
                    get: { self.model.ocrModelTestDraft?.prompt ?? OCRModelConfig.defaultPrompt },
                    set: { value in
                        guard var draft = self.model.ocrModelTestDraft else { return }
                        draft.prompt = value
                        self.model.ocrModelTestDraft = draft
                    }
                )
            )
            .font(.system(size: 11, weight: .medium))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 132)
            .dashboardFieldChrome()
        }
    }

    private var actions: some View {
        HStack {
            Spacer(minLength: 0)
            Button(self.model.text(.commonCancel)) {
                self.model.dismissOCRModelTest()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            Button(self.model.text(.actionRunOCRTest)) {
                Task { await self.model.runOCRModelTest() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
            .disabled(self.model.ocrModelTestDraft?.isRunning == true)
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if self.model.ocrModelTestDraft?.isRunning == true {
            ProgressView()
        } else if let result = self.model.ocrModelTestDraft?.result {
            FormFieldPanel(title: self.model.text(.labelOCRResult)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusPill(
                            text: result.cacheHit ? self.model.text(.statusOCRCacheHit) : self.model.text(.statusOCRRecognized),
                            tone: result.cacheHit ? .accent : .success,
                            compact: true
                        )
                        Text("\(result.latencyMS) ms")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(result.imageHash)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ScrollView {
                        Text(result.text)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160, maxHeight: 220)
                }
            }
        }
    }
}
#endif
