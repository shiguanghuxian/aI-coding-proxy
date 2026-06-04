#if os(macOS)
import AppKit
import CodexProxyCore
import SwiftUI

private struct InteractiveCursorModifier: ViewModifier {
    let isEnabled: Bool
    var cursor: NSCursor = .pointingHand

    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                self.updateCursor(hovering: hovering)
            }
            .onChange(of: self.isEnabled) { _, isEnabled in
                if !isEnabled {
                    self.popCursorIfNeeded()
                }
            }
            .onDisappear {
                self.popCursorIfNeeded()
            }
    }

    private func updateCursor(hovering: Bool) {
        guard self.isEnabled else {
            self.popCursorIfNeeded()
            return
        }

        if hovering {
            guard !self.isCursorPushed else { return }
            self.cursor.push()
            self.isCursorPushed = true
        } else {
            self.popCursorIfNeeded()
        }
    }

    private func popCursorIfNeeded() {
        guard self.isCursorPushed else { return }
        NSCursor.pop()
        self.isCursorPushed = false
    }
}

extension View {
    func interactiveCursor(isEnabled: Bool = true, cursor: NSCursor = .pointingHand) -> some View {
        self.modifier(InteractiveCursorModifier(isEnabled: isEnabled, cursor: cursor))
    }

    func compactOverlayScrollbars() -> some View {
        self.modifier(CompactOverlayScrollbarsModifier())
    }
}

@MainActor
enum CompactOverlayScrollbarStyleController {
    static func apply(around probeView: NSView) {
        let rootView = self.rootView(around: probeView)
        for scrollView in self.scrollViews(in: rootView) {
            self.apply(to: scrollView)
        }
    }

    static func scrollViews(in rootView: NSView) -> [NSScrollView] {
        var scrollViews: [NSScrollView] = []
        var visited = Set<ObjectIdentifier>()

        func collect(from view: NSView) {
            let objectID = ObjectIdentifier(view)
            guard visited.insert(objectID).inserted else { return }

            if let scrollView = view as? NSScrollView {
                scrollViews.append(scrollView)
            }

            view.subviews.forEach(collect)
        }

        collect(from: rootView)
        return scrollViews
    }

    private static func rootView(around probeView: NSView) -> NSView {
        if let contentView = probeView.window?.contentView {
            return contentView
        }

        var currentView = probeView
        while let superview = currentView.superview {
            currentView = superview
        }
        return currentView
    }

    private static func apply(to scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if scrollView.autohidesScrollers == false {
            scrollView.autohidesScrollers = true
        }

        self.apply(to: scrollView.verticalScroller)
        self.apply(to: scrollView.horizontalScroller)
    }

    private static func apply(to scroller: NSScroller?) {
        guard let scroller else { return }

        if scroller.scrollerStyle != .overlay {
            scroller.scrollerStyle = .overlay
        }
        if scroller.controlSize != .small {
            scroller.controlSize = .small
        }
    }
}

private struct CompactOverlayScrollbarsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(CompactOverlayScrollbarsProbe())
    }
}

private struct CompactOverlayScrollbarsProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> CompactOverlayScrollbarsProbeView {
        let view = CompactOverlayScrollbarsProbeView()
        view.refreshHandler = CompactOverlayScrollbarStyleController.apply(around:)
        view.refreshAndSchedule()
        return view
    }

    func updateNSView(_ nsView: CompactOverlayScrollbarsProbeView, context: Context) {
        nsView.refreshHandler = CompactOverlayScrollbarStyleController.apply(around:)
        nsView.refreshAndSchedule()
    }
}

@MainActor
private final class CompactOverlayScrollbarsProbeView: NSView {
    var refreshHandler: ((NSView) -> Void)?
    private var isRefreshScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.refreshAndSchedule()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.refreshAndSchedule()
    }

    override func layout() {
        super.layout()
        self.refreshAndSchedule()
    }

    func refreshAndSchedule() {
        self.refreshHandler?(self)
        self.scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard self.isRefreshScheduled == false else { return }
        self.isRefreshScheduled = true
        self.perform(#selector(self.runScheduledRefresh), with: nil, afterDelay: 0)
    }

    @objc private func runScheduledRefresh() {
        self.isRefreshScheduled = false
        self.refreshHandler?(self)
    }
}

struct SectionCard<Content: View, Accessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String?
    let accessory: Accessory
    let compact: Bool
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        accessory: Accessory,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 12 : 16) {
            HStack(alignment: .top, spacing: self.compact ? 10 : 12) {
                VStack(alignment: .leading, spacing: self.compact ? 4 : 6) {
                    Text(self.title)
                        .font(.system(size: self.compact ? 15 : 17, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(self.compact ? 2 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
                self.accessory
            }

            self.content
        }
        .padding(self.compact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 18 : 22, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 0.985))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 18 : 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? (self.compact ? 0.14 : 0.18) : (self.compact ? 0.05 : 0.08)),
            radius: self.compact ? 8 : 12,
            x: 0,
            y: self.compact ? 3 : 6
        )
    }
}

extension SectionCard where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, accessory: EmptyView(), compact: compact, content: content)
    }
}

struct DashboardTabStrip<Item: Identifiable & Hashable, TrailingContent: View>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    let symbol: (Item) -> String
    let showsTrailingContent: Bool
    @ViewBuilder var trailingContent: TrailingContent

    init(
        items: [Item],
        selection: Binding<Item>,
        title: @escaping (Item) -> String,
        symbol: @escaping (Item) -> String,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        self.items = items
        self._selection = selection
        self.title = title
        self.symbol = symbol
        self.showsTrailingContent = true
        self.trailingContent = trailingContent()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            self.tabTrack

            if self.showsTrailingContent {
                self.trailingContent
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabTrack: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            self.tabButtons
                .padding(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardTabTrackChrome()
    }

    private var tabButtons: some View {
        HStack(spacing: 6) {
            ForEach(self.items) { item in
                DashboardTabStripButton(
                    title: self.title(item),
                    symbol: self.symbol(item),
                    isSelected: self.selection == item
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.selection = item
                    }
                }
            }
        }
    }
}

extension DashboardTabStrip where TrailingContent == EmptyView {
    init(
        items: [Item],
        selection: Binding<Item>,
        title: @escaping (Item) -> String,
        symbol: @escaping (Item) -> String
    ) {
        self.items = items
        self._selection = selection
        self.title = title
        self.symbol = symbol
        self.showsTrailingContent = false
        self.trailingContent = EmptyView()
    }
}

private struct DashboardTabStripButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                DashboardTabStripIconChip(
                    symbol: self.symbol,
                    isSelected: self.isSelected,
                    isHovered: self.isHovered
                )

                Text(self.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(
            DashboardTabStripButtonStyle(
                isSelected: self.isSelected,
                isHovered: self.isHovered
            )
        )
        .interactiveCursor(isEnabled: self.isEnabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                self.isHovered = hovering
            }
        }
    }
}

private struct DashboardTabStripIconChip: View {
    @Environment(\.colorScheme) private var colorScheme

