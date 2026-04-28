#if os(macOS)
import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        ZStack {
            ShellBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AboutHeroCard(model: self.model)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            AboutOverviewCard(model: self.model)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            AboutDeveloperCard(model: self.model)
                                .frame(width: 280, alignment: .top)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            AboutOverviewCard(model: self.model)
                            AboutDeveloperCard(model: self.model)
                        }
                    }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
            }
        }
        .compactOverlayScrollbars()
    }

}

private struct AboutHeroCard: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.accent, palette.accent.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)

                    Image(systemName: DesktopBrandIcon.systemName)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 92, height: 92)
                .shadow(
                    color: palette.accent.opacity(self.colorScheme == .dark ? 0.28 : 0.20),
                    radius: 16,
                    x: 0,
                    y: 10
                )

                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(self.model.text(.brandName))
                            .font(.system(size: 31, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        AboutVersionBadge(versionText: self.model.appVersionText)
                    }

                    Text(self.model.text(.brandSubtitle))
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Text(self.model.aboutWindowSubtitle)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                AboutFocusPill(
                    symbol: DesktopAppModel.Page.accounts.symbolName,
                    title: self.model.pageTitle(.accounts)
                )
                AboutFocusPill(
                    symbol: DesktopAppModel.Page.proxy.symbolName,
                    title: self.model.pageTitle(.proxy)
                )
                AboutFocusPill(
                    symbol: DesktopAppModel.Page.remote.symbolName,
                    title: self.model.pageTitle(.remote)
                )
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.95 : 0.985))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(palette.accentGlow.opacity(self.colorScheme == .dark ? 0.18 : 0.16))
                .frame(width: 220, height: 220)
                .blur(radius: 32)
                .offset(x: 36, y: -46)
                .allowsHitTesting(false)
        }
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? 0.18 : 0.08),
            radius: 16,
            x: 0,
            y: 8
        )
    }
}

private struct AboutOverviewCard: View {
    @ObservedObject var model: DesktopAppModel

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 12)]

    var body: some View {
        SectionCard(title: self.model.text(.aboutOverviewTitle), compact: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text(self.model.text(.aboutOverviewBody))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(self.palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                LazyVGrid(columns: self.columns, spacing: 12) {
                    AboutFeatureCard(
                        icon: DesktopAppModel.Page.accounts.symbolName,
                        title: self.model.pageTitle(.accounts),
                        detail: self.model.text(.aboutCapabilityAccounts),
                        tint: self.palette.accent,
                        tintBackground: self.palette.accentSoft
                    )

                    AboutFeatureCard(
                        icon: DesktopAppModel.Page.proxy.symbolName,
                        title: self.model.pageTitle(.proxy),
                        detail: self.model.text(.aboutCapabilityAccess),
                        tint: self.palette.info,
                        tintBackground: self.palette.infoSoft
                    )

                    AboutFeatureCard(
                        icon: DesktopAppModel.Page.remote.symbolName,
                        title: self.model.pageTitle(.remote),
                        detail: self.model.text(.aboutCapabilityRemote),
                        tint: self.palette.success,
                        tintBackground: self.palette.successSoft
                    )
                }
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var palette: AppearancePalette {
        AppearanceStore.palette(for: self.colorScheme)
    }
}

private struct AboutDeveloperCard: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var body: some View {
        SectionCard(
            title: self.model.text(.aboutDeveloperTitle),
            subtitle: self.model.text(.aboutDeveloperBody),
            compact: false
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(self.palette.accentSoft)

                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(self.palette.accent)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("zuoxiupeng")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(self.palette.textPrimary)

                        Text(self.model.text(.brandName))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(self.palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                AboutContactField(
                    label: self.model.text(.labelEmail),
                    value: self.model.aboutDeveloperEmail,
                    copyTitle: self.model.text(.commonCopy)
                )

                AboutDeveloperNote(text: self.model.text(.brandSubtitle))
            }
        }
    }

    private var palette: AppearancePalette {
        AppearanceStore.palette(for: self.colorScheme)
    }
}

private struct AboutVersionBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let versionText: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Text("v\(self.versionText)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(palette.accentSoft))
            .overlay {
                Capsule()
                    .stroke(palette.accent.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct AboutFocusPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let symbol: String
    let title: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: 7) {
            Image(systemName: self.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)

            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.94 : 1.0)))
        .overlay {
            Capsule()
                .stroke(palette.border.opacity(0.9), lineWidth: 1)
        }
    }
}

private struct AboutFeatureCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let tintBackground: Color

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(self.tintBackground)

                Image(systemName: self.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(self.tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 6) {
                Text(self.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                Text(self.detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.92 : 1.0))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border.opacity(0.92), lineWidth: 1)
        }
    }
}

private struct AboutContactField: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    let copyTitle: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            Text(self.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(palette.textMuted)

            HStack(spacing: 10) {
                Text(self.value)
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 0)

                AboutCopyButton(value: self.value, title: self.copyTitle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.92 : 1.0))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border.opacity(0.92), lineWidth: 1)
        }
    }
}

private struct AboutCopyButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: String
    let title: String

    @State private var didCopy = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Button {
            NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.setString(self.value, forType: .string)
            self.didCopy = true

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                self.didCopy = false
            }
        } label: {
            Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(self.didCopy ? palette.success : palette.textSecondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.84 : 0.96))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
        .help(self.title)
        .interactiveCursor()
    }
}

private struct AboutDeveloperNote: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.top, 1)

            Text(self.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panelMuted.opacity(self.colorScheme == .dark ? 0.88 : 0.95))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border.opacity(0.82), lineWidth: 1)
        }
    }
}
#endif
