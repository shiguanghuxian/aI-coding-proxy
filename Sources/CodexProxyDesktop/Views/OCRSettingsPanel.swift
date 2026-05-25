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
    }

    private func providerText(_ provider: OCRModelProvider) -> String {
        switch provider {
        case .openAICompatible:
            return self.model.localized(zh: "OpenAI 兼容", en: "OpenAI Compatible")
        }
    }
}
#endif