    let symbol: String
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.background)

            Image(systemName: self.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colors.foreground)
        }
        .frame(width: 24, height: 24)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: self.isSelected)
        .animation(.easeOut(duration: 0.18), value: self.isHovered)
    }

    private func colors(palette: AppearancePalette) -> (
        foreground: Color,
        background: Color,
        border: Color
    ) {
        if self.isSelected {
            return (
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
                palette.accent.opacity(self.colorScheme == .dark ? 0.28 : 0.16)
            )
        }

        if self.isHovered {
            return (
                palette.textPrimary,
                palette.panelRaised.opacity(self.colorScheme == .dark ? 0.96 : 0.96),
                palette.border.opacity(self.colorScheme == .dark ? 0.92 : 0.82)
            )
        }

        return (
            palette.textSecondary,
            Color.clear,
            Color.clear
        )
    }
}

private struct DashboardTabTrackChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.94 : 0.985))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
            .shadow(color: palette.shadow.opacity(self.colorScheme == .dark ? 0.16 : 0.05), radius: 7, x: 0, y: 4)
    }
}

private extension View {
    func dashboardTabTrackChrome() -> some View {
        self.modifier(DashboardTabTrackChrome())
    }
}

private struct DashboardTabStripButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let isSelected: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)
        let isPressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .foregroundStyle(colors.foreground)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colors.fill.opacity(isPressed ? 0.92 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(colors.border, lineWidth: self.isSelected || self.isHovered ? 1 : 0.75)
            )
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(self.isSelected ? palette.accent : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 3)
            }
            .shadow(
                color: colors.shadow.opacity(isPressed ? 0.08 : 1.0),
                radius: self.isSelected ? 6 : (self.isHovered ? 4 : 0),
                x: 0,
                y: self.isSelected ? 3 : (self.isHovered ? 1.5 : 0)
            )
            .scaleEffect(isPressed ? 0.992 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.78)
            .animation(.easeOut(duration: 0.14), value: isPressed)
            .animation(.easeOut(duration: 0.18), value: self.isHovered)
            .animation(.easeOut(duration: 0.18), value: self.isSelected)
    }

    private func colors(palette: AppearancePalette) -> (
        foreground: Color,
        fill: Color,
        border: Color,
        shadow: Color
    ) {
        if self.isSelected {
            return (
                palette.textPrimary,
                palette.panel.opacity(self.colorScheme == .dark ? 0.96 : 1.0),
                palette.accent.opacity(self.colorScheme == .dark ? 0.30 : 0.14),
                palette.accentGlow.opacity(self.colorScheme == .dark ? 0.18 : 0.10)
            )
        }

        if self.isHovered {
            return (
                palette.textPrimary,
                palette.panelRaised.opacity(self.colorScheme == .dark ? 0.60 : 0.65),
                palette.border.opacity(self.colorScheme == .dark ? 0.86 : 0.82),
                palette.shadow.opacity(self.colorScheme == .dark ? 0.16 : 0.08)
            )
        }

        return (
            palette.textSecondary,
            Color.clear,
            Color.clear,
            Color.clear
        )
    }
}

struct MetricTile: View {
    enum Tone {
        case accent
        case success
        case warning
        case danger
        case neutral
    }

    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    var footnote: String?
    var tone: Tone = .neutral
    var symbol: String? = nil
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let tone = self.toneColors(palette: palette)

        VStack(alignment: .leading, spacing: self.compact ? 8 : 10) {
            HStack(alignment: .center, spacing: self.compact ? 7 : 8) {
                if let symbol, !symbol.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: self.compact ? 9 : 10, style: .continuous)
                            .fill(tone.iconBackground)
                        Image(systemName: symbol)
                            .font(.system(size: self.compact ? 11 : 12, weight: .semibold))
                            .foregroundStyle(tone.iconForeground)
                    }
                    .frame(width: self.compact ? 24 : 28, height: self.compact ? 24 : 28)
                }

                Text(self.label)
                    .font(.system(size: self.compact ? 10 : 11, weight: .semibold, design: .default))
                    .foregroundStyle(palette.textMuted)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: self.compact ? 2 : 3) {
                Text(self.value)
                    .font(.system(size: self.compact ? 22 : 26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                if let footnote, !footnote.isEmpty {
                    Text(footnote)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                }
            }

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tone.line, tone.line.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2.5)
        }
        .padding(.horizontal, self.compact ? 10 : 12)
        .padding(.vertical, self.compact ? 9 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.compact ? 14 : 16, style: .continuous)
                .fill(tone.background.opacity(self.colorScheme == .dark ? 0.94 : 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.compact ? 14 : 16, style: .continuous)
                .stroke(tone.border, lineWidth: 1)
        )
    }

    private func toneColors(palette: AppearancePalette) -> (
        background: Color,
        border: Color,
        line: Color,
        iconForeground: Color,
        iconBackground: Color
    ) {
        switch self.tone {
        case .accent:
            return (
                palette.panel,
                palette.accent.opacity(0.16),
                palette.accent,
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.90 : 1.0)
            )
        case .success:
            return (
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.58 : 1.0),
                palette.success.opacity(0.18),
                palette.success,
                palette.success,
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.90 : 1.0)
            )
        case .warning:
            return (
                palette.panel,
                palette.warning.opacity(0.18),
                palette.warning,
                palette.warning,
                palette.warningSoft.opacity(self.colorScheme == .dark ? 0.90 : 1.0)
            )
        case .danger:
            return (
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.50 : 1.0),
                palette.danger.opacity(0.18),
                palette.danger,
                palette.danger,
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.90 : 1.0)
            )
        case .neutral:
            return (
                palette.panel,
                palette.border.opacity(0.95),
                palette.textMuted.opacity(0.46),
                palette.textSecondary,
                palette.panelMuted.opacity(self.colorScheme == .dark ? 0.96 : 1.0)
            )
        }
    }
}

struct SettingsOptionCardSelector<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let symbol: String
        let title: String
        let subtitle: String
        let preview: AnyView

        var id: Value { self.value }

        init<Preview: View>(
            value: Value,
            symbol: String,
            title: String,
            subtitle: String,
            @ViewBuilder preview: () -> Preview
        ) {
            self.value = value
            self.symbol = symbol
            self.title = title
            self.subtitle = subtitle
            self.preview = AnyView(preview())
        }
    }

    @Binding var selection: Value
    let items: [Item]
    let currentTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(self.items) { item in
                SettingsOptionCard(
                    item: item,
                    isSelected: self.selection == item.value,
                    currentTitle: self.currentTitle
                ) {
                    guard self.selection != item.value else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.selection = item.value
                    }
                }
            }
        }
    }
}

