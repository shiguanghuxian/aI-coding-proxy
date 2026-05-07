#if os(macOS)
import AppKit
import Combine
import CodexProxyCore
import SwiftUI

enum DesktopBrandIcon {
    static let systemName = "bolt.horizontal.circle.fill"
}

private enum MainWindowTitlebarControlsMetrics {
    static let minimumWidth: CGFloat = 720
    static let minimumHeight: CGFloat = 44
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 2
    static let trailingInset: CGFloat = 8
}

private enum MenuBarPanelMetrics {
    static let width: CGFloat = 300
    static let height: CGFloat = 400
    static let contentPadding: CGFloat = 12
}

@main
enum CodexProxyDesktopMain {
    @MainActor private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: DesktopAppModel
    private let mainWindowDelegate: DesktopMainWindowDelegate
    private let statusItemRenderer = MenuBarStatusItemRenderer()
    private var mainWindow: NSWindow?
    private var mainHostingController: NSHostingController<DesktopMainWindowHostView>?
    private var mainTitlebarControlsAccessory: NSTitlebarAccessoryViewController?
    private var mainTitlebarControlsHostingController: NSHostingController<MainWindowTitlebarControlsHostView>?
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var statusItemRenderResult: MenuBarStatusItemRenderer.RenderResult?
    private var didLoadInitialData = false
    private var didHandleInitialHelpPresentation = false
    private var effectiveAppearanceObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let model = DesktopAppModel()
        self.model = model
        self.mainWindowDelegate = DesktopMainWindowDelegate(model: model)
        super.init()
        self.mainWindowDelegate.onClose = { [weak self] in
            self?.mainWindow = nil
            self?.mainHostingController = nil
            self?.mainTitlebarControlsAccessory = nil
            self?.mainTitlebarControlsHostingController = nil
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppearanceStore.applyAppAppearance(for: self.model.preferences.themeMode)
        DesktopMainMenuController.shared.configure(model: self.model, snapshot: self.model.menuLocalizationSnapshot)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopMainWindow.configureOpenAction { [weak self] in
            self?.openMainWindow()
        }
        self.configureEffectiveAppearanceObserver()
        self.configureModelObservers()
        self.configureStatusItem()
        self.openMainWindow()
        self.loadInitialData()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DesktopMainMenuController.shared.reinstallMenuIfNeeded()
        guard self.didLoadInitialData else { return }
        self.model.startStatsAutoRefreshIfNeeded()
        self.presentHelpWindowIfNeeded()
    }

    func applicationDidResignActive(_ notification: Notification) {
        self.model.stopStatsAutoRefresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard flag == false else { return false }
        self.openMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.model.releaseKeepAwakeSilently()
        self.model.stopStatsAutoRefresh()
        self.statusPopover?.close()
    }

