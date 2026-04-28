#if os(macOS)
import SwiftUI

struct HelpView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    @State private var selectedTopicID: HelpTopicID? = .quickStart

    private var document: HelpDocument {
        self.model.helpDocument
    }

    private var selectedTopic: HelpDocument.Topic {
        let fallbackID = self.document.topics.first?.id ?? .quickStart
        return self.document.topic(for: self.selectedTopicID ?? fallbackID)
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        NavigationSplitView {
            List(selection: self.$selectedTopicID) {
                ForEach(self.document.topics) { topic in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topic.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(topic.eyebrow)
                                .font(.system(size: 10, weight: .bold))
                                .textCase(.uppercase)
                                .foregroundStyle(palette.textMuted)
                        }
                        .padding(.vertical, 4)
                    } icon: {
                        Image(systemName: topic.id.symbolName)
                            .foregroundStyle(palette.accent)
                    }
                    .tag(Optional(topic.id))
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(palette.panelMuted)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HelpHeroCard(
                        title: self.document.title,
                        subtitle: self.document.subtitle,
                        quickActions: self.document.quickActions,
                        model: self.model
                    )

                    HelpTopicCard(topic: self.selectedTopic, model: self.model)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.windowBottom.ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if self.selectedTopicID == nil {
                self.selectedTopicID = self.document.topics.first?.id
            }
        }
        .compactOverlayScrollbars()
    }
}

private struct HelpHeroCard: View {
    let title: String
    let subtitle: String
    let quickActions: [HelpDocument.Action]
    let model: DesktopAppModel

    var body: some View {
        SectionCard(title: self.title, subtitle: self.subtitle) {
            VStack(alignment: .leading, spacing: 14) {
                if self.quickActions.isEmpty == false {
                    Text(self.model.text(.sectionQuickActions))
                        .font(.system(size: 12, weight: .bold))
                    HelpActionRow(actions: self.quickActions, model: self.model)
                }
            }
        }
    }
}

private struct HelpTopicCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let topic: HelpDocument.Topic
    let model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        SectionCard(
            title: self.topic.title,
            subtitle: self.topic.subtitle,
            accessory: StatusPill(text: self.topic.eyebrow, tone: .accent)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text(self.topic.overview)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if self.topic.actions.isEmpty == false {
                    HelpActionRow(actions: self.topic.actions, model: self.model)
                }

                if self.topic.steps.isEmpty == false {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(self.topic.steps) { step in
                            HelpStepView(step: step, model: self.model)
                        }
                    }
                }

                ForEach(self.topic.sections) { section in
                    HelpSectionView(section: section, model: self.model)
                }
            }
        }
    }
}

private struct HelpActionRow: View {
    let actions: [HelpDocument.Action]
    let model: DesktopAppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(self.actions) { action in
                    self.button(for: action)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(self.actions) { action in
                    self.button(for: action)
                }
            }
        }
    }

    @ViewBuilder
    private func button(for action: HelpDocument.Action) -> some View {
        Button(action.title) {
            self.model.openHelpAction(action.target)
        }
        .buttonStyle(AppActionButtonStyle(kind: action.isPrimary ? .primary : .secondary))
    }
}

private struct HelpStepView: View {
    @Environment(\.colorScheme) private var colorScheme

    let step: HelpDocument.Step
    let model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(alignment: .top, spacing: 12) {
            Text("\(self.step.number)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.accent)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(self.step.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)

                Text(self.step.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = self.step.action {
                    HelpActionRow(actions: [action], model: self.model)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct HelpSectionView: View {
    @Environment(\.colorScheme) private var colorScheme

    let section: HelpDocument.Section
    let model: DesktopAppModel

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            Text(self.section.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text(self.section.summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(self.section.bullets.enumerated()), id: \.offset) { bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(palette.accent.opacity(0.9))
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)

                        Text(bullet.element)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let action = self.section.action {
                HelpActionRow(actions: [action], model: self.model)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}
#endif