private struct SettingsOptionCard<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: SettingsOptionCardSelector<Value>.Item
    let isSelected: Bool
    let currentTitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let iconColors = self.iconColors(palette: palette)

        Button(action: self.action) {
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(iconColors.background)

                        Image(systemName: self.item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(iconColors.foreground)
                    }
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(iconColors.border, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(self.item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)

                        Text(self.item.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 10) {
                    ZStack(alignment: .trailing) {
                        if self.isSelected {
                            StatusPill(text: self.currentTitle, tone: .accent, compact: true)
                        }
                    }
                    .frame(height: 20, alignment: .trailing)

                    self.item.preview
                        .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(
            SettingsOptionCardButtonStyle(
                isSelected: self.isSelected,
                isHovered: self.isHovered
            )
        )
        .interactiveCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                self.isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }

    private func iconColors(palette: AppearancePalette) -> (
        foreground: Color,
        background: Color,
        border: Color
    ) {
        if self.isSelected {
            return (
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
                palette.accent.opacity(self.colorScheme == .dark ? 0.28 : 0.18)
            )
        }

        if self.isHovered {
            return (
                palette.textPrimary,
                palette.panelRaised.opacity(self.colorScheme == .dark ? 0.96 : 1.0),
                palette.border.opacity(self.colorScheme == .dark ? 0.92 : 0.84)
            )
        }

        return (
            palette.textSecondary,
            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
            palette.border.opacity(0.7)
        )
    }
}

private struct SettingsOptionCardButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let isSelected: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)
        let isPressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [colors.top, colors.bottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors.border, lineWidth: self.isSelected ? 1.15 : 1)
            )
            .shadow(
                color: colors.shadow.opacity(isPressed ? 0.68 : 1.0),
                radius: self.isSelected ? 8 : (self.isHovered ? 5 : 0),
                x: 0,
                y: self.isSelected ? 4 : (self.isHovered ? 2 : 0)
            )
            .scaleEffect(isPressed ? 0.986 : 1.0)
            .opacity(self.isEnabled ? (isPressed ? 0.97 : 1.0) : 0.78)
            .animation(.easeOut(duration: 0.14), value: isPressed)
            .animation(.easeOut(duration: 0.18), value: self.isHovered)
            .animation(.easeOut(duration: 0.18), value: self.isSelected)
    }

    private func colors(palette: AppearancePalette) -> (
        top: Color,
        bottom: Color,
        border: Color,
        shadow: Color
    ) {
        if self.isSelected {
            return (
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.52 : 0.92),
                palette.panel.opacity(self.colorScheme == .dark ? 0.98 : 1.0),
                palette.accent.opacity(self.colorScheme == .dark ? 0.34 : 0.24),
                palette.accentGlow.opacity(self.colorScheme == .dark ? 0.24 : 0.16)
            )
        }

        if self.isHovered {
            return (
                palette.panelRaised.opacity(self.colorScheme == .dark ? 0.98 : 1.0),
                palette.panel.opacity(self.colorScheme == .dark ? 0.94 : 0.985),
                palette.border.opacity(self.colorScheme == .dark ? 0.96 : 0.86),
                palette.shadow.opacity(self.colorScheme == .dark ? 0.18 : 0.09)
            )
        }

        return (
            palette.panelMuted.opacity(self.colorScheme == .dark ? 0.90 : 0.94),
            palette.panel.opacity(self.colorScheme == .dark ? 0.88 : 0.96),
            palette.border.opacity(0.92),
            Color.clear
        )
    }
}

struct StatusPill: View {
    enum Tone: Equatable {
        case accent
        case success
        case warning
        case danger
        case neutral
    }

    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let tone: Tone
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette)

        HStack(spacing: self.compact ? 5 : 7) {
            Circle()
                .fill(colors.foreground)
                .frame(width: self.compact ? 5 : 6, height: self.compact ? 5 : 6)
            Text(self.text)
                .font(.system(size: self.compact ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(colors.foreground)
                .lineLimit(1)
        }
        .padding(.horizontal, self.compact ? 9 : 10)
        .padding(.vertical, self.compact ? 4.5 : 5.5)
        .background(Capsule().fill(colors.background.opacity(self.colorScheme == .dark ? 0.96 : 1.0)))
        .overlay(Capsule().stroke(colors.border, lineWidth: 1))
    }

    private func colors(_ palette: AppearancePalette) -> (foreground: Color, background: Color, border: Color) {
        switch self.tone {
        case .accent:
            return (palette.accent, palette.accentSoft, palette.accent.opacity(0.22))
        case .success:
            return (palette.success, palette.successSoft, palette.success.opacity(0.22))
        case .warning:
            return (palette.warning, palette.warningSoft, palette.warning.opacity(0.22))
        case .danger:
            return (palette.danger, palette.dangerSoft, palette.danger.opacity(0.22))
        case .neutral:
            return (palette.textSecondary, palette.panelRaised, palette.border)
        }
    }
}

struct ToastView: View {
    @Environment(\.colorScheme) private var colorScheme

    let banner: DesktopAppModel.BannerState
    let dismissTitle: String
    let onDismiss: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(colors.iconBackground)
                    Image(systemName: colors.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.iconForeground)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(self.banner.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = self.banner.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 0)

                Button(action: self.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(colors.iconForeground)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(colors.iconBackground)
                        )
                }
                .buttonStyle(.plain)
                .interactiveCursor()
                .help(self.dismissTitle)
            }

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [colors.iconForeground.opacity(0.92), colors.iconForeground.opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [colors.backgroundTop, colors.backgroundBottom],
                        startPoint: .topLeading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
        .shadow(color: palette.shadow.opacity(self.colorScheme == .dark ? 0.34 : 0.16), radius: 20, x: 0, y: 10)
    }

    private func colors(_ palette: AppearancePalette) -> (
        backgroundTop: Color,
        backgroundBottom: Color,
        border: Color,
        icon: String,
        iconForeground: Color,
        iconBackground: Color
    ) {
        switch self.banner.tone {
        case .success:
            return (
                palette.successSoft.opacity(0.95),
                palette.panel.opacity(0.95),
                palette.success.opacity(0.18),
                "checkmark.circle.fill",
                palette.success,
                palette.success.opacity(self.colorScheme == .dark ? 0.18 : 0.12)
            )
        case .info:
            return (
                palette.accentSoft.opacity(0.95),
                palette.panel.opacity(0.95),
                palette.accent.opacity(0.18),
                "sparkles",
                palette.accent,
                palette.accent.opacity(self.colorScheme == .dark ? 0.18 : 0.12)
            )
        case .warning:
            return (
                palette.warningSoft.opacity(0.95),
                palette.panel.opacity(0.95),
                palette.warning.opacity(0.18),
                "exclamationmark.triangle.fill",
                palette.warning,
                palette.warning.opacity(self.colorScheme == .dark ? 0.18 : 0.12)
            )
        case .error:
            return (
                palette.dangerSoft.opacity(0.95),
                palette.panel.opacity(0.95),
                palette.danger.opacity(0.18),
                "xmark.octagon.fill",
                palette.danger,
                palette.danger.opacity(self.colorScheme == .dark ? 0.18 : 0.12)
            )
        }
    }
}

struct ToastStackView: View {
    let banners: [DesktopAppModel.BannerState]
    let dismissTitle: String
    var topPadding: CGFloat = 18
    var trailingPadding: CGFloat = 22
    let onDismiss: (DesktopAppModel.BannerState.ID) -> Void