    private func configureModelObservers() {
        self.model.$preferences
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAppChrome()
                }
            }
            .store(in: &self.cancellables)

        self.model.$stats
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshStatusItem()
                }
            }
            .store(in: &self.cancellables)
    }

    private func configureEffectiveAppearanceObserver() {
        self.effectiveAppearanceObservation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshSystemAppearanceIfNeeded()
            }
        }
    }

    private func refreshSystemAppearanceIfNeeded() {
        guard self.model.preferences.themeMode == .system else { return }
        guard self.model.refreshSystemColorScheme() else { return }
        self.model.refreshThemeSensitiveWindows()
    }

    private func loadInitialData() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.loadAll()
            self.didLoadInitialData = true
            if NSApp.isActive {
                self.model.startStatsAutoRefreshIfNeeded(immediately: false)
                self.presentHelpWindowIfNeeded()
            }
        }
    }

    private func openMainWindow() {
        if let mainWindow {
            self.refreshMainWindow()
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            mainWindow.orderFrontRegardless()
            return
        }

        let hostingController = NSHostingController(rootView: DesktopMainWindowHostView(model: self.model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = self.model.mainWindowTitle
        window.identifier = DesktopMainWindow.identifier
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 1160, height: 760)
        window.setContentSize(NSSize(width: 1320, height: 860))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self.mainWindowDelegate
        self.applyMainWindowChrome(window)
        AppearanceStore.applyWindowAppearance(window, for: self.model.preferences.themeMode)

        self.mainHostingController = hostingController
        self.mainWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func refreshMainWindow() {
        self.mainWindow?.title = self.model.mainWindowTitle
        self.mainHostingController?.rootView = DesktopMainWindowHostView(model: self.model)
        if let window = self.mainWindow {
            self.applyMainWindowChrome(window)
            AppearanceStore.applyWindowAppearance(window, for: self.model.preferences.themeMode)
        }
    }

    private func applyMainWindowChrome(_ window: NSWindow) {
        if window.toolbar == nil {
            window.toolbar = NSToolbar(identifier: "main-window-toolbar")
        }
        window.titlebarAppearsTransparent = true
        window.toolbar?.showsBaselineSeparator = false
        window.toolbarStyle = .unifiedCompact
        window.styleMask.insert(.fullSizeContentView)
        self.installMainWindowTitlebarControls(on: window)
    }

    private func installMainWindowTitlebarControls(on window: NSWindow) {
        let rootView = MainWindowTitlebarControlsHostView(model: self.model)

        let hostingController: NSHostingController<MainWindowTitlebarControlsHostView>
        if let existingHostingController = self.mainTitlebarControlsHostingController {
            existingHostingController.rootView = rootView
            hostingController = existingHostingController
        } else {
            let newHostingController = NSHostingController(rootView: rootView)
            newHostingController.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
            newHostingController.view.setContentHuggingPriority(.required, for: .horizontal)
            newHostingController.view.setContentHuggingPriority(.required, for: .vertical)
            self.mainTitlebarControlsHostingController = newHostingController
            hostingController = newHostingController
        }
        self.sizeMainTitlebarControlsView(hostingController.view)

        let accessory: NSTitlebarAccessoryViewController
        if let existingAccessory = self.mainTitlebarControlsAccessory {
            accessory = existingAccessory
            accessory.view = hostingController.view
        } else {
            let newAccessory = NSTitlebarAccessoryViewController()
            newAccessory.layoutAttribute = .right
            newAccessory.view = hostingController.view
            self.mainTitlebarControlsAccessory = newAccessory
            accessory = newAccessory
        }

        guard window.titlebarAccessoryViewControllers.contains(where: { $0 === accessory }) == false else {
            return
        }
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func sizeMainTitlebarControlsView(_ view: NSView) {
        let fittingSize = view.fittingSize
        view.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(MainWindowTitlebarControlsMetrics.minimumWidth, ceil(fittingSize.width)),
                height: max(MainWindowTitlebarControlsMetrics.minimumHeight, ceil(fittingSize.height))
            )
        )
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleMenuBarPanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = nil
            button.alternateImage = nil
            button.imagePosition = .imageOnly
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: MenuBarPanelMetrics.width, height: MenuBarPanelMetrics.height)
        popover.contentViewController = NSHostingController(rootView: MenuBarPanelHostView(model: self.model))

        self.statusItem = statusItem
        self.statusPopover = popover
        self.refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let statusItem = self.statusItem,
              let button = statusItem.button
        else {
            return
        }

        self.layoutStatusItemButton(button)

        let presentation = self.model.menuBarTokenUsagePresentation
        let accessibilityLabel = self.model.menuBarStatusItemAccessibilityLabel
        let scale = button.window?.backingScaleFactor
            ?? button.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let isPopoverShown = self.statusPopover?.isShown == true
        let renderedImages = self.renderStatusItemImages(
            presentation: presentation,
            foregroundColor: self.statusItemForegroundColor,
            scale: scale,
            button: button
        )

        self.statusItemRenderResult = isPopoverShown ? renderedImages.highlighted : renderedImages.normal
        button.image = isPopoverShown ? renderedImages.highlighted.image : renderedImages.normal.image
        button.alternateImage = renderedImages.highlighted.image
        statusItem.length = max(NSStatusItem.squareLength, ceil(renderedImages.normal.image.size.width))

        button.toolTip = self.model.menuBarStatusItemToolTip
        button.setAccessibilityLabel(accessibilityLabel)
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        button.highlight(isPopoverShown)

        self.layoutStatusItemButton(button)
        if let popover = self.statusPopover, popover.isShown {
            self.refreshStatusPopoverPosition(relativeTo: button)
        }
    }

    private func refreshStatusPopover() {
        if let hostingController = self.statusPopover?.contentViewController as? NSHostingController<MenuBarPanelHostView> {
            hostingController.rootView = MenuBarPanelHostView(model: self.model)
        }
    }

    private func renderStatusItemImages(
        presentation: DesktopAppModel.MenuBarTokenUsagePresentation?,
        foregroundColor: NSColor,
        scale: CGFloat,
        button: NSStatusBarButton
    ) -> (
        normal: MenuBarStatusItemRenderer.RenderResult,
        highlighted: MenuBarStatusItemRenderer.RenderResult
    ) {
        let appearance = self.statusItemDrawingAppearance

        if let presentation {
            return (
                normal: self.statusItemRenderer.render(
                    presentation: presentation,
                    symbolName: DesktopBrandIcon.systemName,
                    appearance: appearance,
                    foregroundColor: foregroundColor,
                    isHighlighted: false,
                    scale: scale
                ),
                highlighted: self.statusItemRenderer.render(
                    presentation: presentation,
                    symbolName: DesktopBrandIcon.systemName,
                    appearance: appearance,
                    foregroundColor: foregroundColor,
                    isHighlighted: true,
                    scale: scale
                )
            )
        }

        return (
            normal: self.statusItemRenderer.renderIconOnly(
                symbolName: DesktopBrandIcon.systemName,
                appearance: appearance,
                foregroundColor: foregroundColor,
                isHighlighted: false,
                scale: scale,
                sideLength: self.statusItemIconCanvasSideLength(for: button)
            ),
            highlighted: self.statusItemRenderer.renderIconOnly(
                symbolName: DesktopBrandIcon.systemName,
                appearance: appearance,
                foregroundColor: foregroundColor,
                isHighlighted: true,
                scale: scale,
                sideLength: self.statusItemIconCanvasSideLength(for: button)
            )
        )
    }

    private var statusItemDrawingAppearance: NSAppearance {
        if let appearance = NSAppearance(named: .aqua) {
            return appearance
        }
        return NSAppearance(named: .darkAqua)!
    }

    private var statusItemForegroundColor: NSColor {
        .white
    }

    private func statusItemIconCanvasSideLength(for button: NSStatusBarButton) -> CGFloat {
        let buttonHeight = ceil(button.bounds.height)
        let systemThickness = ceil(NSStatusBar.system.thickness)
        return max(buttonHeight, systemThickness, 18)
    }

    private func layoutStatusItemButton(_ button: NSStatusBarButton) {
        button.superview?.layoutSubtreeIfNeeded()
        button.layoutSubtreeIfNeeded()
    }

    private func statusPopoverAnchorRect(in button: NSStatusBarButton) -> NSRect {
        if let renderResult = self.statusItemRenderResult {
            let imageFrame = self.statusItemImageFrame(
                for: renderResult.image.size,
                in: button
            )
            let anchorRect = renderResult.visibleContentRect.offsetBy(
                dx: imageFrame.minX,
                dy: imageFrame.minY
            )
            return anchorRect.intersection(button.bounds).integral
        }

        guard let imageSize = button.image?.size else { return button.bounds }
        let imageFrame = self.statusItemImageFrame(for: imageSize, in: button)
        return imageFrame.insetBy(dx: -1, dy: -1).intersection(button.bounds).integral
    }

    private func statusItemImageFrame(for imageSize: NSSize, in button: NSStatusBarButton) -> NSRect {
        NSRect(
            x: floor((button.bounds.width - imageSize.width) / 2),
            y: floor((button.bounds.height - imageSize.height) / 2),
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private func refreshStatusPopoverPosition(relativeTo button: NSStatusBarButton) {
        guard let popover = self.statusPopover, popover.isShown else { return }
        self.layoutStatusItemButton(button)
        popover.positioningRect = self.statusPopoverAnchorRect(in: button)
    }

    private func refreshAppChrome() {
        self.refreshMainWindow()
        self.refreshStatusPopover()
        self.refreshStatusItem()
    }

    private func presentHelpWindowIfNeeded() {
        guard self.didHandleInitialHelpPresentation == false else { return }
        self.didHandleInitialHelpPresentation = true
        self.model.presentHelpWindowIfNeededOnFirstLaunch()
    }

    @objc private func toggleMenuBarPanel(_ sender: NSStatusBarButton) {
        guard let popover = self.statusPopover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            self.layoutStatusItemButton(sender)
            let anchorRect = self.statusPopoverAnchorRect(in: sender)
            popover.show(relativeTo: anchorRect, of: sender, preferredEdge: .minY)
            popover.positioningRect = anchorRect
            popover.contentViewController?.view.window?.makeKey()
            self.refreshStatusItem()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let button = self.statusItem?.button else { return }
        button.highlight(false)
        self.refreshStatusItem()
    }
}

private struct DesktopMainWindowHostView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        RootShellView(model: self.model)
            .frame(minWidth: 1160, minHeight: 760)
            .preferredColorScheme(self.model.resolvedPreferredColorScheme)
    }
}

