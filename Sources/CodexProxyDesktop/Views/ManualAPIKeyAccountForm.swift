#if os(macOS)
import CodexProxyCore
import SwiftUI

struct ManualAPIKeyAccountForm: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    @Binding var draft: DesktopAppModel.ManualAPIKeyDraft
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 8 : 10) {
            FormFieldPanel(title: self.model.text(.labelLabel), compact: self.compact) {
                TextField(
                    self.model.text(.placeholderManualAccountLabel),
                    text: self.$draft.label
                )
                .dashboardFieldChrome(compact: self.compact)
            }

            FormFieldPanel(title: self.model.text(.labelProviderPreset), compact: self.compact) {
                VStack(alignment: .leading, spacing: self.compact ? 6 : 8) {
                    Picker(
                        self.model.text(.labelProviderPreset),
                        selection: Binding(
                            get: { self.draft.providerPreset },
                            set: { newValue in
                                self.draft = self.model.manualAPIKeyDraft(
                                    self.draft,
                                    updatingProviderPreset: newValue
                                )
                            }
                        )
                    ) {
                        ForEach(OpenAICompatibleProviderPreset.allCases, id: \.self) { preset in
                            Text(self.model.providerPresetText(preset)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .dashboardFieldChrome(compact: self.compact)

                    Text(self.model.manualAPIKeyProviderPresetHelp(self.draft.providerPreset))
                        .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(self.compact ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FormFieldPanel(title: self.model.text(.labelAccountBaseURL), compact: self.compact) {
                TextField(
                    self.model.manualAPIKeyBaseURLPlaceholder(for: self.draft.providerPreset),
                    text: self.$draft.baseURL
                )
                .dashboardFieldChrome(compact: self.compact)
            }

            if self.draft.providerPreset == .genericOpenAICompatible {
                FormFieldPanel(title: self.model.text(.labelUpstreamAdapter), compact: self.compact) {
                    VStack(alignment: .leading, spacing: self.compact ? 6 : 8) {
                        ManualAPIKeyUpstreamAdapterSegmentedControl(
                            model: self.model,
                            selection: Binding(
                                get: { self.draft.upstreamAdapter },
                                set: { newValue in
                                    self.draft = self.model.manualAPIKeyDraft(
                                        self.draft,
                                        updatingUpstreamAdapter: newValue
                                    )
                                }
                            ),
                            compact: self.compact
                        )

                        Text(self.model.text(.helperManualAccountUpstreamAdapter))
                            .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(self.compact ? 2 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            FormFieldPanel(title: self.model.text(.labelAPIKey), compact: self.compact) {
                TextField(
                    self.model.text(.placeholderManualAccountAPIKey),
                    text: self.$draft.apiKey
                )
                .textFieldStyle(.plain)
                .font(.system(size: self.compact ? 11 : 12, weight: .medium, design: .monospaced))
                .dashboardFieldChrome(compact: self.compact)
            }

            Toggle(isOn: self.$draft.enabled) {
                Text(self.model.text(.labelEnabled))
                    .font(.system(size: self.compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            .toggleStyle(.switch)

            FormFieldPanel(
                title: self.model.text(.labelAutomaticCooldown),
                footer: self.model.text(.helperAutomaticCooldownPolicy),
                compact: self.compact
            ) {
                Toggle(isOn: self.$draft.automaticCooldownDisabled) {
                    Text(self.model.text(.actionDisableAutomaticCooldown))
                        .font(.system(size: self.compact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                }
                .toggleStyle(.switch)
            }
        }
    }
}

private struct ManualAPIKeyUpstreamAdapterSegmentedControl: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    @Binding var selection: ManualAPIKeyUpstreamAdapter
    let compact: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: 2) {
            ForEach(ManualAPIKeyUpstreamAdapter.allCases, id: \.self) { adapter in
                let isSelected = adapter == self.selection
                Button {
                    self.selection = adapter
                } label: {
                    Text(self.model.manualAPIKeyUpstreamAdapterText(adapter))
                        .font(.system(size: self.compact ? 11 : 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(isSelected ? Color.white : palette.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: self.compact ? 24 : 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? palette.accent : Color.clear)
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}
#endif