    var body: some View {
        if self.banners.isEmpty == false {
            VStack(alignment: .trailing, spacing: 12) {
                ForEach(self.banners) { banner in
                    ToastView(
                        banner: banner,
                        dismissTitle: self.dismissTitle
                    ) {
                        self.onDismiss(banner.id)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: 44, y: 0).combined(with: .opacity),
                            removal: .offset(x: 18, y: -8).combined(with: .opacity)
                        )
                    )
                }
            }
            .padding(.top, self.topPadding)
            .padding(.trailing, self.trailingPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

struct DashboardHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let statusText: String
    let statusTone: StatusPill.Tone
    let isBusy: Bool
    let trailingTitle: String?
    let onTrailing: (() -> Void)?
    let helpTitle: String?
    let onHelp: (() -> Void)?
    let reloadTitle: String
    let onReload: () -> Void
    let showsControls: Bool
    let compact: Bool

    init(
        title: String,
        subtitle: String,
        statusText: String,
        statusTone: StatusPill.Tone,
        isBusy: Bool,
        trailingTitle: String? = nil,
        onTrailing: (() -> Void)? = nil,
        helpTitle: String? = nil,
        onHelp: (() -> Void)? = nil,
        showsControls: Bool = true,
        compact: Bool = false,
        reloadTitle: String,
        onReload: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.statusTone = statusTone
        self.isBusy = isBusy
        self.trailingTitle = trailingTitle
        self.onTrailing = onTrailing
        self.helpTitle = helpTitle
        self.onHelp = onHelp
        self.showsControls = showsControls
        self.compact = compact
        self.reloadTitle = reloadTitle
        self.onReload = onReload
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 10 : 14) {
            if self.showsControls {
                HStack(alignment: .top, spacing: self.compact ? 12 : 18) {
                    self.headerCopy(palette: palette)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(0)

                    self.headerActions(palette: palette)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            } else {
                self.headerCopy(palette: palette)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(width: self.compact ? 88 : 104, height: 3)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, self.compact ? 0 : 2)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headerCopy(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: self.compact ? 4 : 6) {
            Text(self.title)
                .font(.system(size: self.compact ? 26 : 32, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(self.subtitle)
                .font(.system(size: self.compact ? 10 : 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func headerActions(palette: AppearancePalette) -> some View {
        HStack(spacing: self.compact ? 6 : 8) {
            self.statusCluster(palette: palette)
            self.utilityButtons(palette: palette)
            self.trailingButton(palette: palette)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func statusCluster(palette: AppearancePalette) -> some View {
        StatusPill(text: self.statusText, tone: self.statusTone, compact: self.compact)

        if self.isBusy {
            ProgressView()
                .controlSize(.small)
                .tint(palette.accent)
                .padding(.horizontal, self.compact ? 8 : 10)
                .padding(.vertical, self.compact ? 5 : 6)
                .background(Capsule().fill(palette.panelMuted.opacity(0.95)))
                .overlay(Capsule().stroke(palette.border, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func utilityButtons(palette: AppearancePalette) -> some View {
        if let helpTitle, let onHelp {
            Button(helpTitle, action: onHelp)
                .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, symbol: "questionmark.circle", compact: self.compact))
        }

        Button(self.reloadTitle, action: self.onReload)
            .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, symbol: "arrow.clockwise", compact: self.compact))
    }

    @ViewBuilder
    private func trailingButton(palette: AppearancePalette) -> some View {
        if let trailingTitle, let onTrailing {
            Button(trailingTitle, action: onTrailing)
                .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, compact: self.compact))
        }
    }
}

private enum TitlebarControlMetrics {
    static let groupSpacing: CGFloat = 7
    static let controlHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 11
    static let containerCornerRadius: CGFloat = 15
    static let containerHorizontalPadding: CGFloat = 6
    static let containerVerticalPadding: CGFloat = 4
    static let labelFontSize: CGFloat = 11
    static let iconSize: CGFloat = 11
    static let statusDotSize: CGFloat = 7
    static let labelSpacing: CGFloat = 5
    static let horizontalPadding: CGFloat = 10
    static let pillHorizontalPadding: CGFloat = 12
}

struct MainWindowTitlebarControls: View {
    @Environment(\.colorScheme) private var colorScheme

    let statusText: String
    let statusTone: StatusPill.Tone
    let isBusy: Bool
    let helpTitle: String
    let onHelp: () -> Void
    let reloadTitle: String
    let onReload: () -> Void
    let requestLogsTitle: String
    var requestLogsHelpText: String?
    let onRequestLogs: () -> Void
    var assistantTitle: String? = nil
    var assistantHelpText: String? = nil
    var onAssistant: (() -> Void)? = nil
    var assistantAccessibilityID: String = "titlebar-assistant-button"
    let keepAwakeTitle: String
    let keepAwakeSymbol: String
    let keepAwakeHelpText: String
    let onKeepAwake: () -> Void
    let modeEntryTitle: String
    let modeEntrySymbol: String
    let modeEntryHelpText: String
    let onModeEntry: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(spacing: TitlebarControlMetrics.groupSpacing) {
            TitlebarStatusPill(text: self.statusText, tone: self.statusTone)
                .fixedSize(horizontal: true, vertical: false)

            if self.isBusy {
                TitlebarBusyChip()
                    .fixedSize(horizontal: true, vertical: false)
            }

            TitlebarActionButton(
                title: self.helpTitle,
                symbol: "questionmark.circle",
                accessibilityID: "titlebar-help-button",
                action: self.onHelp
            )

            TitlebarActionButton(
                title: self.reloadTitle,
                symbol: "arrow.clockwise",
                accessibilityID: "titlebar-refresh-button",
                action: self.onReload
            )

            TitlebarActionButton(
                title: self.requestLogsTitle,
                symbol: "list.bullet.rectangle",
                accessibilityID: "titlebar-request-logs-button",
                helpText: self.requestLogsHelpText,
                action: self.onRequestLogs
            )

            if let assistantTitle, let onAssistant {
                TitlebarActionButton(
                    title: assistantTitle,
                    symbol: "sparkles",
                    accessibilityID: assistantAccessibilityID,
                    helpText: assistantHelpText,
                    action: onAssistant
                )
            }

            TitlebarActionButton(
                title: self.keepAwakeTitle,
                symbol: self.keepAwakeSymbol,
                accessibilityID: "titlebar-keep-awake-button",
                helpText: self.keepAwakeHelpText,
                action: self.onKeepAwake
            )

            TitlebarModeEntryButton(
                title: self.modeEntryTitle,
                symbol: self.modeEntrySymbol,
                helpText: self.modeEntryHelpText,
                action: self.onModeEntry
            )
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, TitlebarControlMetrics.containerHorizontalPadding)
        .padding(.vertical, TitlebarControlMetrics.containerVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: TitlebarControlMetrics.containerCornerRadius, style: .continuous)
                .fill(self.containerBackground(palette: palette))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TitlebarControlMetrics.containerCornerRadius, style: .continuous)
                .stroke(palette.border.opacity(self.colorScheme == .dark ? 0.96 : 0.86), lineWidth: 1)
        )
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? 0.10 : 0.04),
            radius: 6,
            x: 0,
            y: 2
        )
        .accessibilityIdentifier("main-window-titlebar-controls")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func containerBackground(palette: AppearancePalette) -> Color {
        palette.panelRaised.opacity(self.colorScheme == .dark ? 0.64 : 0.88)
    }
}

private struct TitlebarStatusPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let tone: StatusPill.Tone

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)

        HStack(spacing: 5) {
            Circle()
                .fill(colors.foreground)
                .frame(width: TitlebarControlMetrics.statusDotSize, height: TitlebarControlMetrics.statusDotSize)
                .shadow(color: colors.foreground.opacity(0.28), radius: 2, x: 0, y: 0)
            Text(self.text)
                .font(.system(size: TitlebarControlMetrics.labelFontSize, weight: .semibold))
                .foregroundStyle(colors.foreground)
                .lineLimit(1)
        }
        .padding(.horizontal, TitlebarControlMetrics.pillHorizontalPadding)
        .frame(height: TitlebarControlMetrics.controlHeight)
        .background(
            Capsule(style: .continuous)
                .fill(colors.background)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(colors.border, lineWidth: 1)
        )
    }

    private func colors(palette: AppearancePalette) -> (foreground: Color, background: Color, border: Color) {
        switch self.tone {
        case .success:
            return (
                palette.success,
                palette.successSoft.opacity(self.colorScheme == .dark ? 0.72 : 1.0),
                palette.success.opacity(self.colorScheme == .dark ? 0.40 : 0.26)
            )
        case .accent:
            return (
                palette.accent,
                palette.accentSoft.opacity(self.colorScheme == .dark ? 0.72 : 1.0),
                palette.accent.opacity(self.colorScheme == .dark ? 0.40 : 0.26)
            )
        case .warning:
            return (
                palette.warning,
                palette.warningSoft.opacity(self.colorScheme == .dark ? 0.70 : 0.96),
                palette.warning.opacity(self.colorScheme == .dark ? 0.42 : 0.28)
            )
        case .danger:
            return (
                palette.danger,
                palette.dangerSoft.opacity(self.colorScheme == .dark ? 0.70 : 0.96),
                palette.danger.opacity(self.colorScheme == .dark ? 0.42 : 0.28)
            )
        case .neutral:
            return (
                palette.textSecondary,
                palette.panelEmphasis.opacity(self.colorScheme == .dark ? 0.62 : 0.86),
                palette.border.opacity(self.colorScheme == .dark ? 0.98 : 0.9)
            )
        }
    }
}

private struct TitlebarBusyChip: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ProgressView()
            .controlSize(.small)
            .tint(palette.accent)
            .padding(.horizontal, 8)
            .frame(height: TitlebarControlMetrics.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: TitlebarControlMetrics.cornerRadius, style: .continuous)
                    .fill(palette.panelEmphasis.opacity(self.colorScheme == .dark ? 0.64 : 0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TitlebarControlMetrics.cornerRadius, style: .continuous)
                    .stroke(palette.border.opacity(self.colorScheme == .dark ? 0.96 : 0.86), lineWidth: 1)
            )
    }
}

