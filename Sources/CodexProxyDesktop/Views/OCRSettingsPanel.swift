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
                        Text(self.model.providerText(provider)).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            FormFieldPanel(title: self.model.text(.labelSelectedOCRModel)) {
                switch self.model.settings.ocrModel.provider {
                case .openAICompatible:
                    self.onlineModelPicker
                case .localMLX:
                    self.localModelPicker
                }
            }

        }
        .task(id: self.model.settings.ocrModel.provider) {
            guard self.model.settings.ocrModel.provider == .localMLX else { return }
            await self.model.refreshLocalOCRModels()
        }
    }

    private var onlineModelPicker: some View {
        Group {
            if self.model.settings.ocrModel.onlineProfiles.isEmpty {
                Text(self.model.localized(zh: "还没有在线 OCR 模型，请打开模型管理新增。", en: "No online OCR model yet. Open the model manager to add one."))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(
                    self.model.text(.labelSelectedOCRModel),
                    selection: self.$model.settings.ocrModel.selectedOnlineProfileID
                ) {
                    ForEach(self.model.settings.ocrModel.onlineProfiles) { profile in
                        Text(profile.displayLabel).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .dashboardFieldChrome()
            }
        }
    }

    private var localModelPicker: some View {
        Picker(
            self.model.text(.labelSelectedOCRModel),
            selection: self.$model.settings.ocrModel.localMLX.selectedModelID
        ) {
            ForEach(self.localModelDescriptors) { descriptor in
                Text(descriptor.displayName).tag(descriptor.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .dashboardFieldChrome()
    }

    private var localModelDescriptors: [LocalOCRModelDescriptor] {
        let responseDescriptors = self.model.localOCRModelsResponse.models.map(\.descriptor)
        if responseDescriptors.isEmpty == false {
            return responseDescriptors
        }
        return LocalOCRModelDescriptor.recommendedModels
    }
}
#endif
