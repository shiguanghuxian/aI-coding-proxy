#if os(macOS)
import CodexProxyCore
import SwiftUI

struct OCRSettingsPanel: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SettingsInsetPanel(
            title: self.model.text(.sectionOCRModel),
            subtitle: self.model.text(.helperOCRModelSettings)
        ) {
            FormFieldPanel(title: self.model.text(.statusEnabled)) {
                Toggle(self.model.text(.statusEnabled), isOn: self.$model.settings.ocrModel.enabled)
                    .toggleStyle(.switch)
            }

            FormFieldPanel(title: self.model.text(.labelOCRProvider)) {
                Picker(self.model.text(.labelOCRProvider), selection: self.$model.settings.ocrModel.provider) {
                    ForEach(OCRModelProvider.allCases, id: \.self) { provider in
                        Text(self.providerText(provider)).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .dashboardFieldChrome()
            }

            switch self.model.settings.ocrModel.provider {
            case .openAICompatible:
                self.openAICompatibleFields
            case .localMLX:
                self.localMLXFields
            }

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
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 132)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelOCRDebugMode)) {
                Toggle(self.model.text(.labelOCRDebugMode), isOn: self.$model.settings.ocrModel.debugMode)
                    .toggleStyle(.switch)
            }
        }
        .task(id: self.model.settings.ocrModel.provider) {
            guard self.model.settings.ocrModel.provider == .localMLX else { return }
            await self.model.refreshLocalOCRModels()
        }
    }

    private var openAICompatibleFields: some View {
        Group {
            FormFieldPanel(title: self.model.text(.labelOCRModel)) {
                TextField(self.model.text(.labelOCRModel), text: self.$model.settings.ocrModel.model)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelOCRAPIKey)) {
                SecureField(self.model.text(.labelOCRAPIKey), text: self.$model.settings.ocrModel.apiKey)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }

            FormFieldPanel(title: self.model.text(.labelOCRBaseURL)) {
                TextField(self.model.text(.labelOCRBaseURL), text: self.$model.settings.ocrModel.baseURL)
                    .textFieldStyle(.plain)
                    .dashboardFieldChrome()
            }
        }
    }

    private var localMLXFields: some View {
        SettingsInsetPanel(
            title: self.model.text(.sectionLocalOCRModels),
            subtitle: self.model.text(.helperLocalOCRModels)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                self.localMLXRuntimeBar
                Text(self.model.text(.helperLocalOCRLowResourceMode))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                self.localMLXConfigFields
                self.localMLXModelList
                Text(self.model.text(.helperLocalOCRPrivacy))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localMLXRuntimeBar: some View {
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

    private var localMLXConfigFields: some View {
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
                    TextField(
                        self.model.text(.labelOCRModelCachePath),
                        text: self.$model.settings.ocrModel.localMLX.modelCachePath
                    )
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

            FormFieldPanel(title: self.model.text(.labelAutoStart)) {
                Toggle(self.model.text(.labelAutoStart), isOn: self.$model.settings.ocrModel.localMLX.autoStart)
                    .toggleStyle(.switch)
            }

            Button(self.model.text(.actionUseLowResourceOCRPreset)) {
                self.model.applyLowResourceLocalOCRPreset()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
        }
    }

    private var localMLXModelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if self.model.localOCRModelsIsRefreshing, self.model.localOCRModelsResponse.models.isEmpty {
                ProgressView()
            }

            ForEach(self.model.localOCRModelsResponse.models) { status in
                LocalOCRModelRow(model: self.model, status: status)
            }
        }
    }

    private func providerText(_ provider: OCRModelProvider) -> String {
        switch provider {
        case .openAICompatible:
            return self.model.localized(zh: "OpenAI 兼容", en: "OpenAI Compatible")
        case .localMLX:
            return "Local MLX"
        }
    }
}

private struct LocalOCRModelRow: View {
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
                self.modelActions
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

    private var modelActions: some View {
        HStack(spacing: 6) {
            Button(self.model.text(.actionUseLocalOCRModel)) {
                self.model.selectLocalOCRModel(self.status.descriptor)
            }
            .buttonStyle(AppActionButtonStyle(kind: self.isSelected ? .secondary : .primary))
            .disabled(self.isSelected)

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
#endif