private struct TitlebarActionButton: View {
    @State private var isHovered = false

    let title: String
    let symbol: String
    let accessibilityID: String
    var helpText: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: TitlebarControlMetrics.labelSpacing) {
                Image(systemName: self.symbol)
                    .font(.system(size: TitlebarControlMetrics.iconSize, weight: .semibold))
                Text(self.title)
                    .lineLimit(1)
            }
            .padding(.horizontal, TitlebarControlMetrics.horizontalPadding)
            .frame(height: TitlebarControlMetrics.controlHeight)
        }
        .buttonStyle(TitlebarActionButtonStyle(isHovered: self.isHovered))
        .help(self.helpText ?? self.title)
        .accessibilityIdentifier(self.accessibilityID)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering in
            self.isHovered = hovering
        }
    }
}

private struct TitlebarActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let pressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .font(.system(size: TitlebarControlMetrics.labelFontSize, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: TitlebarControlMetrics.cornerRadius, style: .continuous)
                    .fill(self.backgroundFill(palette: palette, pressed: pressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TitlebarControlMetrics.cornerRadius, style: .continuous)
                    .stroke(palette.border.opacity(self.colorScheme == .dark ? 0.98 : 0.9), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.99 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.72)
            .interactiveCursor(isEnabled: self.isEnabled)
    }

    private func backgroundFill(palette: AppearancePalette, pressed: Bool) -> Color {
        if pressed {
            return palette.panelEmphasis.opacity(self.colorScheme == .dark ? 0.78 : 1.0)
        }
        if self.isHovered {
            return palette.panelEmphasis.opacity(self.colorScheme == .dark ? 0.66 : 0.96)
        }
        return palette.panel.opacity(self.colorScheme == .dark ? 0.50 : 0.72)
    }
}

private struct TitlebarModeEntryButton: View {
    @State private var isHovered = false

    let title: String
    let symbol: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: TitlebarControlMetrics.labelSpacing) {
                Image(systemName: self.symbol)
                    .font(.system(size: TitlebarControlMetrics.iconSize, weight: .semibold))
                Text(self.title)
                    .lineLimit(1)
            }
            .padding(.horizontal, TitlebarControlMetrics.horizontalPadding)
            .frame(height: TitlebarControlMetrics.controlHeight)
        }
        .buttonStyle(TitlebarModeEntryButtonStyle(isHovered: self.isHovered))
        .help(self.helpText)
        .accessibilityIdentifier("titlebar-interface-mode-button")
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering in
            self.isHovered = hovering
        }
    }
}