private struct MainWindowTitlebarControlsHostView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        MainWindowTitlebarControls(
            statusText: self.model.shellServiceStatusText,
            statusTone: self.model.shellServiceStatusTone,
            isBusy: self.model.isBusy,
            helpTitle: self.model.text(.actionOpenHelp),
            onHelp: { self.model.openHelpWindow() },
            reloadTitle: self.model.text(.commonReload),
            onReload: { Task { await self.model.loadAll() } },
            requestLogsTitle: self.model.text(.actionOpenRequestLogs),
            requestLogsHelpText: self.model.text(.actionOpenRequestLogs),
            onRequestLogs: { self.model.openRequestLogsWindow() },
            keepAwakeTitle: self.model.keepAwakeActionTitle,
            keepAwakeSymbol: self.model.keepAwakeSymbolName,
            keepAwakeHelpText: self.model.keepAwakeHelperText,
            onKeepAwake: { self.model.toggleKeepAwake() },
            modeEntryTitle: self.interfaceModeToolbarTitle,
            modeEntrySymbol: self.interfaceModeToolbarSymbol,
            modeEntryHelpText: self.interfaceModeToolbarHelpText,
            onModeEntry: { self.model.switchInterfaceMode(target: self.interfaceModeToolbarTarget) }
        )
        .frame(minWidth: MainWindowTitlebarControlsMetrics.minimumWidth, alignment: .trailing)
        .padding(.top, MainWindowTitlebarControlsMetrics.topInset)
        .padding(.bottom, MainWindowTitlebarControlsMetrics.bottomInset)
        .padding(.trailing, MainWindowTitlebarControlsMetrics.trailingInset)
        .preferredColorScheme(self.model.resolvedPreferredColorScheme)
    }

    private var interfaceModeToolbarTarget: DesktopInterfaceMode {
        self.model.isMinimalMode ? .full : .minimal
    }

    private var interfaceModeToolbarTitle: String {
        self.model.label(for: self.interfaceModeToolbarTarget)
    }

    private var interfaceModeToolbarSymbol: String {
        switch self.interfaceModeToolbarTarget {
        case .minimal:
            "rectangle.compress.vertical"
        case .full:
            "rectangle.expand.vertical"
        }
    }

    private var interfaceModeToolbarHelpText: String {
        switch self.interfaceModeToolbarTarget {
        case .minimal:
            self.model.switchToMinimalModeButtonTitle
        case .full:
            self.model.switchToFullModeButtonTitle
        }
    }
}

