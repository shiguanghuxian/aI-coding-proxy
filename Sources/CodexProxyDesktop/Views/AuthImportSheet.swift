#if os(macOS)
import SwiftUI

struct AuthImportSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    let presentedDraft: DesktopAppModel.AuthImportDraft

    private var draftBinding: Binding<DesktopAppModel.AuthImportDraft> {
        Binding(
            get: { self.model.authImportDraft ?? self.presentedDraft },
            set: { newValue in
                self.model.authImportDraft = newValue
            }
        )
    }

    private var modeBinding: Binding<DesktopAppModel.AuthImportMode> {
        Binding(
            get: { self.draftBinding.wrappedValue.mode },
            set: { newValue in
                var draft = self.draftBinding.wrappedValue
                draft.mode = newValue
                self.draftBinding.wrappedValue = draft
            }
        )
    }

    private var pastedJSONBinding: Binding<String> {
        Binding(
            get: { self.draftBinding.wrappedValue.pastedJSON },
            set: { newValue in
                var draft = self.draftBinding.wrappedValue
                draft.pastedJSON = newValue
                self.draftBinding.wrappedValue = draft
            }
        )
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let draft = self.draftBinding.wrappedValue

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                self.header(palette: palette)
                self.modePicker
                self.modeContent(draft: draft, palette: palette)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            Divider()

            self.footer(draft: draft, palette: palette)
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 760, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panel)
        )
    }

    private func header(palette: AppearancePalette) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.model.text(.actionImportJSON))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Text(self.model.text(.helperQuickActionImportJSON))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            StatusPill(text: "JSON", tone: .accent)
        }
    }

    private var modePicker: some View {
        Picker("", selection: self.modeBinding) {
            Text(self.model.text(.actionPasteAuthJSON)).tag(DesktopAppModel.AuthImportMode.paste)
            Text(self.model.text(.actionChooseAuthJSONFiles)).tag(DesktopAppModel.AuthImportMode.file)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private func modeContent(
        draft: DesktopAppModel.AuthImportDraft,
        palette: AppearancePalette
    ) -> some View {
        switch draft.mode {
        case .paste:
            self.pastePane(draft: draft, palette: palette)
        case .file:
            self.filePane(palette: palette)
        }
    }

    private func pastePane(
        draft: DesktopAppModel.AuthImportDraft,
        palette: AppearancePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: self.pastedJSONBinding)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 260)

                if draft.pastedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(self.model.text(.placeholderAuthImportPaste))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.86 : 0.90))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )

            Text(self.model.text(.helperAuthImportPaste))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func filePane(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(self.model.text(.actionChooseAuthJSONFiles))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.model.text(.helperAuthImportFile))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.panelMuted.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
        }
    }

    private func footer(
        draft: DesktopAppModel.AuthImportDraft,
        palette: AppearancePalette
    ) -> some View {
        HStack(spacing: 10) {
            Button(self.model.text(.commonCancel)) {
                self.model.dismissAuthImportSheet()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            .disabled(self.model.authImportIsSubmitting)

            Spacer(minLength: 0)

            Button(draft.mode == .paste ? self.model.text(.actionImportJSON) : self.model.text(.actionChooseAuthJSONFiles)) {
                Task { await self.model.submitAuthImportDraft() }
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
            .disabled(self.model.authImportIsSubmitting)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 0.96))
    }
}
#endif
