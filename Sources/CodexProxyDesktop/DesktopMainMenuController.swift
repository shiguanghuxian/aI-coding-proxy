#if os(macOS)
import AppKit

struct DesktopMenuLocalizationSnapshot: Equatable, Sendable {
    struct ViewPageItem: Equatable, Sendable {
        let pageRawValue: String
        let title: String
        let isEnabled: Bool
    }

    let appMenuTitle: String
    let aboutApp: String
    let settings: String
    let checkForUpdates: String
    let hideApp: String
    let hideOthers: String
    let showAll: String
    let quit: String
    let editMenuTitle: String
    let viewMenuTitle: String
    let helpMenuTitle: String
    let undo: String
    let redo: String
    let cut: String
    let copy: String
    let paste: String
    let selectAll: String
    let openMinimalMode: String
    let openFullMode: String
    let openRequestLogs: String
    let reload: String
    let helpWindowTitle: String
    let onboardingWindowTitle: String
    let assistantWindowTitle: String
    let viewPageItems: [ViewPageItem]

    @MainActor
    init(model: DesktopAppModel) {
        self.appMenuTitle = model.text(.brandName)
        self.aboutApp = model.text(.menuAboutApp)
        self.settings = model.text(.menuSettings)
        self.checkForUpdates = model.localized(zh: "检查更新…", en: "Check for Updates…")
        self.hideApp = model.text(.menuHideApp)
        self.hideOthers = model.text(.menuHideOthers)
        self.showAll = model.text(.menuShowAll)
        self.quit = model.text(.menuQuit)
        self.editMenuTitle = model.text(.menuEdit)
        self.viewMenuTitle = model.text(.menuView)
        self.helpMenuTitle = model.text(.actionOpenHelp)
        self.undo = model.text(.menuUndo)
        self.redo = model.text(.menuRedo)
        self.cut = model.text(.menuCut)
        self.copy = model.text(.commonCopy)
        self.paste = model.text(.menuPaste)
        self.selectAll = model.text(.menuSelectAll)
        self.openMinimalMode = model.text(.menuOpenMinimalMode)
        self.openFullMode = model.text(.menuOpenFullMode)
        self.openRequestLogs = model.text(.actionOpenRequestLogs)
        self.reload = model.text(.menuReload)
        self.helpWindowTitle = model.helpWindowTitle
        self.onboardingWindowTitle = model.onboardingWindowTitle
        self.assistantWindowTitle = model.localized(zh: "AI 助手", en: "Assistant")
        self.viewPageItems = model.visiblePages.map { page in
            ViewPageItem(
                pageRawValue: page.rawValue,
                title: model.pageTitle(page),
                isEnabled: model.displayedSelectedPage != page
            )
        }
    }

    func hasSameVisibleContent(as other: DesktopMenuLocalizationSnapshot) -> Bool {
        self.appMenuTitle == other.appMenuTitle
            && self.aboutApp == other.aboutApp
            && self.settings == other.settings
            && self.checkForUpdates == other.checkForUpdates
            && self.hideApp == other.hideApp
            && self.hideOthers == other.hideOthers
            && self.showAll == other.showAll
            && self.quit == other.quit
            && self.editMenuTitle == other.editMenuTitle
            && self.viewMenuTitle == other.viewMenuTitle
            && self.helpMenuTitle == other.helpMenuTitle
            && self.undo == other.undo
            && self.redo == other.redo
            && self.cut == other.cut
            && self.copy == other.copy
            && self.paste == other.paste
            && self.selectAll == other.selectAll
            && self.openMinimalMode == other.openMinimalMode
            && self.openFullMode == other.openFullMode
            && self.openRequestLogs == other.openRequestLogs
            && self.reload == other.reload
            && self.helpWindowTitle == other.helpWindowTitle
            && self.onboardingWindowTitle == other.onboardingWindowTitle
            && self.assistantWindowTitle == other.assistantWindowTitle
            && self.viewPageItems.map(\.pageRawValue) == other.viewPageItems.map(\.pageRawValue)
            && self.viewPageItems.map(\.title) == other.viewPageItems.map(\.title)
    }
}