private struct TitlebarModeEntryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let pressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .font(.system(size: TitlebarControlMetrics.labelFontSize, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(Color.white)
            .background(
                RoundedRectangle(cornerRadius: TitlebarControlMetrics.cornerRadius, style: .continuous)
                    .fill(self.backgroundFill(palette: palette, pressed: pressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TitlebarControlMetrics.cornerRadius, style: .continuous)
                    .stroke(palette.accent.opacity(self.colorScheme == .dark ? 0.26 : 0.16), lineWidth: 1)
            )
            .shadow(color: palette.accent.opacity(self.colorScheme == .dark ? 0.26 : 0.18), radius: 5, x: 0, y: 2)
            .scaleEffect(pressed ? 0.992 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.72)
            .interactiveCursor(isEnabled: self.isEnabled)
    }

    private func backgroundFill(palette: AppearancePalette, pressed: Bool) -> Color {
        if pressed {
            return palette.accent.opacity(self.colorScheme == .dark ? 0.76 : 0.82)
        }
        if self.isHovered {
            return palette.accent.opacity(self.colorScheme == .dark ? 0.94 : 0.96)
        }
        return palette.accent.opacity(self.colorScheme == .dark ? 0.84 : 0.90)
    }
}

struct DetailRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    var labelWidth: CGFloat = 118
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        HStack(alignment: .firstTextBaseline, spacing: self.compact ? 8 : 10) {
            Text(self.label)
                .font(.system(size: self.compact ? 10.5 : 11, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .frame(width: self.labelWidth, alignment: .leading)
            Text(self.value)
                .font(.system(size: self.compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, self.compact ? 3 : 4)
    }
}

struct CodeValueBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: String
    let value: String
    let actionTitle: String?
    let action: (() -> Void)?
    var isSensitive = false

    @State private var isRevealed = false

    private struct Metrics {
        let labelWidth: CGFloat
        let labelTopPadding: CGFloat
        let labelFontSize: CGFloat
        let valueFontSize: CGFloat
        let slotMinHeight: CGFloat
        let slotHorizontalPadding: CGFloat
        let slotVerticalPadding: CGFloat
        let slotCornerRadius: CGFloat
        let contentSpacing: CGFloat
    }

    init(
        label: String,
        value: String,
        actionTitle: String? = nil,
        isSensitive: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.value = value
        self.actionTitle = actionTitle
        self.action = action
        self.isSensitive = isSensitive
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let metrics = self.metrics

        HStack(alignment: .top, spacing: 10) {
            self.labelText(palette: palette)
                .frame(width: metrics.labelWidth, alignment: .leading)
            self.valueField(palette: palette)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func labelText(palette: AppearancePalette) -> some View {
        let metrics = self.metrics

        Text(self.label)
            .font(.system(size: metrics.labelFontSize, weight: .semibold))
            .foregroundStyle(palette.textMuted)
            .lineLimit(2)
            .padding(.top, metrics.labelTopPadding)
    }

    @ViewBuilder
    private func valueField(palette: AppearancePalette) -> some View {
        let metrics = self.metrics

        HStack(alignment: self.isMultilineValue ? .top : .center, spacing: metrics.contentSpacing) {
            Text(self.displayValue)
                .font(.system(size: metrics.valueFontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .lineSpacing(self.isMultilineValue ? 1.5 : 0)
                .fixedSize(horizontal: false, vertical: true)

            if self.hasTrailingControls {
                HStack(spacing: 5) {
                    if self.isSensitive && self.canReveal {
                        Button {
                            self.isRevealed.toggle()
                        } label: {
                            Image(systemName: self.isRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(InlineIconButtonStyle())
                        .help(self.isRevealed ? "Hide" : "Reveal")
                    }

                    if let action {
                        Button(action: action) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(InlineIconButtonStyle())
                        .help(self.actionTitle ?? "")
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                .padding(.top, self.isMultilineValue ? 1 : 0)
            }
        }
        .frame(minHeight: metrics.slotMinHeight, alignment: .leading)
        .padding(.horizontal, metrics.slotHorizontalPadding)
        .padding(.vertical, metrics.slotVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.slotCornerRadius, style: .continuous)
                .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.9 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.slotCornerRadius, style: .continuous)
                .stroke(palette.border.opacity(self.colorScheme == .dark ? 0.98 : 0.9), lineWidth: 1)
        )
        .shadow(
            color: palette.shadow.opacity(self.colorScheme == .dark ? 0.0 : 0.025),
            radius: 4,
            x: 0,
            y: 1
        )
    }

    private var metrics: Metrics {
        if self.isMultilineValue {
            return Metrics(
                labelWidth: 146,
                labelTopPadding: 5,
                labelFontSize: 10.5,
                valueFontSize: 11.5,
                slotMinHeight: 44,
                slotHorizontalPadding: 10,
                slotVerticalPadding: 7,
                slotCornerRadius: 11,
                contentSpacing: 8
            )
        }

        return Metrics(
            labelWidth: 138,
            labelTopPadding: 5,
            labelFontSize: 10.5,
            valueFontSize: 11.5,
            slotMinHeight: 34,
            slotHorizontalPadding: 10,
            slotVerticalPadding: 6.5,
            slotCornerRadius: 11,
            contentSpacing: 8
        )
    }

    private var canReveal: Bool {
        let trimmed = self.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false && trimmed != "—"
    }

    private var hasTrailingControls: Bool {
        (self.isSensitive && self.canReveal) || self.action != nil
    }

    private var isMultilineValue: Bool {
        self.displayValue.contains("\n")
    }

    private var displayValue: String {
        guard self.isSensitive, self.isRevealed == false else { return self.value }
        let trimmed = self.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return self.value }
        return RequestLogPresentation.maskedAPIKey(trimmed)
    }
}

struct DashboardNavigationHintCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let detail: String
    let actionTitle: String
    let isCompact: Bool
    let action: () -> Void

    init(
        title: String,
        detail: String,
        actionTitle: String,
        isCompact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.isCompact = isCompact
        self.action = action
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.isCompact ? 6 : 10) {
            Text(self.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textMuted)

            Text(self.detail)
                .font(.system(size: self.isCompact ? 10 : 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(self.isCompact ? 2 : 4)
                .fixedSize(horizontal: false, vertical: true)

            if self.isCompact {
                Button(self.actionTitle, action: self.action)
                    .buttonStyle(QuietCapsuleButtonStyle(tint: palette.accent, compact: true))
            } else {
                Button(self.actionTitle, action: self.action)
                    .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }
        }
        .padding(self.isCompact ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: self.isCompact ? 16 : 20, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.isCompact ? 16 : 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

struct EmptyStatePanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let detail: String

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.accentSoft.opacity(0.85))
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
                .frame(width: 38, height: 38)

                Text(self.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }

            Text(self.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.94 : 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

struct CompactActionToolbarButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let title: String
    let helpText: String
    let symbol: String
    let tone: StatusPill.Tone
    let action: () -> Void
    var compact = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let iconForeground = self.iconForegroundColor(palette)

        Button(action: self.action) {
            HStack(spacing: self.compact ? 5 : 6) {
                Image(systemName: self.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconForeground)

                Text(self.title)
                    .font(.system(size: self.compact ? 9.5 : 10.5, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, self.compact ? 7 : 9)
            .padding(.vertical, self.compact ? 5 : 6)
            .contentShape(Capsule())
        }
        .buttonStyle(CompactActionToolbarButtonStyle(tone: self.tone, isHovered: self.isHovered, compact: self.compact))
        .interactiveCursor(isEnabled: self.isEnabled)
        .help("\(self.title)\n\(self.helpText)")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                self.isHovered = hovering
            }
        }
    }

    private func iconForegroundColor(_ palette: AppearancePalette) -> Color {
        switch self.tone {
        case .accent:
            return palette.accent
        case .success:
            return palette.success
        case .warning:
            return palette.warning
        case .danger:
            return palette.danger
        case .neutral:
            return palette.textSecondary
        }
    }
}

struct QuickActionWrapLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let arrangement = self.arrangeRows(
            in: proposal.width ?? .greatestFiniteMagnitude,
            subviews: subviews
        )
        return CGSize(width: arrangement.width, height: arrangement.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let availableWidth = bounds.width > 0 ? bounds.width : (proposal.width ?? .greatestFiniteMagnitude)
        let arrangement = self.arrangeRows(in: availableWidth, subviews: subviews)

        for row in arrangement.rows {
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private func arrangeRows(
        in maxWidth: CGFloat,
        subviews: Subviews
    ) -> (rows: [QuickActionWrapRow], width: CGFloat, height: CGFloat) {
        guard !subviews.isEmpty else {
            return ([], 0, 0)
        }

        let lineLimit = max(maxWidth, 1)
        var rows: [QuickActionWrapRow] = []
        var currentItems: [QuickActionWrapItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        func flushRow() {
            guard !currentItems.isEmpty else { return }
            rows.append(
                QuickActionWrapRow(
                    items: currentItems,
                    width: rowWidth,
                    height: rowHeight
                )
            )
            contentWidth = max(contentWidth, rowWidth)
            currentY += rowHeight + self.verticalSpacing
            currentItems.removeAll(keepingCapacity: true)
            currentX = 0
            rowWidth = 0
            rowHeight = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needsWrap = currentX > 0 && currentX + size.width > lineLimit

            if needsWrap {
                flushRow()
            }

            let itemOrigin = CGPoint(x: currentX, y: currentY)
            currentItems.append(
                QuickActionWrapItem(
                    subview: subview,
                    size: size,
                    origin: itemOrigin
                )
            )
            rowWidth = currentX + size.width
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + self.horizontalSpacing
        }

        flushRow()

        let contentHeight = rows.reduce(CGFloat.zero) { partial, row in
            partial + row.height
        } + self.verticalSpacing * CGFloat(max(rows.count - 1, 0))

        return (rows, contentWidth, contentHeight)
    }
}

private struct QuickActionWrapRow {
    let items: [QuickActionWrapItem]
    let width: CGFloat
    let height: CGFloat
}

private struct QuickActionWrapItem {
    let subview: LayoutSubview
    let size: CGSize
    let origin: CGPoint
}

private struct CompactActionToolbarButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let tone: StatusPill.Tone
    let isHovered: Bool
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)
        let isPressed = configuration.isPressed && self.isEnabled
        let hoverActive = self.isHovered && self.isEnabled

        return configuration.label
            .background(
                Capsule(style: .continuous)
                    .fill(colors.fill.opacity(isPressed ? 0.90 : 1.0))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(colors.border, lineWidth: hoverActive ? 1.2 : 1)
            )
            .shadow(
                color: colors.shadow.opacity(isPressed ? 0.05 : (hoverActive ? 0.10 : 0.06)),
                radius: self.compact ? (hoverActive ? 4 : 3) : (hoverActive ? 6 : 4),
                x: 0,
                y: self.compact ? (hoverActive ? 2 : 1) : (hoverActive ? 3 : 1.5)
            )
            .scaleEffect(isPressed ? 0.99 : (hoverActive ? 1.003 : 1.0))
            .opacity(self.isEnabled ? 1.0 : 0.86)
            .animation(.easeOut(duration: 0.14), value: isPressed)
            .animation(.easeOut(duration: 0.18), value: hoverActive)
    }

    private func colors(palette: AppearancePalette) -> (
        fill: Color,
        border: Color,
        shadow: Color
    ) {
        guard self.isEnabled else {
            return (
                palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
                palette.border.opacity(self.colorScheme == .dark ? 0.94 : 1.0),
                palette.shadow.opacity(0.04)
            )
        }

        switch self.tone {
        case .accent:
            return (
                palette.panel.opacity(self.colorScheme == .dark ? 0.90 : 1.0),
                palette.accent.opacity(0.22),
                palette.accent
            )
        case .success:
            return (
                palette.panel.opacity(self.colorScheme == .dark ? 0.90 : 1.0),
                palette.success.opacity(0.22),
                palette.success
            )
        case .warning:
            return (
                palette.panel.opacity(self.colorScheme == .dark ? 0.90 : 1.0),
                palette.warning.opacity(0.22),
                palette.warning
            )
        case .danger:
            return (
                palette.panel.opacity(self.colorScheme == .dark ? 0.90 : 1.0),
                palette.danger.opacity(0.22),
                palette.danger
            )
        case .neutral:
            return (
                palette.panelRaised.opacity(self.colorScheme == .dark ? 0.92 : 1.0),
                palette.border,
                palette.shadow.opacity(0.08)
            )
        }
    }
}

struct FormFieldPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var footer: String?
    let compact: Bool
    @ViewBuilder var content: Content

    init(
        title: String,
        footer: String? = nil,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 5 : 6) {
            Text(self.title)
                .font(.system(size: self.compact ? 10.5 : 11, weight: .semibold))
                .foregroundStyle(palette.textMuted)

            self.content

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(self.compact ? 2 : 3)
            }
        }
        .padding(.horizontal, self.compact ? 0 : 2)
        .padding(.vertical, self.compact ? 2 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppActionButtonColors {
    let fillTop: Color
    let fillBottom: Color
    let foreground: Color
    let border: Color
    let shadow: Color
}

private func appActionButtonColors(
    kind: AppActionButtonStyle.Kind,
    palette: AppearancePalette,
    colorScheme: ColorScheme,
    isEnabled: Bool
) -> AppActionButtonColors {
    guard isEnabled else {
        return AppActionButtonColors(
            fillTop: palette.panelRaised.opacity(colorScheme == .dark ? 0.92 : 0.98),
            fillBottom: palette.panelRaised.opacity(colorScheme == .dark ? 0.92 : 0.98),
            foreground: palette.textSecondary.opacity(colorScheme == .dark ? 0.8 : 0.72),
            border: palette.border.opacity(colorScheme == .dark ? 0.9 : 1.0),
            shadow: palette.shadow.opacity(0.04)
        )
    }

    switch kind {
    case .primary:
        return AppActionButtonColors(
            fillTop: palette.accent,
            fillBottom: palette.accent.opacity(colorScheme == .dark ? 0.88 : 1.0),
            foreground: .white,
            border: palette.accent.opacity(0.24),
            shadow: palette.accent.opacity(0.22)
        )
    case .secondary:
        return AppActionButtonColors(
            fillTop: palette.panel,
            fillBottom: palette.panel,
            foreground: palette.textPrimary,
            border: palette.border,
            shadow: palette.shadow.opacity(0.08)
        )
    case .danger:
        return AppActionButtonColors(
            fillTop: palette.danger,
            fillBottom: palette.danger.opacity(colorScheme == .dark ? 0.88 : 1.0),
            foreground: .white,
            border: palette.danger.opacity(0.22),
            shadow: palette.danger.opacity(0.22)
        )
    }
}

struct AppActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case danger
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = self.colors(palette: palette)
        let pressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colors.fillTop.opacity(pressed ? 0.92 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(colors.border, lineWidth: 1)
            )
            .shadow(color: colors.shadow.opacity(pressed ? 0.08 : 1.0), radius: 10, x: 0, y: 6)
            .scaleEffect(pressed ? 0.985 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.9)
            .animation(.easeOut(duration: 0.14), value: pressed)
            .interactiveCursor(isEnabled: self.isEnabled)
    }

    private func colors(palette: AppearancePalette) -> AppActionButtonColors {
        appActionButtonColors(
            kind: self.kind,
            palette: palette,
            colorScheme: self.colorScheme,
            isEnabled: self.isEnabled
        )
    }
}

struct TopBarCompactActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let kind: AppActionButtonStyle.Kind

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = appActionButtonColors(
            kind: self.kind,
            palette: palette,
            colorScheme: self.colorScheme,
            isEnabled: self.isEnabled
        )
        let pressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(colors.fillTop.opacity(pressed ? 0.92 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(colors.border, lineWidth: 1)
            )
            .shadow(color: colors.shadow.opacity(pressed ? 0.06 : 0.22), radius: 4, x: 0, y: 2)
            .scaleEffect(pressed ? 0.99 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.9)
            .animation(.easeOut(duration: 0.14), value: pressed)
            .interactiveCursor(isEnabled: self.isEnabled)
    }
}

struct AccountCardCompactActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let kind: AppActionButtonStyle.Kind

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let colors = appActionButtonColors(
            kind: self.kind,
            palette: palette,
            colorScheme: self.colorScheme,
            isEnabled: self.isEnabled
        )
        let pressed = configuration.isPressed && self.isEnabled

        return configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [colors.fillTop.opacity(pressed ? 0.9 : 1.0), colors.fillBottom.opacity(pressed ? 0.9 : 1.0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(colors.border, lineWidth: 1)
            )
            .shadow(color: colors.shadow.opacity(pressed ? 0.08 : 0.4), radius: 5, x: 0, y: 3)
            .scaleEffect(pressed ? 0.992 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.88)
            .animation(.easeOut(duration: 0.14), value: pressed)
            .interactiveCursor(isEnabled: self.isEnabled)
    }
}

struct ServiceActionBar<Accessory: View>: View {
    struct ActionConfig {
        var title: String
        var isEnabled: Bool
        var isLoading: Bool
        var kind: AppActionButtonStyle.Kind
        var action: () -> Void
    }

    @Environment(\.colorScheme) private var colorScheme

    let start: ActionConfig
    let stop: ActionConfig
    var helperText: String?
    var helperTone: StatusPill.Tone = .neutral
    let compact: Bool
    @ViewBuilder var accessory: Accessory

    init(
        start: ActionConfig,
        stop: ActionConfig,
        helperText: String? = nil,
        helperTone: StatusPill.Tone = .neutral,
        compact: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.start = start
        self.stop = stop
        self.helperText = helperText
        self.helperTone = helperTone
        self.compact = compact
        self.accessory = accessory()
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: self.compact ? 8 : 10) {
            HStack(alignment: .center, spacing: self.compact ? 8 : 10) {
                self.actionButton(for: self.start)
                self.actionButton(for: self.stop)
                self.accessory
            }

            if let helperText, !helperText.isEmpty {
                Text(helperText)
                    .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(self.helperColor(palette: palette))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(self.compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for config: ActionConfig) -> some View {
        if self.compact {
            Button(action: config.action) {
                HStack(spacing: 8) {
                    if config.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(config.kind == .danger ? .white : nil)
                    }
                    Text(config.title)
                }
                .frame(minWidth: 94)
            }
            .buttonStyle(TopBarCompactActionButtonStyle(kind: config.kind))
            .disabled(!config.isEnabled || config.isLoading)
        } else {
            Button(action: config.action) {
                HStack(spacing: 8) {
                    if config.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(config.kind == .danger ? .white : nil)
                    }
                    Text(config.title)
                }
                .frame(minWidth: 116)
            }
            .buttonStyle(AppActionButtonStyle(kind: config.kind))
            .disabled(!config.isEnabled || config.isLoading)
        }
    }

    private func helperColor(palette: AppearancePalette) -> Color {
        switch self.helperTone {
        case .accent:
            return palette.accent
        case .success:
            return palette.success
        case .warning:
            return palette.warning
        case .danger:
            return palette.danger
        case .neutral:
            return palette.textSecondary
        }
    }
}

extension ServiceActionBar where Accessory == EmptyView {
    init(
        start: ActionConfig,
        stop: ActionConfig,
        helperText: String? = nil,
        helperTone: StatusPill.Tone = .neutral,
        compact: Bool = false
    ) {
        self.init(start: start, stop: stop, helperText: helperText, helperTone: helperTone, compact: compact) {
            EmptyView()
        }
    }
}

struct QuietCapsuleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let tint: Color
    var symbol: String? = nil
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return configuration.label
            .font(.system(size: self.compact ? 9.5 : 10.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(self.tint)
            .padding(.horizontal, self.compact ? 8 : 10)
            .padding(.vertical, self.compact ? 4.5 : 6)
            .background(
                Capsule()
                    .fill(palette.panel.opacity(configuration.isPressed ? 0.92 : 1.0))
            )
            .overlay(
                Capsule()
                    .stroke(self.tint.opacity(self.colorScheme == .dark ? 0.34 : 0.18), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if let symbol, self.compact == false {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(self.tint)
                        .padding(.leading, 9)
                }
            }
            .padding(.leading, self.symbol == nil || self.compact ? 0 : 9)
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
            .interactiveCursor(isEnabled: self.isEnabled)
    }
}

struct ShellBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        ZStack {
            LinearGradient(
                colors: [palette.windowTop, palette.windowBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(palette.accentGlow.opacity(self.colorScheme == .dark ? 0.22 : 0.18))
                .frame(width: 520, height: 520)
                .blur(radius: 85)
                .offset(x: 260, y: -220)

            Circle()
                .fill(palette.info.opacity(self.colorScheme == .dark ? 0.08 : 0.06))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: -280, y: 260)

            LinearGradient(
                colors: [
                    Color.white.opacity(self.colorScheme == .dark ? 0.02 : 0.18),
                    Color.white.opacity(0.0),
                    Color.white.opacity(self.colorScheme == .dark ? 0.01 : 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct DashboardFieldChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let compact: Bool

    func body(content: Content) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        content
            .font(.system(size: self.compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, self.compact ? 9 : 10)
            .padding(.vertical, self.compact ? 7 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: self.compact ? 11 : 12, style: .continuous)
                    .fill(palette.fieldBackground.opacity(self.colorScheme == .dark ? 0.92 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: self.compact ? 11 : 12, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
    }
}

private struct InlineIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        return configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.panelRaised.opacity(configuration.isPressed ? 0.9 : 0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(palette.border.opacity(self.colorScheme == .dark ? 0.98 : 0.88), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(self.isEnabled ? 1.0 : 0.6)
            .shadow(color: palette.shadow.opacity(self.colorScheme == .dark ? 0.0 : 0.02), radius: 2, x: 0, y: 1)
            .interactiveCursor(isEnabled: self.isEnabled)
    }
}

extension View {
    func dashboardFieldChrome(compact: Bool = false) -> some View {
        self.modifier(DashboardFieldChromeModifier(compact: compact))
    }
}
#endif