private struct MenuBarPanelHostView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        MenuBarPanel(model: self.model)
            .id(self.model.preferences.languageMode)
            .preferredColorScheme(self.model.resolvedPreferredColorScheme)
    }
}

@MainActor
private final class DesktopMainWindowDelegate: NSObject, NSWindowDelegate {
    weak var model: DesktopAppModel?
    var onClose: (() -> Void)?

    init(model: DesktopAppModel) {
        self.model = model
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard self.model?.settings.windowCloseBehavior == .hideToMenuBar else {
            return true
        }
        sender.orderOut(nil)
        NSApp.hide(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        self.onClose?()
    }
}

struct MenuBarPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: DesktopAppModel

    var actionTitles: [String] {
        [
            self.model.text(.menuOpenMinimalMode),
            self.model.text(.menuOpenFullMode),
            self.model.text(.actionOpenRequestLogs),
            self.model.keepAwakeActionTitle,
            self.model.text(.menuReload),
            self.model.text(.menuQuit),
        ]
    }

    var body: some View {
        let palette = AppearanceStore.palette(for: self.colorScheme)

        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                self.menuScrollableContent(palette: palette)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            self.menuBottomActionBar(palette: palette)
        }
        .frame(width: MenuBarPanelMetrics.width, height: MenuBarPanelMetrics.height)
        .compactOverlayScrollbars()
    }

    private func menuScrollableContent(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.accent, palette.accent.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: DesktopBrandIcon.systemName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.model.text(.brandName))
                        .font(.system(size: 14, weight: .bold))
                    Text(self.model.shellServiceStatusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            Text(self.model.status?.publicBaseURL ?? self.model.text(.menuNoEndpoint))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            self.keepAwakeRow(palette: palette)

            Divider()

            self.menuActionButton(
                title: self.model.text(.menuOpenMinimalMode),
                kind: self.model.preferences.interfaceMode == .minimal ? .primary : .secondary
            ) {
                self.model.openInterfaceModeWindow(target: .minimal)
            }

            self.menuActionButton(
                title: self.model.text(.menuOpenFullMode),
                kind: self.model.preferences.interfaceMode == .full ? .primary : .secondary
            ) {
                self.model.openInterfaceModeWindow(target: .full)
            }

            self.menuActionButton(
                title: self.model.text(.actionOpenRequestLogs),
                kind: .secondary
            ) {
                self.model.openRequestLogsFromMenu()
            }
        }
        .padding(MenuBarPanelMetrics.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func menuBottomActionBar(palette: AppearancePalette) -> some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                Button(action: {
                    Task { await self.model.loadAll() }
                }) {
                    Text(self.model.text(.menuReload))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
                .frame(maxWidth: .infinity)

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text(self.model.text(.menuQuit))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AppActionButtonStyle(kind: .danger))
                .frame(maxWidth: .infinity)
            }
            .padding(MenuBarPanelMetrics.contentPadding)
        }
        .background(palette.panel.opacity(self.colorScheme == .dark ? 0.94 : 0.98))
    }

    private func menuActionButton(
        title: String,
        kind: AppActionButtonStyle.Kind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AppActionButtonStyle(kind: kind))
    }

    private func keepAwakeRow(palette: AppearancePalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: self.model.keepAwakeSymbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(self.model.isKeepAwakeEnabled ? palette.success : palette.textSecondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.model.text(.labelKeepAwake))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    StatusPill(
                        text: self.model.keepAwakeStatusText,
                        tone: self.model.keepAwakeStatusTone,
                        compact: true
                    )
                }

                Spacer(minLength: 0)

                Toggle(
                    self.model.text(.labelKeepAwake),
                    isOn: Binding(
                        get: { self.model.isKeepAwakeEnabled },
                        set: { self.model.setKeepAwakeEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Text(self.model.keepAwakeHelperText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.panelRaised.opacity(self.colorScheme == .dark ? 0.72 : 0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("menu-bar-keep-awake-toggle")
    }
}
#endif
