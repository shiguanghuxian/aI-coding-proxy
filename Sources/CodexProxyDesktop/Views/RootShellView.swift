#if os(macOS)
import AppKit
import CodexProxyCore
import SwiftUI

struct RootShellView: View {
    private enum MainWindowChromeMetrics {
        static let titlebarTrailingPadding: CGFloat = 20
        static let toastTopPadding: CGFloat = 44
        static let expandedSidebarWidth: CGFloat = 286
        static let collapsedSidebarWidth: CGFloat = 76
    }

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel
    @State private var isSidebarCollapsed = false

    var body: some View {
        GeometryReader { _ in
            Group {
                if self.model.isMinimalMode {
                    MinimalModeView(model: self.model)
                } else {
                    self.fullModeShell
                }
            }
            .overlay(alignment: .topTrailing) {
                ToastStackView(
                    banners: self.model.banners,
                    dismissTitle: self.model.text(.commonDismiss),
                    topPadding: MainWindowChromeMetrics.toastTopPadding,
                    trailingPadding: self.toastTrailingPadding
                ) { id in
                    self.model.dismissBanner(id: id)
                }
            }
        }
        .compactOverlayScrollbars()
    }

    private var fullModeShell: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let sidebarSummary = self.model.sidebarBrandSummary
        let accountMetricTitle = self.model.text(.labelAccounts)
        let requestMetricTitle = self.model.text(.labelRequests)

        return HStack(spacing: 0) {
            self.sidebar(
                palette: palette,
                summary: sidebarSummary,
                accountMetricTitle: accountMetricTitle,
                requestMetricTitle: requestMetricTitle
            )
            .frame(
                width: self.isSidebarCollapsed
                    ? MainWindowChromeMetrics.collapsedSidebarWidth
                    : MainWindowChromeMetrics.expandedSidebarWidth
            )

            Rectangle()
                .fill(palette.border)
                .frame(width: 1)

            self.detailShell
        }
        .animation(.easeOut(duration: 0.18), value: self.isSidebarCollapsed)
    }

    private func sidebar(
        palette: AppearancePalette,
        summary: DesktopAppModel.SidebarBrandSummary,
        accountMetricTitle: String,
        requestMetricTitle: String
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [palette.sidebarTop, palette.sidebarBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if self.isSidebarCollapsed {
                CollapsedSidebarRail(
                    pages: self.model.visiblePages,
                    selectedPage: self.model.displayedSelectedPage,
                    pageTitle: { self.model.pageTitle($0) },
                    expandTitle: self.expandSidebarTitle,
                    aboutTitle: self.model.text(.menuAboutApp),
                    onExpand: self.expandSidebar,
                    onSelectPage: { self.selectPage($0) },
                    onAbout: self.model.openAboutWindow
                )
                .transition(.opacity)
            } else {
                self.expandedSidebar(
                    summary: summary,
                    accountMetricTitle: accountMetricTitle,
                    requestMetricTitle: requestMetricTitle
                )
                .transition(.opacity)
            }
        }
        .accessibilityIdentifier(self.isSidebarCollapsed ? "main-sidebar-collapsed" : "main-sidebar-expanded")
    }

    private func expandedSidebar(
        summary: DesktopAppModel.SidebarBrandSummary,
        accountMetricTitle: String,
        requestMetricTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarBrandCard(
                summary: summary,
                accountMetricTitle: accountMetricTitle,
                requestMetricTitle: requestMetricTitle,
                collapseTitle: self.collapseSidebarTitle,
                onCollapseSidebar: self.collapseSidebar,
                onBrandIconTap: { self.model.registerRemoteManagementRevealTap() }
            )

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(self.model.visiblePages) { page in
                        SidebarPageButton(
                            icon: page.symbolName,
                            title: self.model.pageTitle(page),
                            subtitle: self.model.pageSubtitle(page),
                            isSelected: self.model.displayedSelectedPage == page
                        ) {
                            self.selectPage(page)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            SidebarAboutButton(
                title: self.model.text(.menuAboutApp),
                action: self.model.openAboutWindow
            )
        }
        .padding(18)
    }

    private var detailShell: some View {
        ZStack(alignment: .topTrailing) {
            ShellBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DashboardHeader(
                        title: self.model.currentPageTitle,
                        subtitle: self.model.currentPageSubtitle,
                        statusText: self.model.shellServiceStatusText,
                        statusTone: self.model.shellServiceStatusTone,
                        isBusy: self.model.isBusy,
                        showsControls: false,
                        reloadTitle: self.model.text(.commonReload)
                    ) {
                        Task { await self.model.loadAll() }
                    }

                    Group {
                        switch self.model.displayedSelectedPage {
                        case .overview:
                            OverviewView(model: self.model)
                        case .accounts:
                            AccountsView(model: self.model)
                        case .proxy:
                            ProxyView(model: self.model)
                        case .remote:
                            RemoteView(model: self.model)
                        case .settings:
                            SettingsView(model: self.model)
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MainWorkspaceDetailFrameProbe())
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            if let account = self.accountPoolDetailDrawerAccount {
                Rectangle()
                    .fill(Color.black.opacity(self.colorScheme == .dark ? 0.26 : 0.14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.model.dismissAccountPoolDetailDrawer()
                    }
                    .transition(.opacity)
                    .accessibilityIdentifier("account-pool-detail-drawer-backdrop")

                AccountPoolDetailDrawer(
                    model: self.model,
                    account: account,
                    width: AccountsView.accountPoolDetailDrawerWidth
                )
                .padding(.top, 24)
                .padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.88), value: self.isAccountPoolDetailDrawerVisible)
    }

    private var collapseSidebarTitle: String {
        self.model.localized(zh: "收起主菜单", en: "Collapse Sidebar")
    }

    private var expandSidebarTitle: String {
        self.model.localized(zh: "展开主菜单", en: "Expand Sidebar")
    }

    private func collapseSidebar() {
        withAnimation(.easeOut(duration: 0.18)) {
            self.isSidebarCollapsed = true
        }
    }

    private func expandSidebar() {
        withAnimation(.easeOut(duration: 0.18)) {
            self.isSidebarCollapsed = false
        }
    }

    private func selectPage(_ page: DesktopAppModel.Page) {
        guard self.model.canOpenPage(page) else { return }
        guard self.model.selectedPage != page else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            self.model.selectedPage = page
        }
    }

    private var toastTrailingPadding: CGFloat {
        let basePadding = MainWindowChromeMetrics.titlebarTrailingPadding
        guard self.model.isMinimalMode == false,
              self.isAccountPoolDetailDrawerVisible
        else {
            return basePadding
        }
        return basePadding + AccountsView.accountPoolDetailDrawerWidth + 18
    }

    private var accountPoolDetailDrawerAccount: AccountSummary? {
        guard self.model.displayedSelectedPage == .accounts,
              self.model.accountPoolDisplayMode == .list,
              self.model.isAccountPoolDetailDrawerPresented
        else {
            return nil
        }
        return self.model.selectedAccountPoolAccount
    }

    private var isAccountPoolDetailDrawerVisible: Bool {
        self.accountPoolDetailDrawerAccount != nil
    }
}

private struct MainWorkspaceDetailFrameProbe: NSViewRepresentable {
    private static let identifier = NSUserInterfaceItemIdentifier("main-workspace-detail-content")

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = Self.identifier
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = Self.identifier
    }
}