@MainActor
final class DesktopMainMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = DesktopMainMenuController()

    private var model: DesktopAppModel?
    private var snapshot: DesktopMenuLocalizationSnapshot?
    private var reinstallWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private var mainMenu: NSMenu?
    private var appMenuItem: NSMenuItem?
    private var editMenuItem: NSMenuItem?
    private var viewMenuItem: NSMenuItem?
    private var helpMenuItem: NSMenuItem?

    private override init() {
        super.init()
        let notificationCenter = NotificationCenter.default
        let refreshNames: [Notification.Name] = [
            NSApplication.didFinishLaunchingNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        self.observers = refreshNames.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.scheduleReinstallMenuIfNeeded()
                }
            }
        }
    }

    func configure(model: DesktopAppModel, snapshot: DesktopMenuLocalizationSnapshot) {
        self.model = model
        let previousSnapshot = self.snapshot
        guard previousSnapshot != snapshot || self.isManagedMenuInstalled == false else { return }
        self.syncMenu(snapshot: snapshot, previousSnapshot: previousSnapshot)
        self.snapshot = snapshot
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.editMenuItem?.submenu {
            self.updateEditValidation()
        } else if menu === self.viewMenuItem?.submenu {
            self.updateViewValidation()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let actionName = menuItem.representedObject as? String {
            if let page = DesktopAppModel.Page(rawValue: actionName) {
                return self.model?.displayedSelectedPage != page
            }
            return self.canPerformResponderAction(Selector(actionName))
        }
        return true
    }

    private func installMenu(snapshot: DesktopMenuLocalizationSnapshot) {
        let mainMenu = NSMenu(title: "MainMenu")
        mainMenu.autoenablesItems = false

        let appMenuItem = NSMenuItem(title: snapshot.appMenuTitle, action: nil, keyEquivalent: "")
        let editMenuItem = NSMenuItem(title: snapshot.editMenuTitle, action: nil, keyEquivalent: "")
        let viewMenuItem = NSMenuItem(title: snapshot.viewMenuTitle, action: nil, keyEquivalent: "")
        let helpMenuItem = NSMenuItem(title: snapshot.helpMenuTitle, action: nil, keyEquivalent: "")
        let appMenu = self.appMenu(snapshot: snapshot)
        let editMenu = self.editMenu(snapshot: snapshot)
        let viewMenu = self.viewMenu(snapshot: snapshot)
        let helpMenu = self.helpMenu(snapshot: snapshot)

        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(editMenuItem)
        mainMenu.addItem(viewMenuItem)
        mainMenu.addItem(helpMenuItem)

        mainMenu.setSubmenu(appMenu, for: appMenuItem)
        mainMenu.setSubmenu(editMenu, for: editMenuItem)
        mainMenu.setSubmenu(viewMenu, for: viewMenuItem)
        mainMenu.setSubmenu(helpMenu, for: helpMenuItem)

        self.mainMenu = mainMenu
        self.appMenuItem = appMenuItem
        self.editMenuItem = editMenuItem
        self.viewMenuItem = viewMenuItem
        self.helpMenuItem = helpMenuItem
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = nil
        NSApp.helpMenu = helpMenu
    }

    func reinstallMenuIfNeeded() {
        guard let snapshot, self.isManagedMenuInstalled == false else { return }
        self.installMenu(snapshot: snapshot)
    }

    private func scheduleReinstallMenuIfNeeded() {
        guard NSApp.isRunning else { return }
        self.reinstallWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { [weak self] in
                self?.reinstallMenuIfNeeded()
            }
        }
        self.reinstallWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private var isManagedMenuInstalled: Bool {
        guard let mainMenu = NSApp.mainMenu,
              mainMenu === self.mainMenu,
              let appMenuItem,
              let editMenuItem,
              let viewMenuItem,
              let helpMenuItem,
              mainMenu.items.count == 4
        else {
            return false
        }
        return mainMenu.items[0] === appMenuItem
            && mainMenu.items[1] === editMenuItem
            && mainMenu.items[2] === viewMenuItem
            && mainMenu.items[3] === helpMenuItem
    }

    private func syncMenu(snapshot: DesktopMenuLocalizationSnapshot, previousSnapshot: DesktopMenuLocalizationSnapshot?) {
        if self.isManagedMenuInstalled {
            if let previousSnapshot, snapshot.hasSameVisibleContent(as: previousSnapshot) {
                return
            }
            self.applySnapshotInPlace(snapshot)
        } else {
            self.installMenu(snapshot: snapshot)
            self.scheduleReinstallMenuIfNeeded()
        }
    }

    private func applySnapshotInPlace(_ snapshot: DesktopMenuLocalizationSnapshot) {
        guard self.isManagedMenuInstalled,
              let mainMenu,
              let appMenuItem,
              let editMenuItem,
              let viewMenuItem,
              let helpMenuItem
        else {
            self.installMenu(snapshot: snapshot)
            return
        }

        appMenuItem.title = snapshot.appMenuTitle
        editMenuItem.title = snapshot.editMenuTitle
        viewMenuItem.title = snapshot.viewMenuTitle
        helpMenuItem.title = snapshot.helpMenuTitle

        let appMenu = self.appMenu(snapshot: snapshot)
        let editMenu = self.editMenu(snapshot: snapshot)
        let viewMenu = self.viewMenu(snapshot: snapshot)
        let helpMenu = self.helpMenu(snapshot: snapshot)

        mainMenu.setSubmenu(appMenu, for: appMenuItem)
        mainMenu.setSubmenu(editMenu, for: editMenuItem)
        mainMenu.setSubmenu(viewMenu, for: viewMenuItem)
        mainMenu.setSubmenu(helpMenu, for: helpMenuItem)
        NSApp.windowsMenu = nil
        NSApp.helpMenu = helpMenu
    }

    private func appMenu(snapshot: DesktopMenuLocalizationSnapshot) -> NSMenu {
        let menu = NSMenu(title: snapshot.appMenuTitle)
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(self.item(snapshot.aboutApp, action: #selector(openAboutWindow(_:))))
        menu.addItem(self.item(snapshot.checkForUpdates, action: #selector(checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(self.item(snapshot.settings, action: #selector(openSettings(_:)), key: ","))
        menu.addItem(.separator())
        menu.addItem(self.item(snapshot.hideApp, action: #selector(hideApp(_:)), key: "h"))
        menu.addItem(self.item(snapshot.hideOthers, action: #selector(hideOthers(_:)), key: "h", modifiers: [.command, .option]))
        menu.addItem(self.item(snapshot.showAll, action: #selector(showAll(_:))))
        menu.addItem(.separator())
        menu.addItem(self.item(snapshot.quit, action: #selector(quit(_:)), key: "q"))
        return menu
    }

    private func editMenu(snapshot: DesktopMenuLocalizationSnapshot) -> NSMenu {
        let menu = NSMenu(title: snapshot.editMenuTitle)
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(self.responderItem(snapshot.undo, action: Selector(("undo:")), key: "z"))
        menu.addItem(self.responderItem(snapshot.redo, action: Selector(("redo:")), key: "Z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(self.responderItem(snapshot.cut, action: #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(self.responderItem(snapshot.copy, action: #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(self.responderItem(snapshot.paste, action: #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(.separator())
        menu.addItem(self.responderItem(snapshot.selectAll, action: #selector(NSText.selectAll(_:)), key: "a"))
        return menu
    }

    private func viewMenu(snapshot: DesktopMenuLocalizationSnapshot) -> NSMenu {
        let menu = NSMenu(title: snapshot.viewMenuTitle)
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(self.item(snapshot.openMinimalMode, action: #selector(openMinimalMode(_:))))
        menu.addItem(self.item(snapshot.openFullMode, action: #selector(openFullMode(_:))))
        menu.addItem(self.item(snapshot.openRequestLogs, action: #selector(openRequestLogs(_:))))
        menu.addItem(self.item(snapshot.reload, action: #selector(reload(_:)), key: "r"))
        menu.addItem(.separator())

        for page in snapshot.viewPageItems {
            let item = self.item(page.title, action: #selector(openPage(_:)))
            item.representedObject = page.pageRawValue
            item.isEnabled = page.isEnabled
            menu.addItem(item)
        }

        return menu
    }

    private func helpMenu(snapshot: DesktopMenuLocalizationSnapshot) -> NSMenu {
        let menu = NSMenu(title: snapshot.helpMenuTitle)
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(self.item(snapshot.helpWindowTitle, action: #selector(openHelpWindow(_:))))
        menu.addItem(self.item(snapshot.onboardingWindowTitle, action: #selector(startOnboarding(_:))))
        menu.addItem(.separator())
        menu.addItem(self.item(snapshot.assistantWindowTitle, action: #selector(openAssistantWindow(_:))))
        return menu
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private func responderItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = self.item(title, action: #selector(sendResponderAction(_:)), key: key, modifiers: modifiers)
        item.representedObject = NSStringFromSelector(action)
        item.isEnabled = self.canPerformResponderAction(action)
        return item
    }

    private func updateEditValidation() {
        for item in self.editMenuItem?.submenu?.items ?? [] {
            guard let actionName = item.representedObject as? String else { continue }
            item.isEnabled = self.canPerformResponderAction(Selector(actionName))
        }
    }

    private func updateViewValidation() {
        guard let model else { return }
        for item in self.viewMenuItem?.submenu?.items ?? [] {
            guard let rawValue = item.representedObject as? String,
                  let page = DesktopAppModel.Page(rawValue: rawValue)
            else {
                continue
            }
            item.isEnabled = model.displayedSelectedPage != page
        }
    }

    private func canPerformResponderAction(_ action: Selector) -> Bool {
        NSApp.target(forAction: action, to: nil, from: nil) != nil
    }

    @objc func sendResponderAction(_ sender: NSMenuItem) {
        guard let actionName = sender.representedObject as? String else { return }
        NSApp.sendAction(Selector(actionName), to: nil, from: nil)
        self.updateEditValidation()
    }

    @objc func openAboutWindow(_ sender: NSMenuItem) {
        self.model?.openAboutWindow()
    }

    @objc func checkForUpdates(_ sender: NSMenuItem) {
        guard let model else { return }
        model.openAboutWindow()
        model.checkForAppUpdates(isAutomatic: false)
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        self.model?.openSettingsAppearancePage()
    }

    @objc func hideApp(_ sender: NSMenuItem) {
        NSApp.hide(nil)
    }

    @objc func hideOthers(_ sender: NSMenuItem) {
        NSApp.hideOtherApplications(nil)
    }

    @objc func showAll(_ sender: NSMenuItem) {
        NSApp.unhideAllApplications(nil)
    }

    @objc func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc func openMinimalMode(_ sender: NSMenuItem) {
        self.model?.openInterfaceModeWindow(target: .minimal)
    }

    @objc func openFullMode(_ sender: NSMenuItem) {
        self.model?.openInterfaceModeWindow(target: .full)
    }

    @objc func openRequestLogs(_ sender: NSMenuItem) {
        self.model?.openRequestLogsFromMenu()
    }

    @objc func reload(_ sender: NSMenuItem) {
        guard let model else { return }
        Task { await model.loadAll() }
    }

    @objc func openPage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let page = DesktopAppModel.Page(rawValue: rawValue)
        else {
            return
        }
        self.model?.openDashboard(page)
    }

    @objc func openHelpWindow(_ sender: NSMenuItem) {
        self.model?.openHelpWindow()
    }

    @objc func openAssistantWindow(_ sender: NSMenuItem) {
        self.model?.openAssistantWindow()
    }

    @objc func startOnboarding(_ sender: NSMenuItem) {
        self.model?.startOnboarding()
    }
}
#endif