private struct SidebarBrandCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let summary: DesktopAppModel.SidebarBrandSummary
    let accountMetricTitle: String
    let requestMetricTitle: String
    let collapseTitle: String
    let onCollapseSidebar: () -> Void
    let onBrandIconTap: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.accent, palette.accent.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: DesktopBrandIcon.systemName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
                .onTapGesture(perform: self.onBrandIconTap)

                VStack(alignment: .leading, spacing: 3) {
                    Text(self.summary.brandName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(self.summary.brandSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button(action: self.onCollapseSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.7 : 0.86))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(palette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(self.collapseTitle)
                .accessibilityLabel(self.collapseTitle)
                .accessibilityIdentifier("main-sidebar-collapse-button")
            }

            HStack(alignment: .center, spacing: 7) {
                StatusPill(
                    text: self.summary.serviceText,
                    tone: self.summary.serviceTone,
                    compact: true
                )
                Text(self.summary.versionText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.textMuted)

                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                SidebarInlineMetric(
                    title: self.accountMetricTitle,
                    value: self.summary.accountCountText,
                    tone: .accent
                )
                Rectangle()
                    .fill(palette.border)
                    .frame(width: 1, height: 22)

                SidebarInlineMetric(
                    title: self.requestMetricTitle,
                    value: self.summary.requestCountText,
                    tone: .neutral
                )
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

private struct CollapsedSidebarRail: View {
    @Environment(\.colorScheme) private var colorScheme

    let pages: [DesktopAppModel.Page]
    let selectedPage: DesktopAppModel.Page
    let pageTitle: (DesktopAppModel.Page) -> String
    let expandTitle: String
    let aboutTitle: String
    let onExpand: () -> Void
    let onSelectPage: (DesktopAppModel.Page) -> Void
    let onAbout: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(spacing: 12) {
            self.iconButton(
                systemName: "sidebar.right",
                title: self.expandTitle,
                accessibilityID: "main-sidebar-expand-button",
                isSelected: false,
                action: self.onExpand
            )

            Rectangle()
                .fill(palette.border)
                .frame(width: 34, height: 1)
                .padding(.vertical, 2)

            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(self.pages) { page in
                        CollapsedSidebarPageButton(
                            icon: page.symbolName,
                            title: self.pageTitle(page),
                            accessibilityID: "main-sidebar-collapsed-page-\(page.rawValue)",
                            isSelected: self.selectedPage == page
                        ) {
                            self.onSelectPage(page)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            self.iconButton(
                systemName: "info.circle",
                title: self.aboutTitle,
                accessibilityID: "main-sidebar-collapsed-about-button",
                isSelected: false,
                action: self.onAbout
            )
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(
        systemName: String,
        title: String,
        accessibilityID: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        CollapsedSidebarPageButton(
            icon: systemName,
            title: title,
            accessibilityID: accessibilityID,
            isSelected: isSelected,
            action: action
        )
    }
}

private struct CollapsedSidebarPageButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let title: String
    let accessibilityID: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let fillOpacity = self.isSelected ? 1.0 : (self.isHovered ? 0.82 : 0.32)
        let borderOpacity = self.isSelected ? 0.42 : (self.isHovered ? 0.36 : 0.12)
        let iconColor = self.isSelected ? Color.white : palette.textSecondary

        Button(action: self.action) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: self.isSelected
                                ? [palette.accent, palette.accent.opacity(0.82)]
                                : [
                                    palette.panelRaised.opacity(fillOpacity),
                                    palette.panel.opacity(fillOpacity),
                                ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: self.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 44, height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(self.isSelected ? palette.accentGlow : palette.border.opacity(borderOpacity), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .interactiveCursor()
        .help(self.title)
        .accessibilityLabel(self.title)
        .accessibilityIdentifier(self.accessibilityID)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                self.isHovered = hovering
            }
        }
    }
}

private struct SidebarInlineMetric: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String
    let tone: MetricTile.Tone

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let foreground = self.tone == .accent ? palette.accent : palette.textPrimary

        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.textMuted)
            Text(self.value)
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarAboutButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let action: () -> Void

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        Button(action: self.action) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(self.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.panel.opacity(self.colorScheme == .dark ? 0.9 : 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

enum SidebarPageRowStyleToken: String {
    case clear
    case accent
    case accentSoft
    case accentGlow
    case border
    case panel
    case panelEmphasis
    case panelMuted
    case panelRaised
    case textPrimary
    case textSecondary
    case textMuted
    case white

    func color(in palette: AppearancePalette) -> Color {
        switch self {
        case .clear:
            return .clear
        case .accent:
            return palette.accent
        case .accentSoft:
            return palette.accentSoft
        case .accentGlow:
            return palette.accentGlow
        case .border:
            return palette.border
        case .panel:
            return palette.panel
        case .panelEmphasis:
            return palette.panelEmphasis
        case .panelMuted:
            return palette.panelMuted
        case .panelRaised:
            return palette.panelRaised
        case .textPrimary:
            return palette.textPrimary
        case .textSecondary:
            return palette.textSecondary
        case .textMuted:
            return palette.textMuted
        case .white:
            return .white
        }
    }
}

struct SidebarPageRowStyleLayer: Equatable {
    let token: SidebarPageRowStyleToken
    let opacity: Double

    init(_ token: SidebarPageRowStyleToken, opacity: Double = 1.0) {
        self.token = token
        self.opacity = opacity
    }

    func color(in palette: AppearancePalette) -> Color {
        self.token.color(in: palette).opacity(self.opacity)
    }

    static let clear = SidebarPageRowStyleLayer(.clear, opacity: 0)
}

struct SidebarPageRowStyle: Equatable {
    let rowFillTop: SidebarPageRowStyleLayer
    let rowFillBottom: SidebarPageRowStyleLayer
    let rowBorder: SidebarPageRowStyleLayer
    let rowBorderLineWidth: CGFloat
    let titleForeground: SidebarPageRowStyleLayer
    let subtitleForeground: SidebarPageRowStyleLayer
    let iconFillTop: SidebarPageRowStyleLayer
    let iconFillBottom: SidebarPageRowStyleLayer
    let iconBorder: SidebarPageRowStyleLayer
    let iconForeground: SidebarPageRowStyleLayer
    let indicatorTop: SidebarPageRowStyleLayer
    let indicatorBottom: SidebarPageRowStyleLayer
    let indicatorWidth: CGFloat
    let indicatorLeadingInset: CGFloat
    let indicatorVerticalInset: CGFloat
    let indicatorTrailingGap: CGFloat
    let chevronForeground: SidebarPageRowStyleLayer
    let shadow: SidebarPageRowStyleLayer
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat

    static func resolve(colorScheme: ColorScheme, isSelected: Bool, isHovered: Bool) -> SidebarPageRowStyle {
        if isSelected {
            return colorScheme == .dark ? Self.selectedDark : Self.selectedLight
        }
        if isHovered {
            return colorScheme == .dark ? Self.hoverDark : Self.hoverLight
        }
        return colorScheme == .dark ? Self.idleDark : Self.idleLight
    }

    private static let selectedDark = SidebarPageRowStyle(
        rowFillTop: .init(.accentSoft, opacity: 0.98),
        rowFillBottom: .init(.panel, opacity: 0.98),
        rowBorder: .init(.accent, opacity: 0.42),
        rowBorderLineWidth: 1.25,
        titleForeground: .init(.textPrimary, opacity: 1.0),
        subtitleForeground: .init(.accent, opacity: 0.92),
        iconFillTop: .init(.accent, opacity: 1.0),
        iconFillBottom: .init(.accent, opacity: 0.82),
        iconBorder: .init(.accentGlow, opacity: 0.78),
        iconForeground: .init(.white, opacity: 0.98),
        indicatorTop: .clear,
        indicatorBottom: .clear,
        indicatorWidth: 0,
        indicatorLeadingInset: 0,
        indicatorVerticalInset: 0,
        indicatorTrailingGap: 0,
        chevronForeground: .clear,
        shadow: .init(.accentGlow, opacity: 0.20),
        shadowRadius: 10,
        shadowYOffset: 4
    )

    private static let selectedLight = SidebarPageRowStyle(
        rowFillTop: .init(.accentSoft, opacity: 1.0),
        rowFillBottom: .init(.panel, opacity: 1.0),
        rowBorder: .init(.accent, opacity: 0.16),
        rowBorderLineWidth: 1.1,
        titleForeground: .init(.textPrimary, opacity: 1.0),
        subtitleForeground: .init(.accent, opacity: 0.78),
        iconFillTop: .init(.accent, opacity: 1.0),
        iconFillBottom: .init(.accent, opacity: 0.82),
        iconBorder: .init(.accent, opacity: 0.24),
        iconForeground: .init(.white, opacity: 0.98),
        indicatorTop: .clear,
        indicatorBottom: .clear,
        indicatorWidth: 0,
        indicatorLeadingInset: 0,
        indicatorVerticalInset: 0,
        indicatorTrailingGap: 0,
        chevronForeground: .clear,
        shadow: .init(.accentGlow, opacity: 0.10),
        shadowRadius: 8,
        shadowYOffset: 3
    )

    private static let hoverDark = SidebarPageRowStyle(
        rowFillTop: .init(.panelRaised, opacity: 0.82),
        rowFillBottom: .init(.panel, opacity: 0.92),
        rowBorder: .init(.border, opacity: 0.88),
        rowBorderLineWidth: 1.0,
        titleForeground: .init(.textPrimary, opacity: 1.0),
        subtitleForeground: .init(.textMuted, opacity: 1.0),
        iconFillTop: .init(.panelRaised, opacity: 0.98),
        iconFillBottom: .init(.panelMuted, opacity: 0.94),
        iconBorder: .init(.border, opacity: 0.54),
        iconForeground: .init(.textPrimary, opacity: 1.0),
        indicatorTop: .clear,
        indicatorBottom: .clear,
        indicatorWidth: 0,
        indicatorLeadingInset: 0,
        indicatorVerticalInset: 0,
        indicatorTrailingGap: 0,
        chevronForeground: .clear,
        shadow: .clear,
        shadowRadius: 0,
        shadowYOffset: 0
    )

    private static let hoverLight = SidebarPageRowStyle(
        rowFillTop: .init(.panelRaised, opacity: 1.0),
        rowFillBottom: .init(.panel, opacity: 1.0),
        rowBorder: .init(.border, opacity: 0.72),
        rowBorderLineWidth: 1.0,
        titleForeground: .init(.textPrimary, opacity: 1.0),
        subtitleForeground: .init(.textMuted, opacity: 1.0),
        iconFillTop: .init(.panelRaised, opacity: 0.98),
        iconFillBottom: .init(.panelMuted, opacity: 0.92),
        iconBorder: .init(.border, opacity: 0.42),
        iconForeground: .init(.textPrimary, opacity: 1.0),
        indicatorTop: .clear,
        indicatorBottom: .clear,
        indicatorWidth: 0,
        indicatorLeadingInset: 0,
        indicatorVerticalInset: 0,
        indicatorTrailingGap: 0,
        chevronForeground: .clear,
        shadow: .clear,
        shadowRadius: 0,
        shadowYOffset: 0
    )

    private static let idleDark = SidebarPageRowStyle(
        rowFillTop: .clear,
        rowFillBottom: .clear,
        rowBorder: .clear,
        rowBorderLineWidth: 0,
        titleForeground: .init(.textPrimary, opacity: 1.0),
        subtitleForeground: .init(.textMuted, opacity: 1.0),
        iconFillTop: .init(.panelMuted, opacity: 0.92),
        iconFillBottom: .init(.panel, opacity: 0.88),
        iconBorder: .init(.border, opacity: 0.12),
        iconForeground: .init(.textSecondary, opacity: 1.0),
        indicatorTop: .clear,
        indicatorBottom: .clear,
        indicatorWidth: 0,
        indicatorLeadingInset: 0,
        indicatorVerticalInset: 0,
        indicatorTrailingGap: 0,
        chevronForeground: .clear,
        shadow: .clear,
        shadowRadius: 0,
        shadowYOffset: 0
    )

    private static let idleLight = SidebarPageRowStyle(
        rowFillTop: .clear,
        rowFillBottom: .clear,
        rowBorder: .clear,
        rowBorderLineWidth: 0,
        titleForeground: .init(.textPrimary, opacity: 1.0),
        subtitleForeground: .init(.textMuted, opacity: 1.0),
        iconFillTop: .init(.panelMuted, opacity: 0.92),
        iconFillBottom: .init(.panel, opacity: 0.96),
        iconBorder: .init(.border, opacity: 0.08),
        iconForeground: .init(.textSecondary, opacity: 1.0),
        indicatorTop: .clear,
        indicatorBottom: .clear,
        indicatorWidth: 0,
        indicatorLeadingInset: 0,
        indicatorVerticalInset: 0,
        indicatorTrailingGap: 0,
        chevronForeground: .clear,
        shadow: .clear,
        shadowRadius: 0,
        shadowYOffset: 0
    )
}

struct SidebarPageButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            SidebarPageRow(
                icon: self.icon,
                title: self.title,
                subtitle: self.subtitle,
                isSelected: self.isSelected,
                isHovered: self.isHovered
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .interactiveCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                self.isHovered = hovering
            }
        }
    }
}

private struct SidebarPageRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)
        let style = SidebarPageRowStyle.resolve(
            colorScheme: self.colorScheme,
            isSelected: self.isSelected,
            isHovered: self.isHovered
        )

        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                style.iconFillTop.color(in: palette),
                                style.iconFillBottom.color(in: palette),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: self.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style.iconForeground.color(in: palette))
            }
            .frame(width: 40, height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(style.iconBorder.color(in: palette), lineWidth: self.isSelected ? 1.1 : 1.0)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(.system(size: 13, weight: self.isSelected ? .bold : .semibold))
                    .foregroundStyle(style.titleForeground.color(in: palette))
                Text(self.subtitle)
                    .font(.system(size: 11, weight: self.isSelected ? .semibold : .medium))
                    .foregroundStyle(style.subtitleForeground.color(in: palette))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                style.rowFillTop.color(in: palette),
                                style.rowFillBottom.color(in: palette),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if style.indicatorWidth > 0 {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    style.indicatorTop.color(in: palette),
                                    style.indicatorBottom.color(in: palette),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: style.indicatorWidth)
                        .padding(.vertical, style.indicatorVerticalInset)
                        .padding(.leading, style.indicatorLeadingInset)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(style.rowBorder.color(in: palette), lineWidth: style.rowBorderLineWidth)
        )
        .shadow(color: style.shadow.color(in: palette), radius: style.shadowRadius, x: 0, y: style.shadowYOffset)
        .animation(.easeOut(duration: 0.16), value: self.isSelected)
        .animation(.easeOut(duration: 0.14), value: self.isHovered)
    }
}
#endif
