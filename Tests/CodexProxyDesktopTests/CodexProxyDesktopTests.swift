#if os(macOS)
import AppKit
import Combine
import CodexProxyCore
import CodexProxyDeploy
import SwiftUI
import XCTest
@testable import CodexProxyDesktop

@MainActor
private final class AboutWindowControllerSpy: AboutWindowControlling {
    private(set) var showWindowCallCount = 0
    private(set) var closeWindowCallCount = 0
    private(set) var refreshWindowCallCount = 0

    func showWindow() {
        self.showWindowCallCount += 1
    }

    func closeWindow() {
        self.closeWindowCallCount += 1
    }

    func refreshWindow() {
        self.refreshWindowCallCount += 1
    }
}

@MainActor
private final class HelpWindowControllerSpy: HelpWindowControlling {
    private(set) var showWindowCallCount = 0
    private(set) var closeWindowCallCount = 0
    private(set) var refreshWindowCallCount = 0

    func showWindow() {
        self.showWindowCallCount += 1
    }

    func closeWindow() {
        self.closeWindowCallCount += 1
    }

    func refreshWindow() {
        self.refreshWindowCallCount += 1
    }

    func reset() {
        self.showWindowCallCount = 0
        self.closeWindowCallCount = 0
        self.refreshWindowCallCount = 0
    }
}

@MainActor
private final class OnboardingWindowControllerSpy: OnboardingWindowControlling {
    private(set) var showWindowCallCount = 0
    private(set) var closeWindowCallCount = 0
    private(set) var refreshWindowCallCount = 0

    func showWindow() {
        self.showWindowCallCount += 1
    }

    func closeWindow() {
        self.closeWindowCallCount += 1
    }

    func refreshWindow() {
        self.refreshWindowCallCount += 1
    }

    func reset() {
        self.showWindowCallCount = 0
        self.closeWindowCallCount = 0
        self.refreshWindowCallCount = 0
    }
}

private enum KeepAwakeTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "simulated keep awake failure"
    }
}

private final class DesktopKeepAwakeControllerSpy: DesktopKeepAwakeControlling {
    private(set) var requestedStates: [Bool] = []
    var isEnabled = false
    var enableError: Error?
    var disableError: Error?

    func setEnabled(_ isEnabled: Bool) throws {
        self.requestedStates.append(isEnabled)

        if isEnabled, let enableError {
            throw enableError
        }

        if !isEnabled, let disableError {
            throw disableError
        }

        self.isEnabled = isEnabled
    }
}

@MainActor
private final class RemoteAdminWindowControllerSpy: RemoteAdminWindowControlling {
    let hostID: String
    private let onClose: @Sendable () -> Void

    private(set) var showWindowCallCount = 0
    private(set) var closeWindowCallCount = 0
    private(set) var refreshWindowCallCount = 0

    init(hostID: String, onClose: @escaping @Sendable () -> Void = {}) {
        self.hostID = hostID
        self.onClose = onClose
    }

    func showWindow() {
        self.showWindowCallCount += 1
    }

    func closeWindow() {
        self.closeWindowCallCount += 1
        self.onClose()
    }

    func refreshWindow(preferences: DesktopPreferences) {
        self.refreshWindowCallCount += 1
    }
}

private final class LockedRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func store(_ request: URLRequest) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.request = request
    }

    func snapshot() -> URLRequest? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.request
    }
}

private final class RemoteAdminLocalImportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedImportCalls: [[AuthJsonImportInput]] = []
    private var storedConfirmationContents: [RemoteAdminWindowModel.LocalAccountsImportConfirmationContent] = []
    private var storedLocalExportCallCount = 0
    private var storedAccounts: [AccountSummary] = []

    func recordImport(_ items: [AuthJsonImportInput]) {
        self.lock.withLock {
            self.storedImportCalls.append(items)
        }
    }

    func recordConfirmation(_ content: RemoteAdminWindowModel.LocalAccountsImportConfirmationContent) {
        self.lock.withLock {
            self.storedConfirmationContents.append(content)
        }
    }

    func recordLocalExport() {
        self.lock.withLock {
            self.storedLocalExportCallCount += 1
        }
    }

    func setAccounts(_ accounts: [AccountSummary]) {
        self.lock.withLock {
            self.storedAccounts = accounts
        }
    }

    func accounts() -> [AccountSummary] {
        self.lock.withLock {
            self.storedAccounts
        }
    }

    func importCalls() -> [[AuthJsonImportInput]] {
        self.lock.withLock {
            self.storedImportCalls
        }
    }

    func confirmationContents() -> [RemoteAdminWindowModel.LocalAccountsImportConfirmationContent] {
        self.lock.withLock {
            self.storedConfirmationContents
        }
    }

    func localExportCallCount() -> Int {
        self.lock.withLock {
            self.storedLocalExportCallCount
        }
    }
}

private final class RemoteAdminSSHStub: @unchecked Sendable, SSHControlling {
    struct TunnelCall: Equatable {
        var hostID: String
        var localPort: Int
        var remotePort: Int
        var controlPath: String
    }

    private let lock = NSLock()

    private(set) var runCalls: [String] = []
    private(set) var openTunnelCalls: [TunnelCall] = []
    private(set) var closeTunnelCalls: [TunnelCall] = []

    var runHandler: (@Sendable (RemoteHostConfig, String) async throws -> String)?
    var openTunnelHandler: (@Sendable (RemoteHostConfig, Int, Int, String) async throws -> Void)?

    func run(host: RemoteHostConfig, command: String) async throws -> String {
        self.lock.withLock {
            self.runCalls.append(command)
        }

        if let runHandler {
            return try await runHandler(host, command)
        }
        return ""
    }

    func upload(host: RemoteHostConfig, local: URL, remote: String) async throws {}

    func openTunnel(host: RemoteHostConfig, localPort: Int, remotePort: Int, controlPath: String) async throws {
        self.lock.withLock {
            self.openTunnelCalls.append(
                TunnelCall(hostID: host.id, localPort: localPort, remotePort: remotePort, controlPath: controlPath)
            )
        }

        if let openTunnelHandler {
            try await openTunnelHandler(host, localPort, remotePort, controlPath)
        }
    }

    func closeTunnel(host: RemoteHostConfig, controlPath: String) async {
        self.lock.withLock {
            self.closeTunnelCalls.append(
                TunnelCall(hostID: host.id, localPort: 0, remotePort: 0, controlPath: controlPath)
            )
        }
    }
}

private final class LockedRemoteAdminReconnectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String]
    private var nextTokenIndex = 0
    private var requestCount = 0
    private var authorizationHeaders: [String?] = []
    private var reconnectCount = 0

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func nextToken() -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.tokens.isEmpty else { return "" }
        let index = min(self.nextTokenIndex, self.tokens.count - 1)
        let token = self.tokens[index]
        self.nextTokenIndex += 1
        return token
    }

    func recordAuthorizationHeader(_ value: String?) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.requestCount += 1
        self.authorizationHeaders.append(value)
        return self.requestCount
    }

    func recordReconnect() {
        self.lock.lock()
        self.reconnectCount += 1
        self.lock.unlock()
    }

    func snapshot() -> (authorizationHeaders: [String?], reconnectCount: Int, requestCount: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.authorizationHeaders, self.reconnectCount, self.requestCount)
    }
}

private actor RemoteAdminTunnelStub: RemoteAdminTunneling {
    var state: RemoteAdminSessionState
    var token: String
    var managedProxyLogs = ""
    var ensureConnectedCallCount = 0
    var reconnectCallCount = 0
    var closeCallCount = 0
    var updateReachabilityCalls: [RemoteAdminReachabilityStatus] = []

    init(
        state: RemoteAdminSessionState,
        token: String = "remote-admin-token",
        managedProxyLogs: String = ""
    ) {
        self.state = state
        self.token = token
        self.managedProxyLogs = managedProxyLogs
    }

    func snapshot() async -> RemoteAdminSessionState {
        self.state
    }

    func ensureConnected() async throws -> RemoteAdminSessionState {
        self.ensureConnectedCallCount += 1
        return self.state
    }

    func reconnect() async throws -> RemoteAdminSessionState {
        self.reconnectCallCount += 1
        return self.state
    }

    func updateConfiguredAdminPort(_ port: Int) async {
        self.state.configuredAdminPort = port
    }

    func currentToken() async throws -> String {
        self.token
    }

    func updateReachability(_ status: RemoteAdminReachabilityStatus) async {
        self.updateReachabilityCalls.append(status)
        self.state.reachabilityStatus = status
    }

    func loadManagedProxyLogs(lines: Int) async throws -> String {
        _ = lines
        return self.managedProxyLogs
    }

    func close() async {
        self.closeCallCount += 1
    }
}

private actor ProxyTestRouteProbe {
    private var adminRuns = 0
    private var publicRuns = 0
    private var healthCalls: [String] = []
    private var lastAdminPayload: AdminProxyTestRunRequest?

    func recordAdminRun() {
        self.adminRuns += 1
    }

    func recordAdminRun(_ payload: AdminProxyTestRunRequest) {
        self.adminRuns += 1
        self.lastAdminPayload = payload
    }

    func recordPublicRun() {
        self.publicRuns += 1
    }

    func recordPublicRun(_ route: String) {
        _ = route
        self.publicRuns += 1
    }

    func recordHealthCall(_ baseURL: String) {
        self.healthCalls.append(baseURL)
    }

    func snapshot() -> (adminRuns: Int, publicRuns: Int, healthCalls: [String], lastAdminPayload: AdminProxyTestRunRequest?) {
        (self.adminRuns, self.publicRuns, self.healthCalls, self.lastAdminPayload)
    }
}

private final class RemoteDeployStub: @unchecked Sendable, RemoteDeploying {
    var deployCalls: [RemoteHostConfig] = []
    var statusCalls: [RemoteHostConfig] = []
    var startCalls: [RemoteHostConfig] = []
    var stopCalls: [RemoteHostConfig] = []
    var logsCalls: [(host: RemoteHostConfig, lines: Int)] = []
    var testConnectionCalls: [RemoteHostConfig] = []

    var deployHandler: (@Sendable (RemoteHostConfig, Data, AppConfig) async throws -> RemoteDeployStatus)?
    var statusHandler: (@Sendable (RemoteHostConfig) async throws -> RemoteDeployStatus)?
    var startHandler: (@Sendable (RemoteHostConfig) async throws -> RemoteDeployStatus)?
    var stopHandler: (@Sendable (RemoteHostConfig) async throws -> RemoteDeployStatus)?
    var logsHandler: (@Sendable (RemoteHostConfig, Int) async throws -> String)?
    var testConnectionHandler: (@Sendable (RemoteHostConfig) async throws -> RemoteConnectionCheck)?

    func deploy(
        host: RemoteHostConfig,
        exportedAccountsJSON: Data,
        config: AppConfig
    ) async throws -> RemoteDeployStatus {
        self.deployCalls.append(host)
        if let deployHandler {
            return try await deployHandler(host, exportedAccountsJSON, config)
        }
        return Self.defaultStatus(host: host)
    }

    func start(host: RemoteHostConfig) async throws -> RemoteDeployStatus {
        self.startCalls.append(host)
        if let startHandler {
            return try await startHandler(host)
        }
        var status = Self.defaultStatus(host: host)
        status.running = true
        return status
    }

    func stop(host: RemoteHostConfig) async throws -> RemoteDeployStatus {
        self.stopCalls.append(host)
        if let stopHandler {
            return try await stopHandler(host)
        }
        return Self.defaultStatus(host: host)
    }

    func logs(host: RemoteHostConfig, lines: Int) async throws -> String {
        self.logsCalls.append((host, lines))
        if let logsHandler {
            return try await logsHandler(host, lines)
        }
        return ""
    }

    func status(host: RemoteHostConfig) async throws -> RemoteDeployStatus {
        self.statusCalls.append(host)
        if let statusHandler {
            return try await statusHandler(host)
        }
        return Self.defaultStatus(host: host)
    }

    func testConnection(host: RemoteHostConfig) async throws -> RemoteConnectionCheck {
        self.testConnectionCalls.append(host)
        if let testConnectionHandler {
            return try await testConnectionHandler(host)
        }
        return Self.defaultConnectionCheck(hostID: host.id, architecture: "arm64")
    }

    private static func defaultStatus(host: RemoteHostConfig) -> RemoteDeployStatus {
        RemoteDeployStatus(
            hostID: host.id,
            installed: true,
            serviceInstalled: true,
            running: false,
            enabled: true,
            architecture: "arm64",
            baseURL: "http://\(host.host):\(host.publicPort)/v1",
            apiKey: nil,
            lastError: nil
        )
    }

    private static func defaultConnectionCheck(hostID: String, architecture: String) -> RemoteConnectionCheck {
        RemoteConnectionCheck(
            hostID: hostID,
            architecture: architecture,
            remoteUser: "root",
            remoteDirectoryWritable: true,
            systemctlAvailable: true,
            sudoAvailable: true,
            localArtifactAvailable: true
        )
    }
}

final class CodexProxyDesktopTests: XCTestCase {
    @MainActor
    func testDesktopMainWindowFindsTaggedMainWindow() {
        let first = NSWindow()
        let second = NSWindow()

        DesktopMainWindow.mark(second)

        XCTAssertTrue(DesktopMainWindow.mainWindow(from: [first, second]) === second)
    }

    func testSettingsTabOrderMatchesPlannedInformationArchitecture() {
        XCTAssertEqual(SettingsTab.allCases, [.appearance, .general, .proxy, .service])
        XCTAssertEqual(SettingsTab.appearance.rawValue, "appearance")
        XCTAssertEqual(SettingsTab.service.rawValue, "service")
    }

    func testOverviewTabSymbolsMatchUnifiedDashboardStrip() {
        XCTAssertEqual(OverviewTab.runtime.symbolName, "waveform.path.ecg")
        XCTAssertEqual(OverviewTab.traffic.symbolName, "chart.bar.xaxis")
        XCTAssertEqual(OverviewTab.recentActivity.symbolName, "clock.arrow.circlepath")
    }

    func testProxyWorkspaceTabSymbolsMatchUnifiedDashboardStrip() {
        XCTAssertEqual(ProxyWorkspaceTab.access.symbolName, "link.circle")
        XCTAssertEqual(ProxyWorkspaceTab.apiKeys.symbolName, "key.fill")
        XCTAssertEqual(ProxyWorkspaceTab.usage.symbolName, "chart.bar.xaxis")
        XCTAssertEqual(ProxyWorkspaceTab.advanced.symbolName, "slider.horizontal.3")
    }

    func testAppearanceStoreMapsThemeModesToNativeAppearances() {
        XCTAssertNil(AppearanceStore.nsAppearanceName(for: .system))
        XCTAssertEqual(AppearanceStore.nsAppearanceName(for: .light), .aqua)
        XCTAssertEqual(AppearanceStore.nsAppearanceName(for: .dark), .darkAqua)
    }

    @MainActor
    func testAppearanceStoreResolvesCurrentSystemColorScheme() {
        XCTAssertTrue([ColorScheme.light, ColorScheme.dark].contains(AppearanceStore.currentSystemColorScheme()))
        XCTAssertEqual(AppearanceStore.colorScheme(for: NSAppearance(named: .aqua)!), .light)
        XCTAssertEqual(AppearanceStore.colorScheme(for: NSAppearance(named: .darkAqua)!), .dark)
    }

    @MainActor
    func testAppearanceStoreClearsForcedAppearanceWhenFollowingSystem() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            AppearanceStore.applyAppAppearance(for: .system)
        }

        AppearanceStore.applyAppAppearance(for: .dark)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        XCTAssertEqual(window.appearance?.name, .darkAqua)

        AppearanceStore.applyAppAppearance(for: .system)
        XCTAssertNil(NSApplication.shared.appearance)
        XCTAssertNil(window.appearance)
    }

    @MainActor
    func testUpdateThemeResolvesFollowSystemToExplicitSwiftUIColorScheme() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(preferencesStore: preferencesStore)
        let currentSystemScheme = AppearanceStore.currentSystemColorScheme()

        model.updateTheme(.dark)
        XCTAssertEqual(model.resolvedPreferredColorScheme, .dark)

        model.updateTheme(.system)
        XCTAssertEqual(model.preferences.themeMode, .system)
        XCTAssertEqual(model.systemColorScheme, currentSystemScheme)
        XCTAssertEqual(model.resolvedPreferredColorScheme, currentSystemScheme)
    }

    @MainActor
    func testRefreshSystemColorSchemeSkipsPublishingWhenUnchanged() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(preferencesStore: preferencesStore)
        let initialSystemScheme = model.systemColorScheme

        XCTAssertFalse(model.refreshSystemColorScheme())
        XCTAssertEqual(model.systemColorScheme, initialSystemScheme)
    }

    func testRootShellViewUsesSharedMainWindowTitlebarControlsForBothInterfaceModes() throws {
        let appSource = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")
        let rootShellSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RootShellView.swift")

        XCTAssertTrue(appSource.contains("MainWindowTitlebarControls("))
        XCTAssertTrue(appSource.contains("MainWindowTitlebarControlsHostView"))
        XCTAssertFalse(appSource.contains("FullModeTitlebarControls("))
        XCTAssertFalse(rootShellSource.contains("interface-mode-toolbar-button"))
        XCTAssertFalse(rootShellSource.contains("ToolbarItemGroup(placement: .primaryAction)"))
        XCTAssertFalse(rootShellSource.contains(".toolbar {"))
        XCTAssertFalse(rootShellSource.contains("self.mainWindowTitlebarControls"))
        XCTAssertTrue(appSource.contains("modeEntryTitle: self.interfaceModeToolbarTitle"))
        XCTAssertTrue(appSource.contains("modeEntrySymbol: self.interfaceModeToolbarSymbol"))
        XCTAssertTrue(appSource.contains("modeEntryHelpText: self.interfaceModeToolbarHelpText"))
        XCTAssertTrue(appSource.contains("onModeEntry: { self.model.switchInterfaceMode(target: self.interfaceModeToolbarTarget) }"))
        XCTAssertTrue(appSource.contains("requestLogsTitle: self.model.text(.actionOpenRequestLogs)"))
        XCTAssertTrue(appSource.contains("requestLogsHelpText: self.model.text(.actionOpenRequestLogs)"))
        XCTAssertTrue(appSource.contains("onRequestLogs: { self.model.openRequestLogsWindow() }"))
    }

    func testMainWindowRequestLogsEntryIsCentralizedInTitlebar() throws {
        let overviewSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/OverviewView.swift")
        let proxySource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/ProxyView.swift")
        let sharedUISource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/SharedUI.swift")
        let appSource = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")
        let mainMenuSource = try Self.repoFileText("Sources/CodexProxyDesktop/DesktopMainMenuController.swift")

        XCTAssertFalse(overviewSource.contains("actionOpenRequestLogs"))
        XCTAssertFalse(overviewSource.contains("openRequestLogsWindow"))
        XCTAssertFalse(proxySource.contains("actionOpenRequestLogs"))
        XCTAssertFalse(proxySource.contains("openRequestLogsWindow"))

        XCTAssertTrue(sharedUISource.contains("\"titlebar-request-logs-button\""))
        XCTAssertTrue(sharedUISource.contains("\"list.bullet.rectangle\""))
        XCTAssertTrue(appSource.contains("requestLogsTitle: self.model.text(.actionOpenRequestLogs)"))
        XCTAssertTrue(appSource.contains("onRequestLogs: { self.model.openRequestLogsWindow() }"))

        XCTAssertTrue(appSource.contains("self.model.openRequestLogsFromMenu()"))
        XCTAssertTrue(mainMenuSource.contains("self.openRequestLogs = model.text(.actionOpenRequestLogs)"))
        XCTAssertTrue(mainMenuSource.contains("self.model?.openRequestLogsFromMenu()"))
    }

    func testManualAPIKeyFormIncludesAutomaticCooldownPolicyControls() throws {
        let formSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/ManualAPIKeyAccountForm.swift")
        let accountsSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/AccountsView.swift")

        XCTAssertTrue(formSource.contains("labelAutomaticCooldown"))
        XCTAssertTrue(formSource.contains("helperAutomaticCooldownPolicy"))
        XCTAssertTrue(formSource.contains("$draft.automaticCooldownDisabled"))
        XCTAssertTrue(accountsSource.contains("canUpdateAccountCooldownPolicy"))
        XCTAssertTrue(accountsSource.contains("accountCooldownPolicyActionTitle"))
    }

    func testRootShellViewMapsMinimalModeToolbarEntryToFullModeCopy() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")

        XCTAssertTrue(source.contains("self.model.isMinimalMode ? .full : .minimal"))
        XCTAssertTrue(source.contains("self.model.label(for: self.interfaceModeToolbarTarget)"))
        XCTAssertTrue(source.contains("\"rectangle.compress.vertical\""))
        XCTAssertTrue(source.contains("\"rectangle.expand.vertical\""))
        XCTAssertTrue(source.contains("self.model.switchToFullModeButtonTitle"))
        XCTAssertTrue(source.contains("self.model.switchToMinimalModeButtonTitle"))
    }

    func testRootShellViewProvidesCollapsibleMainSidebarControls() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RootShellView.swift")

        XCTAssertTrue(source.contains("@State private var isSidebarCollapsed = false"))
        XCTAssertTrue(source.contains("CollapsedSidebarRail("))
        XCTAssertTrue(source.contains("\"main-sidebar-collapse-button\""))
        XCTAssertTrue(source.contains("\"main-sidebar-expand-button\""))
        XCTAssertTrue(source.contains("\"main-sidebar-collapsed-page-\\(page.rawValue)\""))
        XCTAssertTrue(source.contains("self.model.localized(zh: \"收起主菜单\", en: \"Collapse Sidebar\")"))
        XCTAssertTrue(source.contains("self.model.localized(zh: \"展开主菜单\", en: \"Expand Sidebar\")"))
    }

    func testMinimalModeViewKeepsHeaderCopyButRemovesDuplicateHeaderControls() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/MinimalModeView.swift")

        XCTAssertTrue(source.contains("title: self.model.minimalModeTitle"))
        XCTAssertTrue(source.contains("subtitle: self.model.minimalModeSubtitle"))
        XCTAssertTrue(source.contains("showsControls: false"))
        XCTAssertFalse(source.contains("helpTitle: self.model.text(.actionOpenHelp)"))
        XCTAssertFalse(source.contains("onHelp: { self.model.openHelpWindow() }"))
    }

    func testMainWindowChromeAlwaysUsesTransparentUnifiedToolbar() throws {
        let behaviorSource = try Self.repoFileText("Sources/CodexProxyDesktop/WindowBehavior.swift")
        let appSource = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")
        let sharedUISource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/SharedUI.swift")

        XCTAssertFalse(behaviorSource.contains("showsTransparentToolbarBackground"))
        XCTAssertTrue(behaviorSource.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(behaviorSource.contains("window.toolbar?.showsBaselineSeparator = false"))
        XCTAssertTrue(behaviorSource.contains("window.toolbarStyle = .unifiedCompact"))
        XCTAssertTrue(behaviorSource.contains("window.styleMask.insert(.fullSizeContentView)"))
        XCTAssertFalse(appSource.contains("showsTransparentToolbarBackground:"))
        XCTAssertTrue(sharedUISource.contains("struct MainWindowTitlebarControls: View"))
        XCTAssertTrue(sharedUISource.contains(".accessibilityIdentifier(\"main-window-titlebar-controls\")"))
        XCTAssertTrue(sharedUISource.contains("accessibilityID: \"titlebar-help-button\""))
        XCTAssertTrue(sharedUISource.contains("accessibilityID: \"titlebar-refresh-button\""))
        XCTAssertTrue(sharedUISource.contains(".accessibilityIdentifier(\"titlebar-interface-mode-button\")"))
        XCTAssertTrue(sharedUISource.contains("static let controlHeight: CGFloat = 30"))
        XCTAssertTrue(sharedUISource.contains("static let labelFontSize: CGFloat = 11"))
        XCTAssertTrue(sharedUISource.contains("static let iconSize: CGFloat = 11"))
        XCTAssertTrue(sharedUISource.contains("static let containerHorizontalPadding: CGFloat = 6"))
        XCTAssertTrue(sharedUISource.contains(".fill(self.containerBackground(palette: palette))"))
        XCTAssertFalse(sharedUISource.contains(".accessibilityIdentifier(\"titlebar-minimal-mode-button\")"))
        XCTAssertTrue(appSource.contains("NSTitlebarAccessoryViewController"))
        XCTAssertTrue(appSource.contains("newAccessory.layoutAttribute = .right"))
        XCTAssertTrue(appSource.contains("window.addTitlebarAccessoryViewController(accessory)"))
    }

    func testMainWindowUsesDefaultAppKitSizeWithoutContentLockedResizability() throws {
        let appSource = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")

        XCTAssertTrue(appSource.contains("window.setContentSize(NSSize(width: 1320, height: 860))"))
        XCTAssertTrue(appSource.contains("window.minSize = NSSize(width: 1160, height: 760)"))
        XCTAssertFalse(appSource.contains(".windowResizability(.contentSize)"))
    }

    func testMainAndRemoteWorkspacesDoNotCapDetailContentAt1320() throws {
        let rootShellSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RootShellView.swift")
        let remoteAdminSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RemoteAdminWindowView.swift")

        XCTAssertFalse(rootShellSource.contains(".frame(maxWidth: 1320, alignment: .leading)"))
        XCTAssertFalse(remoteAdminSource.contains(".frame(maxWidth: 1320, alignment: .leading)"))
        XCTAssertTrue(rootShellSource.contains("\"main-workspace-detail-content\""))
        XCTAssertTrue(remoteAdminSource.contains("\"remote-admin-workspace-detail-content\""))
    }

    func testMinimalLayoutMetricsUsesCompactDensityForTypicalDesktopWindow() {
        let metrics = MinimalLayoutMetrics(width: 1440, height: 900, safeAreaTop: 24, safeAreaBottom: 0)

        XCTAssertTrue(metrics.isCompact)
        XCTAssertEqual(metrics.contentMaxWidth, 1180)
        XCTAssertEqual(metrics.outerHorizontalPadding, 12)
        XCTAssertEqual(metrics.outerTopPadding, 30)
        XCTAssertEqual(metrics.sectionSpacing, 10)
        XCTAssertEqual(metrics.columnSpacing, 10)
        XCTAssertEqual(metrics.primaryColumnMinimumWidth, 336)
        XCTAssertEqual(metrics.detailLabelWidth, 90)
        XCTAssertEqual(metrics.actionSpacing, 6)
        XCTAssertEqual(metrics.primaryCardLayoutMode, .threeColumns)
        XCTAssertEqual(metrics.statusBarLayoutMode, .singleLine)
        XCTAssertEqual(metrics.accountActionColumns, 2)
        XCTAssertEqual(metrics.accessValueLabelWidth, 90)
        XCTAssertEqual(metrics.accountListMaxHeight, 176)
        XCTAssertEqual(metrics.inlinePanelSpacing, 8)
        XCTAssertEqual(metrics.insetPanelPadding, 12)
        XCTAssertEqual(metrics.insetPanelCornerRadius, 14)
    }

    func testMinimalLayoutMetricsUsesCompactDensityForMinimumDesktopWindow() {
        let metrics = MinimalLayoutMetrics(width: 1160, height: 760, safeAreaTop: 24, safeAreaBottom: 0)

        XCTAssertTrue(metrics.isCompact)
        XCTAssertEqual(metrics.outerHorizontalPadding, 12)
        XCTAssertEqual(metrics.outerTopPadding, 30)
        XCTAssertEqual(metrics.sectionSpacing, 10)
        XCTAssertEqual(metrics.columnSpacing, 10)
        XCTAssertEqual(metrics.primaryCardLayoutMode, .twoPlusOne)
        XCTAssertEqual(metrics.statusBarLayoutMode, .stacked)
        XCTAssertEqual(metrics.accountActionColumns, 2)
        XCTAssertEqual(metrics.accountListMaxHeight, 176)
        XCTAssertEqual(metrics.insetPanelPadding, 12)
    }

    func testMinimalLayoutMetricsUsesTwoPlusOneLayoutForMediumWindow() {
        let metrics = MinimalLayoutMetrics(width: 1280, height: 800, safeAreaTop: 24, safeAreaBottom: 0)

        XCTAssertTrue(metrics.isCompact)
        XCTAssertEqual(metrics.primaryCardLayoutMode, .twoPlusOne)
        XCTAssertEqual(metrics.statusBarLayoutMode, .stacked)
        XCTAssertEqual(metrics.accountActionColumns, 2)
        XCTAssertEqual(metrics.accountListMaxHeight, 176)
        XCTAssertEqual(metrics.inlinePanelSpacing, 8)
    }

    func testMinimalLayoutMetricsUsesRegularDensityForLargeWindow() {
        let metrics = MinimalLayoutMetrics(width: 1720, height: 1080, safeAreaTop: 24, safeAreaBottom: 0)

        XCTAssertFalse(metrics.isCompact)
        XCTAssertEqual(metrics.contentMaxWidth, 1220)
        XCTAssertEqual(metrics.outerHorizontalPadding, 16)
        XCTAssertEqual(metrics.outerTopPadding, 32)
        XCTAssertEqual(metrics.sectionSpacing, 14)
        XCTAssertEqual(metrics.columnSpacing, 14)
        XCTAssertEqual(metrics.primaryColumnMinimumWidth, 360)
        XCTAssertEqual(metrics.detailLabelWidth, 118)
        XCTAssertEqual(metrics.actionSpacing, 8)
        XCTAssertEqual(metrics.primaryCardLayoutMode, .threeColumns)
        XCTAssertEqual(metrics.statusBarLayoutMode, .singleLine)
        XCTAssertEqual(metrics.accessValueLabelWidth, 100)
        XCTAssertEqual(metrics.accountListMaxHeight, 192)
        XCTAssertEqual(metrics.inlinePanelSpacing, 12)
        XCTAssertEqual(metrics.insetPanelPadding, 14)
        XCTAssertEqual(metrics.insetPanelCornerRadius, 16)
    }

    func testMinimalLayoutMetricsFallsBackToSingleColumnForNarrowWindow() {
        let metrics = MinimalLayoutMetrics(width: 980, height: 760, safeAreaTop: 24, safeAreaBottom: 0)

        XCTAssertTrue(metrics.isCompact)
        XCTAssertEqual(metrics.primaryCardLayoutMode, .singleColumn)
        XCTAssertEqual(metrics.statusBarLayoutMode, .stacked)
    }

    @MainActor
    func testMinimalAccountUsageSummaryShowsTodayTotalForTokenTrackedAccounts() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let account = Self.makeAccount(
            id: "api-account",
            label: "API Account",
            accountID: "acct-api",
            authMode: .openAIAPIKey,
            todayTokenUsage: AccountTodayTokenUsage(inputTokens: 1_200, outputTokens: 3_400)
        )

        XCTAssertEqual(model.minimalAccountUsageSummary(account), "Today 4.6k")
    }

    @MainActor
    func testMinimalAccountUsageSummaryShowsWindowPercentagesForQuotaAccounts() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let account = Self.makeAccount(
            id: "chatgpt-account",
            label: "ChatGPT",
            accountID: "acct-chatgpt",
            usage: UsageSnapshot(
                planType: "free",
                fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 70, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            )
        )

        XCTAssertEqual(model.minimalAccountUsageSummary(account), "5H 75% / 1W 30%")
    }

    @MainActor
    func testMinimalAccountUsageSummaryFallsBackToNoDataWhenUsageUnavailable() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let account = Self.makeAccount(
            id: "no-usage-account",
            label: "No Usage",
            accountID: "acct-no-usage",
            usage: nil,
            usageWindowsVisible: false
        )

        XCTAssertEqual(model.minimalAccountUsageSummary(account), model.text(.statusNoData))
    }

    @MainActor
    func testMinimalAccountStatusPresentationMapsDisabledWarningAndRunningStates() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let disabledAccount = Self.makeAccount(
            id: "disabled-account",
            label: "Disabled",
            accountID: "acct-disabled",
            enabled: false
        )
        let coolingAccount = Self.makeAccount(
            id: "cooling-account",
            label: "Cooling",
            accountID: "acct-cooling",
            cooldownUntil: Helpers.now() + 300
        )
        let runningAccount = Self.makeAccount(
            id: "running-account",
            label: "Running",
            accountID: "acct-running"
        )

        let disabledPresentation = model.minimalAccountStatusPresentation(disabledAccount)
        XCTAssertEqual(disabledPresentation.text, model.text(.statusDisabled))
        XCTAssertEqual(disabledPresentation.tone, .danger)

        let warningPresentation = model.minimalAccountStatusPresentation(coolingAccount)
        XCTAssertEqual(warningPresentation.text, model.text(.statusCoolingDown))
        XCTAssertEqual(warningPresentation.tone, .warning)

        let runningPresentation = model.minimalAccountStatusPresentation(runningAccount)
        XCTAssertEqual(runningPresentation.text, model.text(.statusRunning))
        XCTAssertEqual(runningPresentation.tone, .success)
    }

    func testSidebarPageRowStyleUsesBrandHighlightForDarkSelection() {
        let style = SidebarPageRowStyle.resolve(colorScheme: .dark, isSelected: true, isHovered: false)

        XCTAssertEqual(style.rowFillTop, SidebarPageRowStyleLayer(.accentSoft, opacity: 0.98))
        XCTAssertEqual(style.rowFillBottom, SidebarPageRowStyleLayer(.panel, opacity: 0.98))
        XCTAssertEqual(style.rowBorder, SidebarPageRowStyleLayer(.accent, opacity: 0.42))
        XCTAssertEqual(style.iconFillTop, SidebarPageRowStyleLayer(.accent))
        XCTAssertEqual(style.iconForeground, SidebarPageRowStyleLayer(.white, opacity: 0.98))
        XCTAssertEqual(style.subtitleForeground, SidebarPageRowStyleLayer(.accent, opacity: 0.92))
        XCTAssertEqual(style.indicatorWidth, 0)
        XCTAssertEqual(style.indicatorLeadingInset, 0)
        XCTAssertEqual(style.indicatorVerticalInset, 0)
        XCTAssertEqual(style.indicatorTrailingGap, 0)
        XCTAssertEqual(style.shadow, SidebarPageRowStyleLayer(.accentGlow, opacity: 0.20))
    }

    func testSidebarPageRowStyleKeepsLightSelectionSofterThanDarkSelection() {
        let darkStyle = SidebarPageRowStyle.resolve(colorScheme: .dark, isSelected: true, isHovered: false)
        let lightStyle = SidebarPageRowStyle.resolve(colorScheme: .light, isSelected: true, isHovered: false)

        XCTAssertEqual(lightStyle.rowFillTop, SidebarPageRowStyleLayer(.accentSoft))
        XCTAssertEqual(lightStyle.rowFillBottom, SidebarPageRowStyleLayer(.panel))
        XCTAssertEqual(lightStyle.rowBorder, SidebarPageRowStyleLayer(.accent, opacity: 0.16))
        XCTAssertEqual(lightStyle.indicatorWidth, 0)
        XCTAssertEqual(lightStyle.indicatorLeadingInset, 0)
        XCTAssertEqual(lightStyle.indicatorVerticalInset, 0)
        XCTAssertEqual(lightStyle.indicatorTrailingGap, 0)
        XCTAssertEqual(lightStyle.shadow, SidebarPageRowStyleLayer(.accentGlow, opacity: 0.10))
        XCTAssertLessThan(lightStyle.rowBorder.opacity, darkStyle.rowBorder.opacity)
        XCTAssertLessThan(lightStyle.shadow.opacity, darkStyle.shadow.opacity)
    }

    func testSidebarPageRowStyleKeepsHoverDistinctFromSelection() {
        let hoverStyle = SidebarPageRowStyle.resolve(colorScheme: .dark, isSelected: false, isHovered: true)
        let selectedStyle = SidebarPageRowStyle.resolve(colorScheme: .dark, isSelected: true, isHovered: false)

        XCTAssertEqual(hoverStyle.rowFillTop, SidebarPageRowStyleLayer(.panelRaised, opacity: 0.82))
        XCTAssertEqual(hoverStyle.rowFillBottom, SidebarPageRowStyleLayer(.panel, opacity: 0.92))
        XCTAssertEqual(hoverStyle.rowBorder, SidebarPageRowStyleLayer(.border, opacity: 0.88))
        XCTAssertEqual(hoverStyle.subtitleForeground, SidebarPageRowStyleLayer(.textMuted))
        XCTAssertEqual(hoverStyle.indicatorWidth, 0)
        XCTAssertEqual(hoverStyle.indicatorLeadingInset, 0)
        XCTAssertEqual(hoverStyle.indicatorVerticalInset, 0)
        XCTAssertEqual(hoverStyle.indicatorTrailingGap, 0)
        XCTAssertEqual(hoverStyle.shadow, .clear)
        XCTAssertNotEqual(hoverStyle.rowBorder, selectedStyle.rowBorder)
        XCTAssertNotEqual(hoverStyle.iconFillTop, selectedStyle.iconFillTop)
    }

    func testLocalDaemonLastErrorSummaryIgnoresStructuredInfoStartupLog() {
        let stderr = """
        2026-04-14T17:14:49+0800 info CodexProxyDaemon/1.0.0: [HummingbirdCore] Server started and listening on 127.0.0.1:8788
        """

        XCTAssertNil(LocalDaemonController.lastErrorSummary(fromStderr: stderr))
    }

    func testLocalDaemonLastErrorSummaryReturnsLatestStructuredError() {
        let stderr = """
        2026-04-14T17:14:49+0800 info CodexProxyDaemon/1.0.0: [HummingbirdCore] Server started and listening on 127.0.0.1:8788
        2026-04-14T17:15:03+0800 warning CodexProxyDaemon/1.0.0: [CodexProxyDaemon] Health check is retrying
        2026-04-14T17:15:07+0800 error CodexProxyDaemon/1.0.0: [CodexProxyDaemon] Failed to bind admin listener
        """

        XCTAssertEqual(
            LocalDaemonController.lastErrorSummary(fromStderr: stderr),
            "2026-04-14T17:15:07+0800 error CodexProxyDaemon/1.0.0: [CodexProxyDaemon] Failed to bind admin listener"
        )
    }

    func testLocalDaemonLastErrorSummaryIgnoresStructuredWarning() {
        let stderr = """
        2026-04-14T17:15:03+0800 warning CodexProxyDaemon/1.0.0: [CodexProxyDaemon] Health check is retrying
        """

        XCTAssertNil(LocalDaemonController.lastErrorSummary(fromStderr: stderr))
    }

    func testLocalDaemonLastErrorSummaryKeepsUnstructuredFatalError() {
        let stderr = """
        Fatal error: Unexpectedly found nil while unwrapping an Optional value
        """

        XCTAssertEqual(
            LocalDaemonController.lastErrorSummary(fromStderr: stderr),
            "Fatal error: Unexpectedly found nil while unwrapping an Optional value"
        )
    }

    func testLocalDaemonLastErrorSummaryFallsBackToLaunchctlWhenStderrHasNoError() {
        let stderr = """
        2026-04-14T17:14:49+0800 info CodexProxyDaemon/1.0.0: [HummingbirdCore] Server started and listening on 127.0.0.1:8788
        """
        let launchctlOutput = """
        system service = io.shiguanghuxian.codex-proxy
        state = exited
        last exit code = 78
        """

        XCTAssertEqual(
            LocalDaemonController.lastErrorSummary(launchctlOutput: launchctlOutput, stderr: stderr),
            "last exit code = 78"
        )
    }

    func testLocalDaemonLaunchctlErrorSummaryIgnoresRunningMetadataPaths() {
        let launchctlOutput = """
        gui/501/io.shiguanghuxian.codex-proxy = {
            path = /Users/zuoxiupeng/Library/LaunchAgents/io.shiguanghuxian.codex-proxy.plist
            state = running
            stdout path = /Users/zuoxiupeng/Library/Application Support/CodexProxy/daemon.out.log
            stderr path = /Users/zuoxiupeng/Library/Application Support/CodexProxy/daemon.err.log
            last terminating signal = Terminated: 15
        }
        """

        XCTAssertNil(LocalDaemonController.launchctlErrorSummary(from: launchctlOutput))
    }

    func testLocalDaemonStartupHealthTimeoutResolutionRetriesWhenServiceIsRunning() {
        let status = LocalServiceStatus(
            installed: true,
            running: true,
            launchctlState: "running",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )

        XCTAssertEqual(
            LocalDaemonController.startupHealthTimeoutResolution(for: status),
            .retryGracePeriod
        )
    }

    func testLocalDaemonStartupHealthTimeoutResolutionFailsWithDiagnosticWhenStopped() {
        let status = LocalServiceStatus(
            installed: true,
            running: false,
            launchctlState: "exited",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: "last exit code = 78"
        )

        XCTAssertEqual(
            LocalDaemonController.startupHealthTimeoutResolution(for: status),
            .fail("last exit code = 78")
        )
    }

    func testLocalDaemonStartupFailureMessageAfterGraceTimeoutUsesRunningTimeoutMessage() {
        let status = LocalServiceStatus(
            installed: true,
            running: true,
            launchctlState: "running",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )

        XCTAssertEqual(
            LocalDaemonController.startupFailureMessage(afterGraceTimeout: status),
            "Daemon process is running, but the health endpoint did not become ready in time."
        )
    }

    func testLocalDaemonStartupFailureMessageAfterGraceTimeoutUsesDiagnosticWhenStopped() {
        let status = LocalServiceStatus(
            installed: true,
            running: false,
            launchctlState: "exited",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: "Fatal error: Unexpectedly found nil while unwrapping an Optional value"
        )

        XCTAssertEqual(
            LocalDaemonController.startupFailureMessage(afterGraceTimeout: status),
            "Fatal error: Unexpectedly found nil while unwrapping an Optional value"
        )
    }

    @MainActor
    func testConfiguredProxyAPIKeysKeepsPrimaryFirst() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "secondary", label: "Secondary", key: "sk-secondary", enabled: true, createdAt: 2),
            ProxyAPIKeyRecord(id: "primary", label: "Primary", key: "sk-primary", enabled: true, createdAt: 1),
        ]
        model.settings.primaryProxyAPIKeyID = "primary"

        let ordered = model.configuredProxyAPIKeys

        XCTAssertEqual(ordered.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(model.localProxyAPIKeyValue, "sk-primary")
    }

    @MainActor
    func testAnthropicAccessProxyAPIKeyPrefersDedicatedUnrestrictedKey() {
        let model = DesktopAppModel()
        model.settings.publicHost = "proxy.internal"
        model.settings.publicPort = 9393
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "primary", label: "Primary", key: "sk-primary", dataSource: .openAI, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "all", label: "All", key: "sk-all", dataSource: .all, enabled: true, createdAt: 2),
            ProxyAPIKeyRecord(id: "anthropic", label: "Anthropic Access", key: "sk-anthropic", dataSource: .anthropic, enabled: true, createdAt: 3),
        ]
        model.settings.primaryProxyAPIKeyID = "primary"

        XCTAssertEqual(model.anthropicAccessProxyAPIKeyValue, "sk-anthropic")
        XCTAssertEqual(model.anthropicAccessProxyAPIKeyDisplayValue, "sk-anthropic")
        XCTAssertEqual(
            model.claudeCodeEnvironmentSnippet,
            """
            export ANTHROPIC_BASE_URL=http://proxy.internal:9393
            export ANTHROPIC_AUTH_TOKEN=sk-anthropic
            """
        )
    }

    @MainActor
    func testAnthropicAPICompatibleManualAccountClientAccessPresentationUsesCompatibleKey() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "restricted-anthropic",
                label: "Restricted Anthropic",
                key: "sk-restricted",
                dataSource: .anthropic,
                allowedAccountKeys: ["other-account"],
                enabled: true,
                createdAt: 1
            ),
            ProxyAPIKeyRecord(
                id: "anthropic-access",
                label: "Anthropic Access",
                key: "sk-anthropic",
                dataSource: .anthropic,
                enabled: true,
                createdAt: 2
            ),
        ]
        let account = Self.makeAccount(
            id: "anthropic-manual",
            label: "Anthropic Manual",
            accountID: "acct-anthropic-manual",
            accountKey: "anthropic-manual-key",
            authMode: .anthropicAPIKey,
            providerPreset: .anthropicAPICompatible,
            upstreamBaseURL: "https://example.com/v1"
        )

        let presentation = try XCTUnwrap(model.anthropicAPICompatibleClientAccessPresentation(for: account))

        XCTAssertTrue(model.isAnthropicAPICompatibleManualAccount(account))
        XCTAssertEqual(presentation.statusText, "Ready")
        XCTAssertEqual(presentation.apiKeyText, "Anthropic Access")
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertTrue(presentation.detail.contains("Claude Code"))
        XCTAssertTrue(presentation.detail.contains("Codex"))
        XCTAssertTrue(presentation.detail.contains("Anthropic Access"))
    }

    @MainActor
    func testAnthropicAPICompatibleManualAccountClientAccessPresentationReportsAllowlistRestriction() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "restricted-anthropic",
                label: "Restricted Anthropic",
                key: "sk-restricted",
                dataSource: .anthropic,
                allowedAccountKeys: ["other-account"],
                enabled: true,
                createdAt: 1
            ),
        ]
        let account = Self.makeAccount(
            id: "anthropic-restricted",
            label: "Anthropic Restricted",
            accountID: "acct-anthropic-restricted",
            accountKey: "anthropic-restricted-key",
            authMode: .anthropicAPIKey,
            providerPreset: .anthropicAPICompatible,
            upstreamBaseURL: "https://example.com/v1"
        )

        let presentation = try XCTUnwrap(model.anthropicAPICompatibleClientAccessPresentation(for: account))

        XCTAssertEqual(presentation.statusText, "Allowlist Restricted")
        XCTAssertEqual(presentation.apiKeyText, "Allowlist Restricted")
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertTrue(presentation.detail.contains("Claude Code"))
        XCTAssertTrue(presentation.detail.contains("Codex"))
        XCTAssertTrue(presentation.detail.contains("allowlist") || presentation.detail.contains("allow"))
    }

    @MainActor
    func testAnthropicAPICompatibleManualAccountClientAccessPresentationReportsMissingKey() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "openai-only",
                label: "OpenAI Only",
                key: "sk-openai",
                dataSource: .openAI,
                enabled: true,
                createdAt: 1
            ),
        ]
        let account = Self.makeAccount(
            id: "anthropic-missing",
            label: "Anthropic Missing",
            accountID: "acct-anthropic-missing",
            accountKey: "anthropic-missing-key",
            authMode: .anthropicAPIKey,
            providerPreset: .anthropicAPICompatible,
            upstreamBaseURL: "https://example.com/v1"
        )

        let presentation = try XCTUnwrap(model.anthropicAPICompatibleClientAccessPresentation(for: account))

        XCTAssertEqual(presentation.statusText, model.text(.statusUnavailable))
        XCTAssertEqual(presentation.apiKeyText, model.text(.statusUnavailable))
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertTrue(presentation.detail.contains("Claude Code"))
        XCTAssertTrue(presentation.detail.contains("Codex"))
        XCTAssertTrue(presentation.detail.contains(".anthropic"))
    }

    func testProxyAPIKeyUsageFilterUsesNaturalRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        let now = Date(timeIntervalSince1970: 1_776_137_245) // 2026-04-14 10:20:45 +0800

        let today = ProxyAPIKeyUsageFilter(preset: .today).timeRange(now: now, calendar: calendar)
        let week = ProxyAPIKeyUsageFilter(preset: .week).timeRange(now: now, calendar: calendar)
        let month = ProxyAPIKeyUsageFilter(preset: .month).timeRange(now: now, calendar: calendar)

        XCTAssertEqual(Int(today.from.timeIntervalSince1970), 1_776_096_000)
        XCTAssertEqual(Int(week.from.timeIntervalSince1970), 1_775_923_200)
        XCTAssertEqual(Int(month.from.timeIntervalSince1970), 1_774_972_800)
        XCTAssertEqual(Int(today.to.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        XCTAssertEqual(Int(week.to.timeIntervalSince1970), Int(now.timeIntervalSince1970))
        XCTAssertEqual(Int(month.to.timeIntervalSince1970), Int(now.timeIntervalSince1970))
    }

    func testOverviewNumberFormatAbbreviatesLargeValues() {
        XCTAssertEqual(OverviewNumberFormat.abbreviated(999), "999")
        XCTAssertEqual(OverviewNumberFormat.abbreviated(1_200), "1.2k")
        XCTAssertEqual(OverviewNumberFormat.abbreviated(15_600_000), "15.6m")
        XCTAssertEqual(OverviewNumberFormat.abbreviated(1_000_000_000), "1b")
    }

    @MainActor
    func testMenuBarTokenUsagePresentationUsesTodayStatsAndCurrentLanguage() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.stats = AdminStatsSummary(
            totalRequests: 0,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            naturalTokenUsage: .init(
                today: .init(requestCount: 0, inputTokens: 1_200, outputTokens: 3_456)
            ),
            latestBuckets: []
        )

        let englishPresentation = model.menuBarTokenUsagePresentation
        XCTAssertEqual(englishPresentation?.primaryLine, "In 1.2k")
        XCTAssertEqual(englishPresentation?.secondaryLine, "Out 3.5k")
        XCTAssertEqual(englishPresentation?.toolTip, "AI Coding Proxy\nInput Tokens 1,200\nOutput Tokens 3,456")
        XCTAssertEqual(
            englishPresentation?.accessibilityLabel,
            "AI Coding Proxy, input tokens 1,200, output tokens 3,456"
        )

        model.preferences.languageMode = .zhHans

        let chinesePresentation = model.menuBarTokenUsagePresentation
        XCTAssertEqual(chinesePresentation?.primaryLine, "入 1.2k")
        XCTAssertEqual(chinesePresentation?.secondaryLine, "出 3.5k")
        XCTAssertEqual(chinesePresentation?.toolTip, "AI Coding Proxy\n输入 Token 1,200\n输出 Token 3,456")
        XCTAssertEqual(chinesePresentation?.accessibilityLabel, "AI Coding Proxy，输入 Token 1,200，输出 Token 3,456")
    }

    @MainActor
    func testMenuBarTokenUsagePresentationFallsBackToIconOnlyWhenDisabled() {
        let model = DesktopAppModel()
        model.preferences.showsMenuBarTokenUsage = false
        model.stats = AdminStatsSummary(
            totalRequests: 0,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            naturalTokenUsage: .init(
                today: .init(requestCount: 0, inputTokens: 9_999, outputTokens: 8_888)
            ),
            latestBuckets: []
        )

        XCTAssertNil(model.menuBarTokenUsagePresentation)
        XCTAssertEqual(model.menuBarStatusItemToolTip, model.text(.brandName))
        XCTAssertEqual(model.menuBarStatusItemAccessibilityLabel, model.text(.brandName))
    }

    @MainActor
    func testOverviewTooltipTokenFormattingUsesAbbreviatedValuesAndPreservesNoData() {
        let model = DesktopAppModel()

        XCTAssertEqual(model.overviewTooltipTokenText(1_200), "1.2k")
        XCTAssertEqual(model.overviewTooltipTokenText(15_600_000), "15.6m")
        XCTAssertEqual(model.overviewTooltipTokenText(1_000_000_000), "1b")
        XCTAssertEqual(model.overviewTooltipTokenText(nil), model.text(.statusNoData))
    }

    @MainActor
    func testOverviewTooltipRequestCountFormattingUsesFullValues() {
        let model = DesktopAppModel()

        XCTAssertEqual(model.overviewTooltipRequestCountText(1_200), "1,200")
        XCTAssertEqual(model.overviewTooltipRequestCountText(1_000_000_000), "1,000,000,000")
        XCTAssertEqual(model.overviewTooltipRequestCountText(nil), model.text(.statusNoData))
    }

    @MainActor
    func testProxySummaryTokenFormattingMatchesOverviewStyle() {
        let model = DesktopAppModel()

        XCTAssertEqual(model.proxySummaryTokenText(0), "0")
        XCTAssertEqual(model.proxySummaryTokenHelp(0), "0")
        XCTAssertEqual(model.proxySummaryTokenText(999), "999")
        XCTAssertEqual(model.proxySummaryTokenText(1_200), "1.2k")
        XCTAssertEqual(model.proxySummaryTokenText(15_600_000), "15.6m")
        XCTAssertEqual(model.proxySummaryTokenText(1_000_000_000), "1b")
        XCTAssertEqual(model.proxySummaryTokenHelp(1_000_000_000), "1,000,000,000")
    }

    @MainActor
    func testProxySummaryTokenFormattingPreservesNoDataStateForOptionalValues() {
        let model = DesktopAppModel()
        let missingValue: Int64? = nil

        XCTAssertEqual(model.proxySummaryTokenText(missingValue), model.text(.statusNoData))
        XCTAssertNil(model.proxySummaryTokenHelp(missingValue))
    }

    @MainActor
    func testOverviewTabDefaultsToRuntimeAndUsesExistingLocalizedTitles() {
        let model = DesktopAppModel()

        XCTAssertEqual(model.selectedOverviewTab, .runtime)
        XCTAssertEqual(model.overviewTabTitle(.runtime), model.text(.sectionRuntime))
        XCTAssertEqual(model.overviewTabTitle(.traffic), model.text(.sectionTraffic))
        XCTAssertEqual(model.overviewTabTitle(.recentActivity), model.text(.sectionLatestActivity))
    }

    func testOverviewTopUtilitiesExposeLocalClientConfigurationEntry() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/OverviewView.swift")

        XCTAssertTrue(source.contains("self.clientConfigButton"))
        XCTAssertTrue(source.contains("self.model.actionOpenClientConfigManager"))
        XCTAssertTrue(source.contains("self.model.openClientConfigManagerWindow()"))
    }

    @MainActor
    func testSetOutboundProxyModePromotesDisabledManualSchemeToHTTP() {
        let model = DesktopAppModel()
        model.settings.outboundProxyMode = .disabled
        model.settings.outboundProxy = .init()
        model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)

        model.setOutboundProxyMode(.manual)

        XCTAssertEqual(model.settings.outboundProxyMode, .disabled)
        XCTAssertEqual(model.settingsOutboundProxyDraft.mode, .manual)
        XCTAssertEqual(model.settingsOutboundProxyDraft.outboundProxy.scheme, .http)
    }

    @MainActor
    func testSettingsOutboundProxyManualModeRequiresSavedManualSettingsBeforeConfirming() {
        let model = DesktopAppModel()
        model.settings.outboundProxyMode = .disabled
        model.settings.outboundProxy = .init()
        model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)

        model.setSettingsOutboundProxyDraftMode(.manual)
        model.settingsOutboundProxyDraft.outboundProxy.host = "127.0.0.1"
        model.settingsOutboundProxyDraft.outboundProxy.port = 7890

        XCTAssertTrue(model.settingsOutboundProxyModeNeedsConfirmation)
        XCTAssertTrue(model.settingsOutboundProxyManualNeedsSave)
        XCTAssertFalse(model.settingsOutboundProxyCanConfirmModeChange)
        XCTAssertEqual(
            model.settingsOutboundProxyModeConfirmationRequirementText,
            model.text(.helperConfirmProxyModeChangeNeedsManualSave)
        )
    }

    @MainActor
    func testSettingsOutboundProxyManualModeCanConfirmWithExistingSavedManualSettings() {
        let model = DesktopAppModel()
        model.settings.outboundProxyMode = .disabled
        model.settings.outboundProxy = OutboundProxySettings(
            scheme: .http,
            host: "127.0.0.1",
            port: 7890,
            username: "",
            password: ""
        )
        model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)

        model.setSettingsOutboundProxyDraftMode(.manual)

        XCTAssertTrue(model.settingsOutboundProxyModeNeedsConfirmation)
        XCTAssertFalse(model.settingsOutboundProxyManualNeedsSave)
        XCTAssertTrue(model.settingsOutboundProxyCanConfirmModeChange)
    }

    @MainActor
    func testManagedProxySummaryExplainsStoppedDaemonForSubscriptionMode() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .stopped
        )
        model.status = nil

        XCTAssertTrue(model.managedProxySummaryText.contains("本地服务未运行"))
    }

    @MainActor
    func testManagedProxySummaryPointsToManagerWindowWhenSubscriptionIsMissing() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: false,
            runtimeState: .stopped
        )

        XCTAssertTrue(model.managedProxySummaryText.contains(model.managedProxyManagerWindowTitle))
    }

    @MainActor
    func testManagedProxySummaryRecommendsPinningWhenCurrentNodeExistsWithoutPinnedNode() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans
        model.settings.outboundProxyMode = .subscription
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 88),
            ]
        )

        XCTAssertTrue(model.managedProxySummaryText.contains("还未设置固定默认节点"))
    }

    @MainActor
    func testManagedProxyManagerSummaryExplainsTemporaryCurrentNodeWhenPinnedDefaultDiffers() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans
        model.settings.outboundProxyMode = .subscription
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Seoul",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 88),
                ManagedProxyNode(name: "Seoul", type: "vmess", isPinned: true, alive: true, lastDelayMS: 92),
            ]
        )

        XCTAssertTrue(model.managedProxyManagerSummaryText.contains("临时切换"))
        XCTAssertTrue(model.managedProxyManagerSummaryText.contains("Tokyo"))
        XCTAssertTrue(model.managedProxyManagerSummaryText.contains("Seoul"))
    }

    @MainActor
    func testManagedProxyManagerSummaryExplainsManagementOutsideSubscriptionMode() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans
        model.settings.outboundProxyMode = .manual
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .manual,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 88),
            ]
        )

        XCTAssertTrue(model.managedProxyManagerSummaryText.contains("当前全局未启用订阅代理"))
    }

    @MainActor
    func testManagedProxyNodePrimaryActionAllowsPinningCurrentNodeWithoutExistingPin() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running
        )
        let currentNode = ManagedProxyNode(
            name: "Seoul",
            type: "ss",
            isCurrent: true,
            isPinned: false,
            alive: true,
            lastDelayMS: 72
        )
        let pinnedCurrentNode = ManagedProxyNode(
            name: "Tokyo",
            type: "vmess",
            isCurrent: true,
            isPinned: true,
            alive: true,
            lastDelayMS: 92
        )

        XCTAssertEqual(model.managedProxyNodePrimaryActionTitle(currentNode), "Pin Current")
        XCTAssertTrue(model.managedProxyCanApplyNode(currentNode))
        XCTAssertEqual(model.managedProxyNodePrimaryActionTitle(pinnedCurrentNode), "Pinned")
        XCTAssertFalse(model.managedProxyCanApplyNode(pinnedCurrentNode))
    }

    @MainActor
    func testManagedProxyNodeIndependentActionTitlesReflectCurrentAndPinnedState() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running
        )
        let currentNode = ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true)
        let pinnedNode = ManagedProxyNode(name: "Seoul", type: "vmess", isPinned: true, alive: true)
        let pinnedCurrentNode = ManagedProxyNode(name: "Osaka", type: "trojan", isCurrent: true, isPinned: true, alive: true)

        XCTAssertEqual(model.managedProxyNodeSwitchCurrentTitle(currentNode), "Current")
        XCTAssertFalse(model.managedProxyCanSwitchCurrentNode(currentNode))
        XCTAssertEqual(model.managedProxyNodePinnedActionTitle(currentNode), "Set Pinned Default")
        XCTAssertTrue(model.managedProxyCanUpdatePinnedNode(currentNode))

        XCTAssertEqual(model.managedProxyNodeSwitchCurrentTitle(pinnedNode), "Use Current")
        XCTAssertTrue(model.managedProxyCanSwitchCurrentNode(pinnedNode))
        XCTAssertEqual(model.managedProxyNodePinnedActionTitle(pinnedNode), "Clear Pinned Default")
        XCTAssertTrue(model.managedProxyCanUpdatePinnedNode(pinnedNode))

        XCTAssertEqual(model.managedProxyNodePinnedActionTitle(pinnedCurrentNode), "Clear Pinned Default")
        XCTAssertFalse(model.managedProxyCanSwitchCurrentNode(pinnedCurrentNode))
    }

    @MainActor
    func testManagedProxyNodesDrawerDefaultsClosedAndFocusesCurrentNodeWhenPresented() {
        let model = DesktopAppModel()
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Seoul",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", isPinned: true, alive: true, lastDelayMS: 84),
            ]
        )

        XCTAssertFalse(model.isManagedProxyNodesDrawerPresented)
        XCTAssertNil(model.managedProxyFocusedNodeName)

        model.presentManagedProxyNodesDrawer()

        XCTAssertTrue(model.isManagedProxyNodesDrawerPresented)
        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
    }

    @MainActor
    func testManagedProxyFocusFallsBackToFirstVisibleNodeWhenSearchHidesFocusedNode() {
        let model = DesktopAppModel()
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
                ManagedProxyNode(name: "Osaka", type: "trojan", alive: true),
            ]
        )

        model.presentManagedProxyNodesDrawer()
        model.focusManagedProxyNode("Seoul")
        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Seoul")

        model.managedProxyNodeSearchQuery = "osa"
        model.syncManagedProxyFocus()

        XCTAssertEqual(model.visibleManagedProxyNodes.map(\.name), ["Osaka"])
        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Osaka")
    }

    @MainActor
    func testManagedProxyHealthcheckKeepsFocusedNodeAndUpdatesLatencyText() async {
        let updatedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84, lastHealthcheckAt: 1_710_000_200),
            ]
        )
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Seoul")
                return updatedSnapshot
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )

        model.focusManagedProxyNode("Seoul")
        await model.healthcheckManagedProxy(nodeName: "Seoul")

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Seoul")
        XCTAssertEqual(model.managedProxyFocusedNode?.lastDelayMS, 84)
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "84 ms")
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Node Seoul · 84 ms")
    }

    @MainActor
    func testManagedProxyCurrentNodeHealthcheckUsesActiveNodeInsteadOfFocusedNode() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 68,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        model.focusManagedProxyNode("Seoul")

        await model.healthcheckCurrentManagedProxyNode()

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyFocusedNode?.lastDelayMS, 68)
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · 68 ms")
    }

    @MainActor
    func testManagedProxyCurrentNodeHealthcheckSuccessReplacesStaleFailureState() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 948,
                            lastHealthcheckStatus: .success,
                            lastHealthcheckAt: 1_710_000_500
                        ),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
            ]
        )
        model.managedProxyNodeHealthcheckDisplayStates["Tokyo"] = ManagedProxyNodeHealthcheckDisplayState(
            status: .failed,
            checkedAt: Date(timeIntervalSince1970: 1_710_000_400)
        )

        await model.healthcheckCurrentManagedProxyNode()

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "948 ms")
        XCTAssertEqual(model.managedProxyNodeDelayTone(model.managedProxyFocusedNode!), .accent)
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · 948 ms")
        XCTAssertEqual(model.managedProxyNodeHealthcheckDisplayStates["Tokyo"]?.status, .succeeded)
        XCTAssertEqual(model.managedProxyNodeHealthcheckDisplayStates["Tokyo"]?.latencyMS, 948)
    }

    @MainActor
    func testManagedProxyAllNodeHealthcheckUsesNilRequest() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertNil(request.nodeName)
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running
        )

        await model.healthcheckAllManagedProxyNodes()
    }

    @MainActor
    func testManagedProxyBatchHealthcheckFeedbackShowsUpdatedNodeCountAndCurrentLatency() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertNil(request.nodeName)
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 71,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84, lastHealthcheckAt: 1_710_000_200),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84, lastHealthcheckAt: 1_710_000_200),
            ]
        )
        model.focusManagedProxyNode("Seoul")

        await model.healthcheckAllManagedProxyNodes()

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyFocusedNode?.lastDelayMS, 71)
        XCTAssertEqual(
            model.managedProxyHealthcheckFeedbackText,
            "Succeeded 1 / Failed 1 · Target cp.cloudflare.com/generate_204"
        )
    }

    @MainActor
    func testManagedProxyBatchHealthcheckFeedbackIncludesSavedTargetHostText() async {
        let customURL = "https://latency.example.com/generate_204"
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertNil(request.nodeName)
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    healthcheckURL: customURL,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 71,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(
                            name: "Seoul",
                            type: "vmess",
                            alive: true,
                            lastDelayMS: 84,
                            lastHealthcheckAt: 1_710_000_401
                        ),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            healthcheckURL: customURL,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )

        await model.healthcheckAllManagedProxyNodes()

        XCTAssertEqual(
            model.managedProxyHealthcheckFeedbackText,
            "Succeeded 2 / Failed 0 · Target latency.example.com/generate_204"
        )
    }

    @MainActor
    func testManagedProxyBatchHealthcheckFallsBackToFirstFreshLatencyNodeWhenCurrentNodeStaysUnchecked() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertNil(request.nodeName)
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                        ManagedProxyNode(
                            name: "Seoul",
                            type: "vmess",
                            alive: true,
                            lastDelayMS: 84,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        model.focusManagedProxyNode("Tokyo")

        await model.healthcheckAllManagedProxyNodes()

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Seoul")
        XCTAssertEqual(model.managedProxyFocusedNode?.lastDelayMS, 84)
        XCTAssertEqual(
            model.managedProxyHealthcheckFeedbackText,
            "Succeeded 1 / Failed 1 · Target cp.cloudflare.com/generate_204"
        )
        XCTAssertEqual(model.banners.first?.tone, .warning)
    }

    @MainActor
    func testManagedProxyCurrentNodeHealthcheckMarksFailedWhenDrawerStillHasNoVisibleLatency() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastHealthcheckStatus: .failure,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        model.focusManagedProxyNode("Seoul")

        await model.healthcheckCurrentManagedProxyNode()

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · Failed")
        XCTAssertEqual(model.managedProxyNodeAvailabilityText(model.managedProxyFocusedNode!), "Healthy")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "Failed")
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackTone, .danger)
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertEqual(model.banners.first?.title, "Node Health Check Failed")
        XCTAssertEqual(model.banners.first?.detail, "Current node Tokyo · Failed")
    }

    @MainActor
    func testManagedProxyCurrentNodeHealthcheckUsesFeedbackDetailForBanner() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastHealthcheckStatus: .failure,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
                    ],
                    lastHealthcheckFeedbackDetail: "Probe timed out"
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        model.focusManagedProxyNode("Seoul")

        await model.healthcheckCurrentManagedProxyNode()

        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · Failed")
        XCTAssertEqual(model.banners.first?.title, "Node Health Check Failed")
        XCTAssertEqual(model.banners.first?.detail, "Probe timed out")
    }

    @MainActor
    func testManagedProxyCurrentNodeHealthcheckRemoteRouteErrorSuggestsRedeploy() async {
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                throw ProxyError.message("HTTP 404")
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )

        await model.healthcheckCurrentManagedProxyNode()

        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · Failed")
        XCTAssertEqual(model.banners.first?.title, "Node Health Check Failed")
        XCTAssertEqual(
            model.banners.first?.detail,
            "The remote proxy service is too old for node health checks. Redeploy or update the remote service and try again."
        )
    }

    @MainActor
    func testManagedProxyCurrentNodeHealthcheckTreatsZeroLatencyAsFailed() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastHealthcheckStatus: .failure,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )

        await model.healthcheckCurrentManagedProxyNode()

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · Failed")
        XCTAssertEqual(model.managedProxyNodeAvailabilityText(model.managedProxyFocusedNode!), "Healthy")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "Failed")
        XCTAssertEqual(model.managedProxyNodeDelayTone(model.managedProxyFocusedNode!), .danger)
        XCTAssertEqual(model.managedProxyNodeHealthcheckDisplayStates["Tokyo"]?.status, .failed)
    }

    @MainActor
    func testManagedProxyRowHealthcheckFailureOverridesStaleLatencyText() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Seoul")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 68,
                            lastHealthcheckAt: 1_710_000_200
                        ),
                        ManagedProxyNode(
                            name: "Seoul",
                            type: "vmess",
                            alive: true,
                            lastDelayMS: 84,
                            lastHealthcheckStatus: .failure,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(
                    name: "Tokyo",
                    type: "ss",
                    isCurrent: true,
                    isPinned: true,
                    alive: true,
                    lastDelayMS: 68,
                    lastHealthcheckAt: 1_710_000_200
                ),
                ManagedProxyNode(
                    name: "Seoul",
                    type: "vmess",
                    alive: true,
                    lastDelayMS: 84,
                    lastHealthcheckAt: 1_710_000_100
                ),
            ]
        )

        model.focusManagedProxyNode("Seoul")
        await model.healthcheckManagedProxy(nodeName: "Seoul")

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Seoul")
        XCTAssertEqual(model.managedProxyNodeAvailabilityText(model.managedProxyFocusedNode!), "Healthy")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "Failed")
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Node Seoul · Failed")
    }

    @MainActor
    func testManagedProxyLegacyHealthcheckFailureFallbackStillMarksDelayFailed() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Seoul")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 68,
                            lastHealthcheckAt: 1_710_000_200
                        ),
                        ManagedProxyNode(
                            name: "Seoul",
                            type: "vmess",
                            alive: true,
                            lastDelayMS: 84,
                            lastHealthcheckAt: 1_710_000_100
                        ),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(
                    name: "Tokyo",
                    type: "ss",
                    isCurrent: true,
                    isPinned: true,
                    alive: true,
                    lastDelayMS: 68,
                    lastHealthcheckAt: 1_710_000_200
                ),
                ManagedProxyNode(
                    name: "Seoul",
                    type: "vmess",
                    alive: true,
                    lastDelayMS: 84,
                    lastHealthcheckAt: 1_710_000_100
                ),
            ]
        )

        model.focusManagedProxyNode("Seoul")
        await model.healthcheckManagedProxy(nodeName: "Seoul")

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Seoul")
        XCTAssertEqual(model.managedProxyNodeAvailabilityText(model.managedProxyFocusedNode!), "Healthy")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "Failed")
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Node Seoul · Failed")
    }

    @MainActor
    func testManagedProxyCurrentNodeHealthcheckClearsSearchToRevealActiveNode() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 68,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        model.managedProxyNodeSearchQuery = "seo"
        model.syncManagedProxyFocus()
        model.focusManagedProxyNode("Seoul")

        await model.healthcheckCurrentManagedProxyNode()

        XCTAssertEqual(model.managedProxyNodeSearchQuery, "")
        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "68 ms")
    }

    @MainActor
    func testManagedProxyBatchHealthcheckClearsSearchToRevealCurrentNode() async {
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertNil(request.nodeName)
                return ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    runtimeState: .running,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: [
                        ManagedProxyNode(
                            name: "Tokyo",
                            type: "ss",
                            isCurrent: true,
                            isPinned: true,
                            alive: true,
                            lastDelayMS: 71,
                            lastHealthcheckAt: 1_710_000_400
                        ),
                        ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84),
                    ]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84),
            ]
        )
        model.managedProxyNodeSearchQuery = "seo"
        model.syncManagedProxyFocus()
        model.focusManagedProxyNode("Seoul")

        await model.healthcheckAllManagedProxyNodes()

        XCTAssertEqual(model.managedProxyNodeSearchQuery, "")
        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "71 ms")
    }

    @MainActor
    func testManagedProxyHealthcheckHelpersReflectRuntimeAndCurrentNodeAvailability() {
        let model = DesktopAppModel()
        model.settings.outboundProxyMode = .subscription
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: nil
        )

        XCTAssertFalse(model.canHealthcheckCurrentManagedProxyNode)
        XCTAssertTrue(model.canHealthcheckAllManagedProxyNodes)

        model.managedProxySnapshot.currentNodeName = "Tokyo"
        XCTAssertTrue(model.canHealthcheckCurrentManagedProxyNode)
        XCTAssertTrue(model.canHealthcheckAllManagedProxyNodes)

        model.status = Self.makeProxyStatus(running: false)
        XCTAssertFalse(model.canHealthcheckCurrentManagedProxyNode)
        XCTAssertFalse(model.canHealthcheckAllManagedProxyNodes)
    }

    @MainActor
    func testManagedProxyUpdateSubscriptionFallsBackWhenFocusedNodeDisappears() async {
        let updatedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 66),
                ManagedProxyNode(name: "Osaka", type: "trojan", alive: true, lastDelayMS: 91),
            ]
        )
        let admin = AdminAPIClient(
            updateManagedProxySubscriptionHandler: { updatedSnapshot }
        )
        let model = DesktopAppModel(admin: admin)
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 88),
            ]
        )
        model.focusManagedProxyNode("Seoul")

        await model.updateManagedProxySubscription()

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
    }

    @MainActor
    func testManagedProxyWebsiteProbeTargetsUsePlannedDefaultURLs() {
        let model = DesktopAppModel()
        model.managedProxySnapshot = ManagedProxySnapshot(
            healthcheckURL: "https://latency.example.com/generate_204"
        )

        XCTAssertEqual(
            model.managedProxyWebsiteProbeTargets.map(\.rawValue),
            ["custom", "google", "github", "youtube", "wikipedia"]
        )
        XCTAssertEqual(
            model.managedProxyWebsiteProbeTargets.compactMap { model.managedProxyWebsiteProbeURL($0)?.absoluteString },
            [
                "https://latency.example.com/generate_204",
                "https://www.google.com/generate_204",
                "https://github.com/robots.txt",
                "https://www.youtube.com/robots.txt",
                "https://www.wikipedia.org/robots.txt",
            ]
        )
    }

    @MainActor
    func testManagedProxyWebsiteProbeBatchMapsStatesAndRetryUpdatesSingleTargetOnly() async {
        let attempts = ManagedProxyWebsiteProbeAttemptProbe()
        let customURL = "https://latency.example.com/generate_204"
        let client = ManagedProxyWebsiteProbeClient(probeHandler: { target, url, mixedPort in
            XCTAssertEqual(mixedPort, 7890)
            let attempt = await attempts.record(target)
            switch (target, attempt) {
            case (.custom, _):
                XCTAssertEqual(url.absoluteString, customURL)
                return ManagedProxyWebsiteProbeResponse(statusCode: 204, latencyMilliseconds: 77)
            case (.google, _):
                return ManagedProxyWebsiteProbeResponse(statusCode: 204, latencyMilliseconds: 118)
            case (.github, 1):
                return ManagedProxyWebsiteProbeResponse(statusCode: 503, latencyMilliseconds: 265)
            case (.github, _):
                return ManagedProxyWebsiteProbeResponse(statusCode: 200, latencyMilliseconds: 91)
            case (.youtube, _):
                throw URLError(.timedOut)
            case (.wikipedia, _):
                return ManagedProxyWebsiteProbeResponse(statusCode: 302, latencyMilliseconds: 143)
            }
        })
        let model = DesktopAppModel(managedProxyWebsiteProbeClient: client)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            healthcheckURL: customURL,
            runtimeState: .running,
            controllerReachable: true,
            mixedPort: 7890,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
            ]
        )

        await model.runAllManagedProxyWebsiteProbes()

        XCTAssertTrue(model.managedProxyWebsiteProbeRunningTargets.isEmpty)
        XCTAssertNotNil(model.managedProxyWebsiteProbeLastBatchTestedAt)
        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .custom), .succeeded)
        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .google), .succeeded)
        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .github), .succeeded)
        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .youtube), .failed)
        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .wikipedia), .succeeded)
        XCTAssertEqual(model.managedProxyWebsiteProbeHTTPStatusText(.github), "503")
        XCTAssertEqual(model.managedProxyWebsiteProbeLatencyText(.github), "265 ms")
        XCTAssertEqual(model.managedProxyWebsiteProbeStatusText(.youtube), "Failed")

        let googleResult = model.managedProxyWebsiteProbeResult(for: .google)
        let youtubeResult = model.managedProxyWebsiteProbeResult(for: .youtube)

        await model.runManagedProxyWebsiteProbe(.github)

        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .github), .succeeded)
        XCTAssertEqual(model.managedProxyWebsiteProbeHTTPStatusText(.github), "200")
        XCTAssertEqual(model.managedProxyWebsiteProbeLatencyText(.github), "91 ms")
        XCTAssertEqual(model.managedProxyWebsiteProbeResult(for: .google), googleResult)
        XCTAssertEqual(model.managedProxyWebsiteProbeResult(for: .youtube), youtubeResult)

        let counts = await attempts.snapshot()
        XCTAssertEqual(counts[.custom], 1)
        XCTAssertEqual(counts[.google], 1)
        XCTAssertEqual(counts[.github], 2)
        XCTAssertEqual(counts[.youtube], 1)
        XCTAssertEqual(counts[.wikipedia], 1)
    }

    @MainActor
    func testManagedProxyWebsiteProbeDisabledStateBlocksRequests() async {
        let attempts = ManagedProxyWebsiteProbeAttemptProbe()
        let client = ManagedProxyWebsiteProbeClient(probeHandler: { target, url, mixedPort in
            _ = target
            _ = url
            _ = mixedPort
            _ = await attempts.record(.google)
            return ManagedProxyWebsiteProbeResponse(statusCode: 200, latencyMilliseconds: 100)
        })
        let model = DesktopAppModel(managedProxyWebsiteProbeClient: client)
        model.preferences.languageMode = .zhHans
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            runtimeState: .running,
            currentNodeName: nil
        )

        XCTAssertFalse(model.canRunManagedProxyWebsiteProbes)
        XCTAssertTrue(model.managedProxyWebsiteProbeUnavailableReason?.contains("mixed-port") == true)

        await model.runAllManagedProxyWebsiteProbes()
        await model.runManagedProxyWebsiteProbe(.google)

        let counts = await attempts.snapshot()
        XCTAssertEqual(counts.count, 0)
        XCTAssertTrue(model.managedProxyWebsiteProbeResults.isEmpty)
    }

    @MainActor
    func testManagedProxyWebsiteProbeResultsResetOnSubscriptionAndTargetSavesButNotNodeHealthcheck() async {
        let runtimeSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            healthcheckURL: "https://latency.example.com/generate_204",
            runtimeState: .running,
            controllerReachable: true,
            mixedPort: 7890,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 92),
            ]
        )
        let healthcheckSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            healthcheckURL: "https://latency.example.com/generate_204",
            runtimeState: .running,
            controllerReachable: true,
            mixedPort: 7890,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(
                    name: "Tokyo",
                    type: "ss",
                    isCurrent: true,
                    isPinned: true,
                    alive: true,
                    lastDelayMS: 68,
                    lastHealthcheckAt: 1_710_000_500
                ),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 92),
            ]
        )
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: true) },
            saveSettingsHandler: { config in config },
            getSettingsHandler: { AppConfig() },
            saveManagedProxyConfigHandler: { _ in runtimeSnapshot },
            saveManagedProxyHealthcheckConfigHandler: { _ in
                ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: true,
                    subscriptionURL: "https://example.com/subscription",
                    healthcheckURL: ManagedProxyConfigSummary.defaultHealthcheckURL,
                    runtimeState: .running,
                    controllerReachable: true,
                    mixedPort: 7890,
                    currentNodeName: "Tokyo",
                    pinnedNodeName: "Tokyo",
                    pinnedNodeAvailable: true,
                    nodes: runtimeSnapshot.nodes
                )
            },
            updateManagedProxySubscriptionHandler: { runtimeSnapshot },
            selectManagedProxyNodeHandler: { _ in runtimeSnapshot },
            healthcheckManagedProxyHandler: { _ in healthcheckSnapshot }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            statusHandler: {
                LocalServiceStatus(
                    installed: true,
                    running: true,
                    launchctlState: "running",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        model.managedProxySnapshot = runtimeSnapshot

        model.managedProxyWebsiteProbeResults[.google] = ManagedProxyWebsiteProbeResult(
            target: .google,
            state: .succeeded,
            statusCode: 204,
            latencyMilliseconds: 88,
            testedAt: Date()
        )
        model.managedProxyHealthcheckFeedback = ManagedProxyHealthcheckFeedback(
            kind: .node,
            nodeName: "Tokyo",
            latencyMS: 68
        )
        model.managedProxyNodeHealthcheckDisplayStates["Tokyo"] = ManagedProxyNodeHealthcheckDisplayState(
            status: .succeeded,
            latencyMS: 68
        )
        await model.healthcheckManagedProxy(nodeName: "Tokyo")
        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .google), .succeeded)
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · 68 ms")

        model.managedProxyWebsiteProbeResults[.google] = ManagedProxyWebsiteProbeResult(
            target: .google,
            state: .succeeded,
            statusCode: 204,
            latencyMilliseconds: 88,
            testedAt: Date()
        )
        model.managedProxyHealthcheckFeedback = ManagedProxyHealthcheckFeedback(
            kind: .node,
            nodeName: "Tokyo",
            latencyMS: 68
        )
        await model.saveProxySettings()
        XCTAssertTrue(model.managedProxyWebsiteProbeResults.isEmpty)
        XCTAssertNil(model.managedProxyHealthcheckFeedback)
        XCTAssertTrue(model.managedProxyNodeHealthcheckDisplayStates.isEmpty)

        model.managedProxyWebsiteProbeResults[.google] = ManagedProxyWebsiteProbeResult(
            target: .google,
            state: .succeeded,
            statusCode: 204,
            latencyMilliseconds: 88,
            testedAt: Date()
        )
        model.managedProxyHealthcheckFeedback = ManagedProxyHealthcheckFeedback(
            kind: .node,
            nodeName: "Tokyo",
            latencyMS: 68
        )
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = runtimeSnapshot
        await model.updateManagedProxySubscription()
        XCTAssertTrue(model.managedProxyWebsiteProbeResults.isEmpty)
        XCTAssertNil(model.managedProxyHealthcheckFeedback)
        XCTAssertTrue(model.managedProxyNodeHealthcheckDisplayStates.isEmpty)

        model.managedProxyWebsiteProbeResults[.google] = ManagedProxyWebsiteProbeResult(
            target: .google,
            state: .succeeded,
            statusCode: 204,
            latencyMilliseconds: 88,
            testedAt: Date()
        )
        model.managedProxyHealthcheckFeedback = ManagedProxyHealthcheckFeedback(
            kind: .node,
            nodeName: "Tokyo",
            latencyMS: 68
        )
        model.managedProxyHealthcheckURLDraft = "   "
        await model.saveManagedProxyHealthcheckURL()
        XCTAssertTrue(model.managedProxyWebsiteProbeResults.isEmpty)
        XCTAssertNil(model.managedProxyHealthcheckFeedback)
        XCTAssertTrue(model.managedProxyNodeHealthcheckDisplayStates.isEmpty)
        XCTAssertEqual(model.managedProxyHealthcheckURLDraft, ManagedProxyConfigSummary.defaultHealthcheckURL)

        model.managedProxyWebsiteProbeResults[.google] = ManagedProxyWebsiteProbeResult(
            target: .google,
            state: .succeeded,
            statusCode: 204,
            latencyMilliseconds: 88,
            testedAt: Date()
        )
        model.managedProxyHealthcheckFeedback = ManagedProxyHealthcheckFeedback(
            kind: .node,
            nodeName: "Tokyo",
            latencyMS: 68
        )
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = runtimeSnapshot
        await model.selectManagedProxyNode("Tokyo")
        XCTAssertTrue(model.managedProxyWebsiteProbeResults.isEmpty)
        XCTAssertNil(model.managedProxyHealthcheckFeedback)
        XCTAssertTrue(model.managedProxyNodeHealthcheckDisplayStates.isEmpty)
    }

    @MainActor
    func testOpenManagedProxyManagerWindowResetsHealthcheckFeedback() {
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                getManagedProxySnapshotHandler: {
                    ManagedProxySnapshot(
                        mode: .subscription,
                        subscriptionConfigured: true,
                        runtimeState: .running,
                        currentNodeName: "Tokyo",
                        nodes: [ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 68)]
                    )
                }
            )
        )
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription
        model.managedProxyHealthcheckFeedback = ManagedProxyHealthcheckFeedback(
            kind: .node,
            nodeName: "Tokyo",
            latencyMS: 68
        )
        model.managedProxyNodeHealthcheckDisplayStates["Tokyo"] = ManagedProxyNodeHealthcheckDisplayState(
            status: .succeeded,
            latencyMS: 68
        )

        model.openManagedProxyManagerWindow()

        XCTAssertNil(model.managedProxyHealthcheckFeedback)
        XCTAssertTrue(model.managedProxyNodeHealthcheckDisplayStates.isEmpty)
    }

    @MainActor
    func testOpenManagedProxyManagerWindowRefreshesSnapshotWithoutChangingOutboundProxyModes() async {
        let expectedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            healthcheckURL: "https://latency.example.com/generate_204",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 68),
            ]
        )
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                getManagedProxySnapshotHandler: {
                    expectedSnapshot
                }
            )
        )
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .manual
        model.settings.outboundProxy = OutboundProxySettings(
            scheme: .http,
            host: "127.0.0.1",
            port: 7890,
            username: "",
            password: ""
        )
        model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)
        model.setSettingsOutboundProxyDraftMode(.disabled)

        model.openManagedProxyManagerWindow()
        defer { model.dismissManagedProxyManagerWindow() }

        XCTAssertTrue(model.isManagedProxyManagerPresented)
        XCTAssertEqual(model.settings.outboundProxyMode, .manual)
        XCTAssertEqual(model.settingsOutboundProxyDraft.mode, .disabled)
        XCTAssertTrue(model.settingsOutboundProxyModeNeedsConfirmation)

        await Self.waitForCondition {
            model.managedProxySnapshot.subscriptionURL == expectedSnapshot.subscriptionURL
        }

        XCTAssertEqual(model.managedProxySnapshot, expectedSnapshot)
        XCTAssertEqual(model.managedProxySubscriptionURLDraft, expectedSnapshot.subscriptionURL)
        XCTAssertEqual(model.managedProxyHealthcheckURLDraft, expectedSnapshot.healthcheckURL)
        XCTAssertEqual(model.settings.outboundProxyMode, .manual)
        XCTAssertEqual(model.settingsOutboundProxyDraft.mode, .disabled)
        XCTAssertTrue(model.settingsOutboundProxyModeNeedsConfirmation)
    }

    @MainActor
    func testOpenManagedProxyManagerWindowShowsMigratedLegacyGoogleHealthcheckURLInDraft() async {
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                getManagedProxySnapshotHandler: {
                    ManagedProxySnapshot(
                        mode: .subscription,
                        subscriptionConfigured: true,
                        healthcheckURL: "https://www.google.com/generate_204",
                        runtimeState: .running
                    )
                }
            )
        )
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .subscription

        model.openManagedProxyManagerWindow()
        defer { model.dismissManagedProxyManagerWindow() }

        await Self.waitForCondition {
            model.managedProxyHealthcheckURLDraft == ManagedProxyConfigSummary.defaultHealthcheckURL
        }

        XCTAssertEqual(model.managedProxySnapshot.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertEqual(model.managedProxyHealthcheckURLDraft, ManagedProxyConfigSummary.defaultHealthcheckURL)
    }

    @MainActor
    func testRefreshManagedProxySnapshotClearsStaleSubscriptionDraftWhenLatestSnapshotHasNoURL() async {
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                getManagedProxySnapshotHandler: {
                    ManagedProxySnapshot(
                        mode: .subscription,
                        subscriptionConfigured: false,
                        subscriptionURL: nil,
                        healthcheckURL: ManagedProxyConfigSummary.defaultHealthcheckURL,
                        runtimeState: .stopped
                    )
                }
            )
        )
        model.managedProxySubscriptionURLDraft = "https://stale.example.com/subscription"
        model.managedProxyHealthcheckURLDraft = "https://stale.example.com/generate_204"

        await model.refreshManagedProxySnapshot(showLoading: true)

        XCTAssertEqual(model.managedProxySubscriptionURLDraft, "")
        XCTAssertEqual(model.managedProxyHealthcheckURLDraft, ManagedProxyConfigSummary.defaultHealthcheckURL)
    }

    @MainActor
    func testManagedProxyManagerLayoutMetricsUseRegularSpacingForTallWindow() {
        let layout = ManagedProxyManagerLayoutMetrics(
            width: 1220,
            height: 900,
            safeAreaTop: 0,
            safeAreaBottom: 0
        )

        XCTAssertFalse(layout.isCompact)
        XCTAssertEqual(layout.outerHorizontalPadding, 22)
        XCTAssertEqual(layout.sectionSpacing, 14)
        XCTAssertEqual(layout.headerSpacing, 12)
        XCTAssertEqual(layout.runtimeMetricColumnCount, 2)
        XCTAssertEqual(layout.nodeTableViewportHeight, 324, accuracy: 0.1)
        XCTAssertEqual(layout.nodeDrawerWidth, 512.4, accuracy: 0.1)
        XCTAssertEqual(layout.nodeDrawerListMinHeight, 522, accuracy: 0.1)
        XCTAssertEqual(layout.pageContentMinHeight, 900)
    }

    @MainActor
    func testManagedProxyManagerLayoutMetricsCompressForShortWindow() {
        let layout = ManagedProxyManagerLayoutMetrics(
            width: 1060,
            height: 680,
            safeAreaTop: 0,
            safeAreaBottom: 0
        )

        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.outerHorizontalPadding, 16)
        XCTAssertEqual(layout.sectionSpacing, 10)
        XCTAssertEqual(layout.headerSpacing, 10)
        XCTAssertEqual(layout.runtimeMetricColumnCount, 1)
        XCTAssertEqual(layout.runtimeSummaryLineLimit, 2)
        XCTAssertGreaterThanOrEqual(layout.nodeTableViewportHeight, 240)
        XCTAssertLessThanOrEqual(layout.nodeTableViewportHeight, 360)
        XCTAssertEqual(layout.nodeTableViewportHeight, 244.8, accuracy: 0.1)
        XCTAssertEqual(layout.nodeDrawerWidth, 487.6, accuracy: 0.1)
        XCTAssertEqual(layout.nodeDrawerListMinHeight, 394.4, accuracy: 0.1)
        XCTAssertEqual(layout.pageContentMinHeight, 680)
    }

    @MainActor
    func testManagedProxyManagerViewDefaultRenderUsesPageLevelScrollViewWithoutInlineTable() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.outboundProxyMode = .subscription
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        model.isManagedProxyLogsExpanded = false
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            providerUpdatedAt: 1_710_000_100,
            nodes: [
                ManagedProxyNode(
                    name: "Tokyo",
                    type: "ss",
                    isCurrent: true,
                    isPinned: true,
                    alive: true,
                    lastDelayMS: 68,
                    lastHealthcheckAt: 1_710_000_100
                ),
                ManagedProxyNode(
                    name: "Seoul",
                    type: "vmess",
                    isCurrent: false,
                    isPinned: false,
                    alive: true,
                    lastDelayMS: 92,
                    lastHealthcheckAt: 1_710_000_090
                ),
            ]
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: ManagedProxyManagerView(model: model)
                .frame(width: 1060, height: 680)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        XCTAssertGreaterThanOrEqual(Self.hostedSubviewCount(in: hostingView, named: "NSScrollView"), 1)
        XCTAssertEqual(Self.hostedSubviewCount(in: hostingView, named: "NSTableView"), 0)
        Self.assertCompactOverlayScrollbars(in: hostingView)
    }

    @MainActor
    func testManagedProxyManagerViewRendersWebsiteProbeCardAndDefaultRows() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.outboundProxyMode = .subscription
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true,
            mixedPort: 7890,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            providerUpdatedAt: 1_710_000_100,
            nodes: [
                ManagedProxyNode(
                    name: "Tokyo",
                    type: "ss",
                    isCurrent: true,
                    isPinned: true,
                    alive: true,
                    lastDelayMS: 68,
                    lastHealthcheckAt: 1_710_000_100
                ),
            ]
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: ManagedProxyManagerView(model: model)
                .frame(width: 1060, height: 680)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        XCTAssertGreaterThanOrEqual(Self.hostedSubviewCount(in: hostingView, named: "NSScrollView"), 1)
        XCTAssertEqual(Self.hostedSubviewCount(in: hostingView, named: "NSTableView"), 0)
        XCTAssertEqual(
            model.managedProxyWebsiteProbeTargets.map(\.rawValue),
            ["custom", "google", "github", "youtube", "wikipedia"]
        )
        XCTAssertEqual(model.managedProxyWebsiteProbeState(for: .google), .idle)
    }

    @MainActor
    func testManagedProxyManagerViewDrawerRenderShowsOverlayScrollAndLatencyText() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/ManagedProxyManagerView.swift")
        let baseSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            providerUpdatedAt: 1_710_000_100,
            nodes: [
                ManagedProxyNode(
                    name: "Tokyo",
                    type: "ss",
                    isCurrent: true,
                    isPinned: true,
                    alive: true,
                    lastDelayMS: 68,
                    lastHealthcheckAt: 1_710_000_100
                ),
                ManagedProxyNode(
                    name: "Seoul",
                    type: "vmess",
                    isCurrent: false,
                    isPinned: false,
                    alive: true,
                    lastDelayMS: 92,
                    lastHealthcheckAt: 1_710_000_090
                ),
            ]
        )

        let closedModel = DesktopAppModel()
        closedModel.preferences.languageMode = .english
        closedModel.settings.outboundProxyMode = .subscription
        closedModel.status = Self.makeProxyStatus(running: true)
        closedModel.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        closedModel.isManagedProxyLogsExpanded = false
        closedModel.managedProxySnapshot = baseSnapshot

        let openModel = DesktopAppModel()
        openModel.preferences.languageMode = .english
        openModel.settings.outboundProxyMode = .subscription
        openModel.status = Self.makeProxyStatus(running: true)
        openModel.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        openModel.isManagedProxyLogsExpanded = false
        openModel.managedProxySnapshot = baseSnapshot
        openModel.presentManagedProxyNodesDrawer()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let closedHostingView = NSHostingView(
            rootView: ManagedProxyManagerView(model: closedModel)
                .frame(width: 1060, height: 680)
        )
        closedHostingView.frame = window.contentLayoutRect
        window.contentView = closedHostingView

        Self.renderHostedView(closedHostingView)

        let openHostingView = NSHostingView(
            rootView: ManagedProxyManagerView(model: openModel)
                .frame(width: 1060, height: 680)
        )
        openHostingView.frame = window.contentLayoutRect
        window.contentView = openHostingView

        Self.renderHostedView(openHostingView)

        XCTAssertGreaterThanOrEqual(Self.hostedSubviewCount(in: openHostingView, named: "NSScrollView"), 1)
        XCTAssertEqual(Self.hostedSubviewCount(in: openHostingView, named: "NSTableView"), 0)
        XCTAssertGreaterThanOrEqual(Self.hostedSubviewCount(in: openHostingView, named: "NSView"), 1)
        XCTAssertEqual(openModel.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(openModel.managedProxyFocusedNode?.lastDelayMS, 68)
        XCTAssertEqual(openModel.managedProxyNodeDelayText(openModel.managedProxyFocusedNode!), "68 ms")
        XCTAssertTrue(source.contains("\"managed-proxy-drawer-focused-node-summary\""))
        XCTAssertTrue(source.contains("self.model.managedProxyNodeDelayText(node)"))
    }

    @MainActor
    func testManagedProxyManagerViewDrawerRendersLatestHealthcheckFeedbackStrip() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.outboundProxyMode = .subscription
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 84, lastHealthcheckAt: 1_710_000_200),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        model.managedProxyHealthcheckFeedback = ManagedProxyHealthcheckFeedback(
            kind: .node,
            nodeName: "Tokyo",
            latencyMS: 84
        )
        model.presentManagedProxyNodesDrawer()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: ManagedProxyManagerView(model: model)
                .frame(width: 1060, height: 680)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · 84 ms")
        XCTAssertGreaterThanOrEqual(Self.hostedSubviewCount(in: hostingView, named: "NSScrollView"), 1)
    }

    @MainActor
    func testManagedProxyDrawerCurrentHealthcheckMountedViewRefreshesFeedbackAndLatencyText() async {
        let updatedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(
                    name: "Tokyo",
                    type: "ss",
                    isCurrent: true,
                    isPinned: true,
                    alive: true,
                    lastDelayMS: 84,
                    lastHealthcheckAt: 1_710_000_200
                ),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        let admin = AdminAPIClient(
            healthcheckManagedProxyHandler: { request in
                XCTAssertEqual(request.nodeName, "Tokyo")
                return updatedSnapshot
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.settings.outboundProxyMode = .subscription
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        model.presentManagedProxyNodesDrawer()
        model.focusManagedProxyNode("Seoul")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: ManagedProxyManagerView(model: model)
                .frame(width: 1060, height: 680)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        await model.healthcheckCurrentManagedProxyNode()
        Self.renderHostedView(hostingView)

        XCTAssertEqual(model.managedProxyFocusedNode?.name, "Tokyo")
        XCTAssertEqual(model.managedProxyHealthcheckFeedbackText, "Current node Tokyo · 84 ms")
        XCTAssertEqual(model.managedProxyNodeDelayText(model.managedProxyFocusedNode!), "84 ms")
        XCTAssertNotNil(model.managedProxyHealthcheckFeedback)
        XCTAssertGreaterThanOrEqual(Self.hostedSubviewCount(in: hostingView, named: "NSScrollView"), 1)
    }

    @MainActor
    func testProxyViewRendersCompressedAccessOverviewAndTabStrip() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.localServiceStatus = Self.makeLocalServiceStatus(running: true)
        var status = Self.makeProxyStatus(running: true)
        status.activeAccountLabel = "Primary Workspace"
        status.activeAccountID = "acct-proxy-summary"
        model.status = status
        model.selectedProxyWorkspaceTab = .access

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 880),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: ProxyView(model: model)
                .frame(width: 1240, height: 880)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        XCTAssertEqual(Self.hostedSubviewCount(in: hostingView, named: "NSTableView"), 0)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    @MainActor
    func testProxyAccessOverviewCardBecomesTallerInNarrowWidthWithoutLosingContent() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.localServiceStatus = Self.makeLocalServiceStatus(running: true)
        var status = Self.makeProxyStatus(running: true)
        status.activeAccountLabel = "Primary Workspace"
        status.activeAccountID = "acct-proxy-summary"
        model.status = status

        let wideWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { wideWindow.orderOut(nil) }

        let wideHostingView = NSHostingView(
            rootView: ProxyAccessOverviewCard(model: model)
                .frame(width: 1120, alignment: .leading)
        )
        wideHostingView.frame = wideWindow.contentLayoutRect
        wideWindow.contentView = wideHostingView
        Self.renderHostedView(wideHostingView)

        let narrowWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { narrowWindow.orderOut(nil) }

        let narrowHostingView = NSHostingView(
            rootView: ProxyAccessOverviewCard(model: model)
                .frame(width: 520, alignment: .leading)
        )
        narrowHostingView.frame = narrowWindow.contentLayoutRect
        narrowWindow.contentView = narrowHostingView
        Self.renderHostedView(narrowHostingView)

        let wideHeight = wideHostingView.fittingSize.height
        let narrowHeight = narrowHostingView.fittingSize.height

        XCTAssertGreaterThan(narrowHeight, wideHeight + 20)
        XCTAssertEqual(Self.hostedSubviewCount(in: narrowHostingView, named: "NSTableView"), 0)
    }

    @MainActor
    func testSettingsViewRendersCompressedAppearanceSummaryCardAndTabs() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.preferences.themeMode = .dark
        model.settings.windowCloseBehavior = .hideToMenuBar
        model.selectedSettingsTab = .appearance

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: SettingsView(model: model)
                .frame(width: 1180, height: 860)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        let summaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { summaryWindow.orderOut(nil) }

        let summaryHostingView = NSHostingView(
            rootView: SettingsAppearanceSummaryCard(model: model)
                .frame(width: 1180, alignment: .leading)
        )
        summaryHostingView.frame = summaryWindow.contentLayoutRect
        summaryWindow.contentView = summaryHostingView

        Self.renderHostedView(summaryHostingView)

        XCTAssertEqual(Self.hostedSubviewCount(in: hostingView, named: "NSTableView"), 0)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        XCTAssertLessThan(summaryHostingView.fittingSize.height, 220)
    }

    @MainActor
    func testSettingsProxyPanelDeclaresManageSubscriptionHeaderAccessory() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("accessory: Button(self.model.managedProxyManagerWindowTitle)"))
        XCTAssertTrue(source.contains("switch self.model.settingsOutboundProxyDraft.mode"))
        XCTAssertFalse(source.contains("self.manageSubscriptionPanel"))
    }

    @MainActor
    func testSettingsProxyPanelRemovesInlineSubscriptionManagementPanelCopy() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("self.model.managedProxyManagerWindowTitle"))
        XCTAssertFalse(source.contains("title: self.model.localizedManagedProxyText(zh: \"订阅管理\", en: \"Subscription Management\")"))
        XCTAssertFalse(source.contains("subtitle: self.model.settingsManagedProxyManagerHelperText"))
    }

    @MainActor
    func testSettingsGeneralPanelDeclaresMenuBarTokenUsageToggle() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("title: self.model.text(.labelMenuBarTokenUsage)"))
        XCTAssertTrue(source.contains("footer: self.model.text(.helperMenuBarTokenUsage)"))
        XCTAssertTrue(source.contains("self.model.updateShowsMenuBarTokenUsage($0)"))
    }

    @MainActor
    func testTitlebarDeclaresKeepAwakeButton() throws {
        let appSource = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")
        let sharedSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/SharedUI.swift")

        XCTAssertTrue(appSource.contains("keepAwakeTitle: self.model.keepAwakeActionTitle"))
        XCTAssertTrue(appSource.contains("onKeepAwake: { self.model.toggleKeepAwake() }"))
        XCTAssertTrue(sharedSource.contains("accessibilityID: \"titlebar-keep-awake-button\""))
    }

    @MainActor
    func testMenuBarPanelDeclaresKeepAwakeToggle() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")

        XCTAssertTrue(source.contains("self.keepAwakeRow(palette: palette)"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"menu-bar-keep-awake-toggle\")"))
        XCTAssertTrue(source.contains("set: { self.model.setKeepAwakeEnabled($0) }"))
    }

    @MainActor
    func testMenuBarPanelKeepAwakeUsesTallerScrollablePopover() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")

        XCTAssertTrue(source.contains("static let width: CGFloat = 300"))
        XCTAssertTrue(source.contains("static let height: CGFloat = 400"))
        XCTAssertTrue(source.contains("popover.contentSize = NSSize(width: MenuBarPanelMetrics.width, height: MenuBarPanelMetrics.height)"))
        XCTAssertTrue(source.contains("ScrollView(.vertical, showsIndicators: false)"))
        XCTAssertTrue(source.contains("self.menuScrollableContent(palette: palette)"))
        XCTAssertTrue(source.contains(".frame(width: MenuBarPanelMetrics.width, height: MenuBarPanelMetrics.height)"))
        XCTAssertTrue(source.contains(".compactOverlayScrollbars()"))
    }

    @MainActor
    func testMenuBarPanelKeepAwakePinsBottomActionBar() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")

        XCTAssertTrue(source.contains("VStack(spacing: 0)"))
        XCTAssertTrue(source.contains("self.menuBottomActionBar(palette: palette)"))
        XCTAssertTrue(source.contains("private func menuBottomActionBar(palette: AppearancePalette) -> some View"))
        XCTAssertTrue(source.contains("HStack(spacing: 8)"))
        XCTAssertTrue(source.contains("Text(self.model.text(.menuReload))\n                        .frame(maxWidth: .infinity)"))
        XCTAssertTrue(source.contains("Text(self.model.text(.menuQuit))\n                        .frame(maxWidth: .infinity)"))
        XCTAssertTrue(source.contains(".buttonStyle(AppActionButtonStyle(kind: .secondary))\n                .frame(maxWidth: .infinity)"))
        XCTAssertTrue(source.contains(".buttonStyle(AppActionButtonStyle(kind: .danger))\n                .frame(maxWidth: .infinity)"))
    }

    @MainActor
    func testKeepAwakeEnablesControllerAndPublishesState() {
        let keepAwakeController = DesktopKeepAwakeControllerSpy()
        let model = DesktopAppModel(keepAwakeController: keepAwakeController)

        model.setKeepAwakeEnabled(true)

        XCTAssertEqual(keepAwakeController.requestedStates, [true])
        XCTAssertTrue(keepAwakeController.isEnabled)
        XCTAssertTrue(model.isKeepAwakeEnabled)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.text(.successKeepAwakeEnabled))
    }

    @MainActor
    func testKeepAwakeDisablesControllerAndPublishesState() {
        let keepAwakeController = DesktopKeepAwakeControllerSpy()
        let model = DesktopAppModel(keepAwakeController: keepAwakeController)

        model.setKeepAwakeEnabled(true)
        model.setKeepAwakeEnabled(false)

        XCTAssertEqual(keepAwakeController.requestedStates, [true, false])
        XCTAssertFalse(keepAwakeController.isEnabled)
        XCTAssertFalse(model.isKeepAwakeEnabled)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.text(.successKeepAwakeDisabled))
    }

    @MainActor
    func testKeepAwakeEnableFailureRollsBackStateAndPublishesError() {
        let keepAwakeController = DesktopKeepAwakeControllerSpy()
        keepAwakeController.enableError = KeepAwakeTestError.failed
        let model = DesktopAppModel(keepAwakeController: keepAwakeController)

        model.setKeepAwakeEnabled(true)

        XCTAssertEqual(keepAwakeController.requestedStates, [true])
        XCTAssertFalse(keepAwakeController.isEnabled)
        XCTAssertFalse(model.isKeepAwakeEnabled)
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertEqual(model.banners.first?.title, model.text(.errorKeepAwakeFailed))
        XCTAssertEqual(model.banners.first?.detail, "simulated keep awake failure")
    }

    @MainActor
    func testReleaseKeepAwakeSilentlyDisablesWithoutPublishingNotice() {
        let keepAwakeController = DesktopKeepAwakeControllerSpy()
        let model = DesktopAppModel(keepAwakeController: keepAwakeController)

        model.setKeepAwakeEnabled(true)
        let bannerCount = model.banners.count

        model.releaseKeepAwakeSilently()

        XCTAssertEqual(keepAwakeController.requestedStates, [true, false])
        XCTAssertFalse(keepAwakeController.isEnabled)
        XCTAssertFalse(model.isKeepAwakeEnabled)
        XCTAssertEqual(model.banners.count, bannerCount)
    }

    @MainActor
    func testDesktopPreferencesDoNotPersistKeepAwakeState() throws {
        let encodedPreferences = String(
            data: try Helpers.encodeJSON(DesktopPreferences(), pretty: true),
            encoding: .utf8
        )

        XCTAssertFalse(encodedPreferences?.localizedCaseInsensitiveContains("keepAwake") ?? true)
        XCTAssertFalse(encodedPreferences?.localizedCaseInsensitiveContains("keep_awake") ?? true)
    }

    @MainActor
    func testUpdateLanguageUpdatesLocalizedTextWithoutRecreatingModel() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        model.updateLanguage(.english)
        XCTAssertEqual(model.text(.menuOpenDashboard), "Open Dashboard")
        XCTAssertEqual(model.pageTitle(.overview), "Overview")
        XCTAssertEqual(model.mainWindowTitle, model.text(.brandName))
        XCTAssertEqual(model.menuBarExtraTitle, model.text(.brandName))

        model.updateLanguage(DesktopLanguageMode.zhHans)
        XCTAssertEqual(model.text(.menuOpenDashboard), "打开控制台")
        XCTAssertEqual(model.pageTitle(.overview), "总览")
        XCTAssertEqual(model.mainWindowTitle, model.text(.brandName))
        XCTAssertEqual(model.menuBarExtraTitle, model.text(.brandName))
        XCTAssertEqual(preferencesStore.load().languageMode, .zhHans)
    }

    @MainActor
    func testUpdateLanguagePublishesPreferencesChange() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(preferencesStore: preferencesStore)
        let expectation = self.expectation(description: "preferences publisher emits")
        var emittedPreferences: DesktopPreferences?
        let cancellable = model.$preferences
            .dropFirst()
            .sink { preferences in
                emittedPreferences = preferences
                expectation.fulfill()
            }

        model.updateLanguage(.zhHans)

        self.wait(for: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(emittedPreferences?.languageMode, .zhHans)
        XCTAssertEqual(emittedPreferences?.themeMode, .system)
        XCTAssertEqual(preferencesStore.load().languageMode, .zhHans)
    }

    @MainActor
    func testMenuRelatedTextFollowsCurrentLanguage() {
        let model = DesktopAppModel()

        model.preferences.languageMode = .english
        XCTAssertEqual(model.text(.menuEdit), "Edit")
        XCTAssertEqual(model.text(.menuView), "View")
        XCTAssertEqual(model.text(.menuSettings), "Settings…")
        XCTAssertEqual(model.text(.menuAboutApp), "About AI Coding Proxy")
        XCTAssertEqual(model.text(.menuOpenMinimalMode), "Open Minimal Mode")
        XCTAssertEqual(model.text(.menuOpenFullMode), "Open Full Mode")
        XCTAssertEqual(model.text(.menuHideApp), "Hide AI Coding Proxy")
        XCTAssertEqual(model.text(.menuHideOthers), "Hide Others")
        XCTAssertEqual(model.text(.menuShowAll), "Show All")
        XCTAssertEqual(model.text(.menuUndo), "Undo")
        XCTAssertEqual(model.text(.menuRedo), "Redo")
        XCTAssertEqual(model.text(.menuCut), "Cut")
        XCTAssertEqual(model.text(.menuPaste), "Paste")
        XCTAssertEqual(model.text(.menuSelectAll), "Select All")
        XCTAssertEqual(model.text(.actionOpenRequestLogs), "Detailed Logs")

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(model.text(.menuEdit), "编辑")
        XCTAssertEqual(model.text(.menuView), "显示")
        XCTAssertEqual(model.text(.menuSettings), "设置…")
        XCTAssertEqual(model.text(.menuAboutApp), "关于 AI Coding Proxy")
        XCTAssertEqual(model.text(.menuOpenMinimalMode), "打开极简模式")
        XCTAssertEqual(model.text(.menuOpenFullMode), "打开全功能模式")
        XCTAssertEqual(model.text(.menuHideApp), "隐藏 AI Coding Proxy")
        XCTAssertEqual(model.text(.menuHideOthers), "隐藏其他")
        XCTAssertEqual(model.text(.menuShowAll), "全部显示")
        XCTAssertEqual(model.text(.menuUndo), "撤销")
        XCTAssertEqual(model.text(.menuRedo), "重做")
        XCTAssertEqual(model.text(.menuCut), "剪切")
        XCTAssertEqual(model.text(.menuPaste), "粘贴")
        XCTAssertEqual(model.text(.menuSelectAll), "全选")
        XCTAssertEqual(model.text(.actionOpenRequestLogs), "查看详细日志")
    }

    @MainActor
    func testDesktopTopMenuKeepsRequestedMenusAndFollowsLanguageSetting() {
        let application = NSApplication.shared
        let originalMainMenu = application.mainMenu
        let aboutPresenter = AboutWindowControllerSpy()
        let helpPresenter = HelpWindowControllerSpy()
        let model = DesktopAppModel(
            aboutWindowFactory: { _ in aboutPresenter },
            helpWindowFactory: { _ in helpPresenter }
        )

        defer {
            application.mainMenu = originalMainMenu
        }

        model.preferences.languageMode = .zhHans
        DesktopMainMenuController.shared.configure(model: model, snapshot: model.menuLocalizationSnapshot)

        XCTAssertEqual(application.mainMenu?.items.map(\.title), ["AI Coding Proxy", "编辑", "显示", "帮助"])
        XCTAssertEqual(application.mainMenu?.items[0].submenu?.items.first?.title, "关于 AI Coding Proxy")
        XCTAssertTrue(application.mainMenu?.items[0].submenu?.items.first?.target === DesktopMainMenuController.shared)
        XCTAssertEqual(application.mainMenu?.items[2].submenu?.items.filter { $0.isSeparatorItem == false }.map(\.title), [
            "打开极简模式",
            "打开全功能模式",
            "查看详细日志",
            "刷新",
            "总览",
            "账号",
            "代理",
            "设置",
        ])
        XCTAssertEqual(application.mainMenu?.items[3].submenu?.items.first?.title, "使用帮助")
        XCTAssertTrue(application.mainMenu?.items[3].submenu?.items.first?.target === DesktopMainMenuController.shared)

        guard let initialMainMenu = application.mainMenu,
              initialMainMenu.items.count == 4
        else {
            XCTFail("Missing managed main menu")
            return
        }
        let initialAppMenuItem = initialMainMenu.items[0]
        let initialEditMenuItem = initialMainMenu.items[1]
        let initialViewMenuItem = initialMainMenu.items[2]
        let initialHelpMenuItem = initialMainMenu.items[3]

        guard let aboutItem = application.mainMenu?.items[0].submenu?.items.first,
              let aboutAction = aboutItem.action
        else {
            XCTFail("Missing About menu item action")
            return
        }
        XCTAssertTrue(NSApp.sendAction(aboutAction, to: aboutItem.target, from: aboutItem))
        XCTAssertEqual(aboutPresenter.showWindowCallCount, 1)

        guard let helpItem = application.mainMenu?.items[3].submenu?.items.first,
              let helpAction = helpItem.action
        else {
            XCTFail("Missing Help menu item action")
            return
        }
        XCTAssertTrue(NSApp.sendAction(helpAction, to: helpItem.target, from: helpItem))
        XCTAssertEqual(helpPresenter.showWindowCallCount, 1)

        model.preferences.languageMode = .english
        DesktopMainMenuController.shared.configure(model: model, snapshot: model.menuLocalizationSnapshot)

        XCTAssertTrue(application.mainMenu === initialMainMenu)
        XCTAssertTrue(application.mainMenu?.items[0] === initialAppMenuItem)
        XCTAssertTrue(application.mainMenu?.items[1] === initialEditMenuItem)
        XCTAssertTrue(application.mainMenu?.items[2] === initialViewMenuItem)
        XCTAssertTrue(application.mainMenu?.items[3] === initialHelpMenuItem)
        XCTAssertEqual(application.mainMenu?.items.map(\.title), ["AI Coding Proxy", "Edit", "View", "Help"])
        XCTAssertEqual(application.mainMenu?.items[2].submenu?.items.filter { $0.isSeparatorItem == false }.map(\.title), [
            "Open Minimal Mode",
            "Open Full Mode",
            "Detailed Logs",
            "Reload",
            "Overview",
            "Accounts",
            "Proxy",
            "Settings",
        ])
        XCTAssertEqual(application.mainMenu?.items[3].submenu?.items.first?.title, "Usage Guide")

        guard let englishViewMenu = application.mainMenu?.items[2].submenu else {
            XCTFail("Missing English View menu")
            return
        }
        let englishViewMenuItems = englishViewMenu.items

        model.selectedPage = .accounts
        DesktopMainMenuController.shared.configure(model: model, snapshot: model.menuLocalizationSnapshot)

        XCTAssertTrue(application.mainMenu === initialMainMenu)
        XCTAssertTrue(application.mainMenu?.items[2].submenu === englishViewMenu)
        XCTAssertEqual(application.mainMenu?.items[2].submenu?.items.count, englishViewMenuItems.count)
        for index in englishViewMenuItems.indices {
            XCTAssertTrue(application.mainMenu?.items[2].submenu?.items[index] === englishViewMenuItems[index])
        }
        XCTAssertTrue(englishViewMenu.items.first { $0.representedObject as? String == DesktopAppModel.Page.overview.rawValue }?.isEnabled == false)
        XCTAssertTrue(englishViewMenu.items.first { $0.representedObject as? String == DesktopAppModel.Page.accounts.rawValue }?.isEnabled == true)

        DesktopMainMenuController.shared.menuNeedsUpdate(englishViewMenu)

        XCTAssertTrue(englishViewMenu.items.first { $0.representedObject as? String == DesktopAppModel.Page.overview.rawValue }?.isEnabled == true)
        XCTAssertTrue(englishViewMenu.items.first { $0.representedObject as? String == DesktopAppModel.Page.accounts.rawValue }?.isEnabled == false)

        model.selectedSettingsTab = .proxy
        DesktopMainMenuController.shared.configure(model: model, snapshot: model.menuLocalizationSnapshot)

        XCTAssertTrue(application.mainMenu === initialMainMenu)
        XCTAssertTrue(application.mainMenu?.items[2].submenu === englishViewMenu)
    }

    @MainActor
    func testDesktopTopMenuRestoresAfterSystemMenuReplacement() {
        let application = NSApplication.shared
        let originalMainMenu = application.mainMenu
        let model = DesktopAppModel()

        defer {
            application.mainMenu = originalMainMenu
        }

        model.preferences.languageMode = .english
        DesktopMainMenuController.shared.configure(model: model, snapshot: model.menuLocalizationSnapshot)

        let systemMenu = NSMenu(title: "SwiftUI Default")
        for title in ["AI Coding Proxy", "Edit", "View", "Window", "Help"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            systemMenu.addItem(item)
        }
        systemMenu.items[2].submenu?.addItem(NSMenuItem(title: "Enter Full Screen", action: nil, keyEquivalent: "f"))
        application.mainMenu = systemMenu

        DesktopMainMenuController.shared.reinstallMenuIfNeeded()

        XCTAssertEqual(application.mainMenu?.items.map(\.title), ["AI Coding Proxy", "Edit", "View", "Help"])
        XCTAssertEqual(application.mainMenu?.items[2].submenu?.items.filter { $0.isSeparatorItem == false }.map(\.title), [
            "Open Minimal Mode",
            "Open Full Mode",
            "Detailed Logs",
            "Reload",
            "Overview",
            "Accounts",
            "Proxy",
            "Settings",
        ])
    }

    @MainActor
    func testDesktopTopMenuIsUnaffectedByPageAndTabSelectionChanges() {
        let application = NSApplication.shared
        let originalMainMenu = application.mainMenu
        let model = DesktopAppModel()

        defer {
            application.mainMenu = originalMainMenu
        }

        model.preferences.languageMode = .english
        DesktopMainMenuController.shared.configure(model: model, snapshot: model.menuLocalizationSnapshot)

        guard let initialMainMenu = application.mainMenu,
              initialMainMenu.items.count > 2,
              let initialViewMenu = initialMainMenu.items[2].submenu
        else {
            XCTFail("Missing managed View menu")
            return
        }
        let initialTopItems = initialMainMenu.items
        let initialViewItems = initialViewMenu.items

        model.selectedPage = .accounts
        model.selectedSettingsTab = .proxy
        model.selectedProxyWorkspaceTab = .access
        model.selectedAccountPoolAccountID = "account-1"

        XCTAssertTrue(application.mainMenu === initialMainMenu)
        XCTAssertEqual(application.mainMenu?.items.map(\.title), ["AI Coding Proxy", "Edit", "View", "Help"])
        for index in initialTopItems.indices {
            XCTAssertTrue(application.mainMenu?.items[index] === initialTopItems[index])
        }
        XCTAssertTrue(application.mainMenu?.items[2].submenu === initialViewMenu)
        for index in initialViewItems.indices {
            XCTAssertTrue(application.mainMenu?.items[2].submenu?.items[index] === initialViewItems[index])
        }
    }

    func testDesktopTopMenuAvoidsSwiftUISceneCommandsAndModelWideMenuRefreshes() throws {
        let appSource = try String(
            contentsOfFile: "Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift",
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOfFile: "Sources/CodexProxyDesktop/DesktopMainMenuController.swift",
            encoding: .utf8
        )
        let appearanceSource = try String(
            contentsOfFile: "Sources/CodexProxyDesktop/Appearance.swift",
            encoding: .utf8
        )
        let swiftUIHostSources = try [
            "Sources/CodexProxyDesktop/AboutWindowController.swift",
            "Sources/CodexProxyDesktop/ClientConfigManagerWindowController.swift",
            "Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift",
            "Sources/CodexProxyDesktop/HelpWindowController.swift",
            "Sources/CodexProxyDesktop/ManagedProxyWindowController.swift",
            "Sources/CodexProxyDesktop/OnboardingWindowController.swift",
            "Sources/CodexProxyDesktop/ProxyTestWindowController.swift",
            "Sources/CodexProxyDesktop/RemoteAdminWindowController.swift",
            "Sources/CodexProxyDesktop/RequestLogsWindowController.swift",
        ].map { try Self.repoFileText($0) }.joined(separator: "\n")
        let statusItemRendererSource = try String(
            contentsOfFile: "Sources/CodexProxyDesktop/MenuBarStatusItemRenderer.swift",
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("enum CodexProxyDesktopMain"))
        XCTAssertTrue(appSource.contains("let app = NSApplication.shared"))
        XCTAssertTrue(appSource.contains("app.delegate = delegate"))
        XCTAssertTrue(appSource.contains("app.run()"))
        XCTAssertTrue(appSource.contains("final class AppDelegate: NSObject, NSApplicationDelegate"))
        XCTAssertTrue(appSource.contains("private var effectiveAppearanceObservation: NSKeyValueObservation?"))
        XCTAssertTrue(appSource.contains("NSApplication.shared.observe("))
        XCTAssertTrue(appSource.contains("\\.effectiveAppearance"))
        let refreshStart = try XCTUnwrap(appSource.range(of: "private func refreshSystemAppearanceIfNeeded() {"))
        let refreshEnd = try XCTUnwrap(appSource[refreshStart.upperBound...].range(of: "\n    }\n\n    private func loadInitialData"))
        let refreshSystemAppearanceBody = String(appSource[refreshStart.upperBound..<refreshEnd.lowerBound])
        XCTAssertTrue(refreshSystemAppearanceBody.contains("guard self.model.preferences.themeMode == .system else { return }"))
        XCTAssertTrue(refreshSystemAppearanceBody.contains("guard self.model.refreshSystemColorScheme() else { return }"))
        XCTAssertTrue(appSource.contains("self.model.refreshThemeSensitiveWindows()"))
        XCTAssertFalse(refreshSystemAppearanceBody.contains("AppearanceStore.applyAppAppearance(for: .system)"))
        XCTAssertFalse(refreshSystemAppearanceBody.contains("self.refreshAppChrome()"))
        XCTAssertTrue(swiftUIHostSources.contains("resolvedPreferredColorScheme"))
        XCTAssertFalse(swiftUIHostSources.contains(".preferredColorScheme(AppearanceStore.preferredColorScheme(for:"))
        XCTAssertTrue(appSource.contains("NSStatusBar.system.statusItem"))
        XCTAssertTrue(appSource.contains("NSStatusItem.squareLength"))
        XCTAssertTrue(appSource.contains("private let statusItemRenderer = MenuBarStatusItemRenderer()"))
        XCTAssertTrue(appSource.contains("private var statusItemRenderResult: MenuBarStatusItemRenderer.RenderResult?"))
        XCTAssertTrue(appSource.contains("popover.delegate = self"))
        XCTAssertTrue(appSource.contains("button.alternateImage = renderedImages.highlighted.image"))
        XCTAssertTrue(appSource.contains("button.highlight(isPopoverShown)"))
        XCTAssertTrue(appSource.contains("self.layoutStatusItemButton(button)"))
        XCTAssertTrue(appSource.contains("self.refreshStatusPopoverPosition(relativeTo: button)"))
        XCTAssertTrue(appSource.contains("private func statusPopoverAnchorRect(in button: NSStatusBarButton)"))
        XCTAssertTrue(appSource.contains("renderResult.visibleContentRect.offsetBy"))
        XCTAssertTrue(appSource.contains("popover.positioningRect = anchorRect"))
        XCTAssertTrue(appSource.contains("button.action = #selector(toggleMenuBarPanel(_:))"))
        XCTAssertTrue(appSource.contains("self.model.$stats"))
        XCTAssertTrue(appSource.contains("button.toolTip = self.model.menuBarStatusItemToolTip"))
        XCTAssertTrue(appSource.contains("button.setAccessibilityLabel(accessibilityLabel)"))
        XCTAssertTrue(appSource.contains("button.imagePosition = .imageOnly"))
        XCTAssertTrue(appSource.contains("self.statusItemRenderer.renderIconOnly"))
        XCTAssertFalse(appSource.contains("private var statusItemContentView: MenuBarStatusItemContentView?"))
        XCTAssertFalse(appSource.contains("contentView.attach(to: button)"))
        XCTAssertFalse(appSource.contains("button.imagePosition = .noImage"))
        XCTAssertFalse(appSource.contains("button.effectiveAppearance"))
        XCTAssertFalse(appSource.contains("AppearanceStore.menuBarAppearance()"))
        XCTAssertFalse(appSource.contains("DistributedNotificationCenter.default().addObserver"))
        XCTAssertFalse(appSource.contains("menuBarAppearanceDidChangeNotification"))
        XCTAssertFalse(appSource.contains("makeStatusItemImage(accessibilityDescription:"))
        XCTAssertFalse(appearanceSource.contains("menuBarAppearanceName"))
        XCTAssertFalse(appearanceSource.contains("menuBarAppearance(systemDefaults:"))
        XCTAssertTrue(statusItemRendererSource.contains("final class MenuBarStatusItemRenderer"))
        XCTAssertTrue(statusItemRendererSource.contains("struct RenderResult"))
        XCTAssertTrue(statusItemRendererSource.contains("private enum RenderContent: Hashable"))
        XCTAssertTrue(statusItemRendererSource.contains("private func tokenFont() -> NSFont"))
        XCTAssertTrue(statusItemRendererSource.contains("func renderIconOnly("))
        XCTAssertTrue(statusItemRendererSource.contains("foregroundColor: NSColor"))
        XCTAssertTrue(statusItemRendererSource.contains("NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)"))
        XCTAssertTrue(statusItemRendererSource.contains("appearance.performAsCurrentDrawingAppearance"))
        XCTAssertTrue(statusItemRendererSource.contains("static let iconSize = NSSize(width: 18, height: 18)"))
        XCTAssertTrue(statusItemRendererSource.contains("static let horizontalPadding: CGFloat = 4"))
        XCTAssertTrue(statusItemRendererSource.contains("static let iconToTextSpacing: CGFloat = 5"))
        XCTAssertTrue(statusItemRendererSource.contains("static let symbolPointSize: CGFloat = 18"))
        XCTAssertTrue(statusItemRendererSource.contains("static let symbolScale: NSImage.SymbolScale = .large"))
        XCTAssertTrue(statusItemRendererSource.contains("image?.withSymbolConfiguration(configuration) ?? image"))
        XCTAssertFalse(statusItemRendererSource.contains(".labelColor"))
        XCTAssertFalse(statusItemRendererSource.contains(".selectedMenuItemTextColor"))
        XCTAssertFalse(appSource.contains("button.title = self.model.menuBarExtraTitle"))
        XCTAssertTrue(appSource.contains("NSWindow(contentViewController: hostingController)"))
        XCTAssertTrue(appSource.contains("window.orderFrontRegardless()"))
        XCTAssertFalse(appSource.contains("@main\n@MainActor\nfinal class AppDelegate"))
        XCTAssertFalse(appSource.contains("struct CodexProxyDesktopApp: App"))
        XCTAssertFalse(appSource.contains("@NSApplicationDelegateAdaptor"))
        XCTAssertFalse(appSource.contains("@Environment(\\.openWindow)"))
        XCTAssertFalse(appSource.contains("@Environment(\\.scenePhase)"))
        XCTAssertFalse(appSource.contains("MenuBarExtra"))
        XCTAssertFalse(appSource.contains(".commands {"))
        XCTAssertFalse(appSource.contains("CommandGroup(replacing:"))
        XCTAssertFalse(appSource.contains("DesktopSuppressedDefaultCommands"))
        XCTAssertFalse(controllerSource.contains("objectWillChange.sink"))
        XCTAssertFalse(controllerSource.contains("import Combine"))
        XCTAssertFalse(controllerSource.contains("NSApplication.didUpdateNotification"))
    }

    func testAuxiliaryWindowHeadersDoNotRenderDuplicateCloseButtons() throws {
        func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: startMarker))
            let end = try XCTUnwrap(source[start.upperBound...].range(of: endMarker))
            return String(source[start.upperBound..<end.lowerBound])
        }

        let requestLogsSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RequestLogsView.swift")
        let proxyTestSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/ProxyTestConsoleView.swift")
        let managedProxySource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/ManagedProxyManagerView.swift")
        let remoteAdminSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RemoteAdminWindowView.swift")
        let remoteAdminControllerSource = try Self.repoFileText("Sources/CodexProxyDesktop/RemoteAdminWindowController.swift")

        let requestLogsHeaderButtons = try slice(
            requestLogsSource,
            from: "private func headerButtons(palette: AppearancePalette) -> some View {",
            to: "\n    private func embeddedControlsDisclosure"
        )
        XCTAssertTrue(requestLogsHeaderButtons.contains("commonReload"))
        XCTAssertFalse(requestLogsHeaderButtons.contains("commonDismiss"))
        XCTAssertFalse(requestLogsHeaderButtons.contains("dismissRequestLogsWindow"))

        let proxyTestHeader = try slice(
            proxyTestSource,
            from: "private func header(palette: AppearancePalette) -> some View {",
            to: "\n    private var requestColumn"
        )
        XCTAssertTrue(proxyTestHeader.contains("commonReload"))
        XCTAssertFalse(proxyTestHeader.contains("commonDismiss"))
        XCTAssertFalse(proxyTestHeader.contains("dismissProxyTestConsole"))

        let managedProxyHeaderButtons = try slice(
            managedProxySource,
            from: "private func headerButtons(palette: AppearancePalette) -> some View {",
            to: "\n    private func embeddedRuntimeActionStrip"
        )
        XCTAssertTrue(managedProxyHeaderButtons.contains("commonReload"))
        XCTAssertFalse(managedProxyHeaderButtons.contains("commonDismiss"))
        XCTAssertFalse(managedProxyHeaderButtons.contains("dismissManagedProxyManagerWindow"))

        let remoteAdminHeader = try slice(
            remoteAdminSource,
            from: "private struct RemoteAdminHeaderCard: View {",
            to: "\n}\n\nprivate struct RemoteAdminNotePanel"
        )
        XCTAssertTrue(remoteAdminHeader.contains("remote-admin-header-refresh-button"))
        XCTAssertTrue(remoteAdminHeader.contains("remote-admin-header-reconnect-button"))
        XCTAssertFalse(remoteAdminHeader.contains("remote-admin-header-close-button"))
        XCTAssertFalse(remoteAdminHeader.contains("关闭窗口"))
        XCTAssertFalse(remoteAdminHeader.contains("Close Window"))
        XCTAssertFalse(remoteAdminSource.contains("let onClose: () -> Void"))
        XCTAssertFalse(remoteAdminControllerSource.contains("RemoteAdminWindowView(model: self.model) {"))
        XCTAssertTrue(remoteAdminControllerSource.contains("RemoteAdminWindowView(model: self.model)"))

        for path in [
            "Sources/CodexProxyDesktop/ProxyTestWindowController.swift",
            "Sources/CodexProxyDesktop/ManagedProxyWindowController.swift",
            "Sources/CodexProxyDesktop/RequestLogsWindowController.swift",
            "Sources/CodexProxyDesktop/RemoteAdminWindowController.swift",
        ] {
            let source = try Self.repoFileText(path)
            XCTAssertTrue(
                source.contains("window.styleMask = [.titled, .closable, .miniaturizable, .resizable]"),
                path
            )
            XCTAssertTrue(source.contains("func windowWillClose"), path)
        }
    }

    @MainActor
    func testMenuBarStatusItemRendererAlignsIconAndTextBlockCenters() {
        let renderer = MenuBarStatusItemRenderer()
        let appearance = NSAppearance(named: .aqua)!
        let result = renderer.render(
            presentation: DesktopAppModel.MenuBarTokenUsagePresentation(
                primaryLine: "In 542.7k",
                secondaryLine: "Out 8.4k",
                toolTip: "",
                accessibilityLabel: ""
            ),
            symbolName: "bolt.horizontal.circle.fill",
            appearance: appearance,
            foregroundColor: .white,
            isHighlighted: false,
            scale: 2
        )
        XCTAssertEqual(result.primaryTextFrame.minX, result.secondaryTextFrame.minX, accuracy: 0.5)
        XCTAssertEqual(result.iconFrame.midY, result.textBlockFrame.midY, accuracy: 1.0)
    }

    @MainActor
    func testMenuBarStatusItemRendererExpandsForLongerTokenText() {
        let renderer = MenuBarStatusItemRenderer()
        let appearance = NSAppearance(named: .aqua)!
        let shortResult = renderer.render(
            presentation: DesktopAppModel.MenuBarTokenUsagePresentation(
                primaryLine: "In 1",
                secondaryLine: "Out 2",
                toolTip: "",
                accessibilityLabel: ""
            ),
            symbolName: "bolt.horizontal.circle.fill",
            appearance: appearance,
            foregroundColor: .white,
            isHighlighted: false,
            scale: 2
        )
        let longResult = renderer.render(
            presentation: DesktopAppModel.MenuBarTokenUsagePresentation(
                primaryLine: "In 542.7k",
                secondaryLine: "Out 8.4k",
                toolTip: "",
                accessibilityLabel: ""
            ),
            symbolName: "bolt.horizontal.circle.fill",
            appearance: appearance,
            foregroundColor: .white,
            isHighlighted: false,
            scale: 2
        )
        XCTAssertGreaterThan(longResult.image.size.width, shortResult.image.size.width)
    }

    @MainActor
    func testMenuBarStatusItemRendererVisibleContentRectTracksRenderedText() {
        let renderer = MenuBarStatusItemRenderer()
        let appearance = NSAppearance(named: .aqua)!
        let shortResult = renderer.render(
            presentation: DesktopAppModel.MenuBarTokenUsagePresentation(
                primaryLine: "In 12",
                secondaryLine: "Out 34",
                toolTip: "",
                accessibilityLabel: ""
            ),
            symbolName: "bolt.horizontal.circle.fill",
            appearance: appearance,
            foregroundColor: .white,
            isHighlighted: false,
            scale: 2
        )
        let longResult = renderer.render(
            presentation: DesktopAppModel.MenuBarTokenUsagePresentation(
                primaryLine: "In 542.7k",
                secondaryLine: "Out 8.4k",
                toolTip: "",
                accessibilityLabel: ""
            ),
            symbolName: "bolt.horizontal.circle.fill",
            appearance: appearance,
            foregroundColor: .white,
            isHighlighted: false,
            scale: 2
        )
        XCTAssertTrue(NSRect(origin: .zero, size: shortResult.image.size).contains(shortResult.visibleContentRect))
        XCTAssertTrue(NSRect(origin: .zero, size: longResult.image.size).contains(longResult.visibleContentRect))
        XCTAssertLessThan(shortResult.visibleContentRect.width, longResult.visibleContentRect.width)
    }

    @MainActor
    func testMenuBarStatusItemRendererIconOnlyUsesSquareCanvasAndCenteredIcon() {
        let renderer = MenuBarStatusItemRenderer()
        let appearance = NSAppearance(named: .darkAqua)!
        let sideLength: CGFloat = 22
        let result = renderer.renderIconOnly(
            symbolName: "bolt.horizontal.circle.fill",
            appearance: appearance,
            foregroundColor: .white,
            isHighlighted: false,
            scale: 2,
            sideLength: sideLength
        )

        XCTAssertEqual(result.image.size.width, ceil(sideLength), accuracy: 0.5)
        XCTAssertEqual(result.image.size.height, ceil(sideLength), accuracy: 0.5)
        XCTAssertEqual(result.iconFrame.width, 18, accuracy: 0.5)
        XCTAssertEqual(result.iconFrame.height, 18, accuracy: 0.5)
        XCTAssertEqual(result.iconFrame.midX, result.image.size.width / 2, accuracy: 1.0)
        XCTAssertEqual(result.iconFrame.midY, result.image.size.height / 2, accuracy: 1.0)
        XCTAssertTrue(NSRect(origin: .zero, size: result.image.size).contains(result.visibleContentRect))
        XCTAssertEqual(result.primaryTextFrame, .zero)
        XCTAssertEqual(result.secondaryTextFrame, .zero)
    }

    @MainActor
    func testMenuBarStatusItemRendererUsesExplicitForegroundColorAcrossAppearances() {
        let renderer = MenuBarStatusItemRenderer()
        let foregroundColor = NSColor.white

        let tokenLightResult = renderer.render(
            presentation: DesktopAppModel.MenuBarTokenUsagePresentation(
                primaryLine: "In 542.7k",
                secondaryLine: "Out 8.4k",
                toolTip: "",
                accessibilityLabel: ""
            ),
            symbolName: "bolt.horizontal.circle.fill",
            appearance: NSAppearance(named: .aqua)!,
            foregroundColor: foregroundColor,
            isHighlighted: false,
            scale: 2
        )
        let tokenDarkResult = renderer.render(
            presentation: DesktopAppModel.MenuBarTokenUsagePresentation(
                primaryLine: "In 542.7k",
                secondaryLine: "Out 8.4k",
                toolTip: "",
                accessibilityLabel: ""
            ),
            symbolName: "bolt.horizontal.circle.fill",
            appearance: NSAppearance(named: .darkAqua)!,
            foregroundColor: foregroundColor,
            isHighlighted: false,
            scale: 2
        )
        let iconLightResult = renderer.renderIconOnly(
            symbolName: "bolt.horizontal.circle.fill",
            appearance: NSAppearance(named: .aqua)!,
            foregroundColor: foregroundColor,
            isHighlighted: false,
            scale: 2,
            sideLength: 22
        )
        let iconDarkResult = renderer.renderIconOnly(
            symbolName: "bolt.horizontal.circle.fill",
            appearance: NSAppearance(named: .darkAqua)!,
            foregroundColor: foregroundColor,
            isHighlighted: false,
            scale: 2,
            sideLength: 22
        )

        XCTAssertEqual(self.bitmapData(for: tokenLightResult.image), self.bitmapData(for: tokenDarkResult.image))
        XCTAssertEqual(self.bitmapData(for: iconLightResult.image), self.bitmapData(for: iconDarkResult.image))
    }

    @MainActor
    func testMenuBarPanelLocalizationFollowsCurrentLanguageWithoutRecreatingModel() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let panel = MenuBarPanel(model: model)

        XCTAssertTrue(panel.actionTitles.contains("Open Minimal Mode"))
        XCTAssertTrue(panel.actionTitles.contains("Detailed Logs"))

        model.preferences.languageMode = .zhHans

        XCTAssertTrue(panel.actionTitles.contains("打开极简模式"))
        XCTAssertTrue(panel.actionTitles.contains("查看详细日志"))
    }

    @MainActor
    func testRequestLogContextMenuLocalizationFollowsCurrentLanguageWithoutRecreatingModel() {
        let entry = RequestLogEntry(
            id: 1,
            timestamp: 1_776_052_953,
            endpoint: "/v1/responses",
            upstreamURL: "https://api.deepseek.com/responses",
            model: "gpt-5",
            actualModel: "gpt-5-high",
            reasoningEffort: "xhigh",
            apiKey: "sk-local",
            accountKey: "acct",
            accountLabel: "OAuth",
            success: false,
            latencyMS: 320,
            inputTokens: 16,
            outputTokens: 42,
            totalTokens: 58,
            cacheHitTokens: 8,
            failureCategory: "gateway",
            errorSummary: "Gateway timeout"
        )
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let contextMenu = RequestLogContextMenuContent(model: model, entry: entry)

        XCTAssertTrue(contextMenu.actionTitles.contains("Copy Time"))
        XCTAssertTrue(contextMenu.actionTitles.contains("Copy Upstream URL"))
        XCTAssertTrue(contextMenu.actionTitles.contains("Copy Reasoning Effort"))
        XCTAssertTrue(contextMenu.actionTitles.contains("Copy Error Summary"))
        XCTAssertTrue(contextMenu.actionTitles.contains("Copy Row CSV"))

        model.preferences.languageMode = .zhHans

        XCTAssertTrue(contextMenu.actionTitles.contains("复制时间"))
        XCTAssertTrue(contextMenu.actionTitles.contains("复制上游地址"))
        XCTAssertTrue(contextMenu.actionTitles.contains("复制思维等级"))
        XCTAssertTrue(contextMenu.actionTitles.contains("复制错误摘要"))
        XCTAssertTrue(contextMenu.actionTitles.contains("复制 CSV 行"))
    }

    @MainActor
    func testDesktopPreferencesDefaultToMinimalModeForNewInstall() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        XCTAssertEqual(model.preferences.interfaceMode, .minimal)
        XCTAssertEqual(model.preferences.accountPoolDisplayMode, .cards)
        XCTAssertTrue(model.preferences.showsMenuBarTokenUsage)
    }

    @MainActor
    func testDesktopPreferencesMissingInterfaceModeDefaultsToFullForExistingInstall() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyPreferences = """
        {
          "languageMode" : "system",
          "themeMode" : "system",
          "hasSeenHelpWindow" : true,
          "hasAutoPresentedOnboardingAfterHelp" : false
        }
        """
        try legacyPreferences.data(using: .utf8)?.write(to: Paths.desktopPreferencesURL(in: directory))

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        XCTAssertEqual(model.preferences.interfaceMode, .full)
        XCTAssertEqual(model.preferences.accountPoolDisplayMode, .cards)
        XCTAssertTrue(model.preferences.showsMenuBarTokenUsage)
        XCTAssertTrue(model.preferences.hasSeenHelpWindow)
    }

    @MainActor
    func testDesktopPreferencesRoundTripSavedInterfaceMode() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        XCTAssertEqual(model.preferences.interfaceMode, .full)
    }

    @MainActor
    func testDesktopPreferencesRoundTripSavedAccountPoolDisplayMode() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try preferencesStore.save(DesktopPreferences(accountPoolDisplayMode: .list))

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        XCTAssertEqual(model.preferences.accountPoolDisplayMode, .list)
    }

    @MainActor
    func testDesktopPreferencesRoundTripSavedMenuBarTokenUsageVisibility() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try preferencesStore.save(DesktopPreferences(showsMenuBarTokenUsage: false))

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        XCTAssertFalse(model.preferences.showsMenuBarTokenUsage)
    }

    @MainActor
    func testPresentHelpWindowIfNeededMarksPreferenceAndShowsPresenter() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let presenter = HelpWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in presenter }
        )

        XCTAssertTrue(model.shouldAutoPresentHelpWindow)

        model.presentHelpWindowIfNeededOnFirstLaunch()

        XCTAssertTrue(model.isHelpPresented)
        XCTAssertEqual(presenter.showWindowCallCount, 1)
        XCTAssertTrue(preferencesStore.load().hasSeenHelpWindow)
        XCTAssertFalse(model.shouldAutoPresentHelpWindow)
    }

    @MainActor
    func testManualHelpButtonStillShowsWindowAfterPreferenceAlreadySeen() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try preferencesStore.save(DesktopPreferences(hasSeenHelpWindow: true))

        let presenter = HelpWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in presenter }
        )

        XCTAssertFalse(model.shouldAutoPresentHelpWindow)

        model.openHelpWindow()

        XCTAssertTrue(model.isHelpPresented)
        XCTAssertEqual(presenter.showWindowCallCount, 1)
        XCTAssertTrue(preferencesStore.load().hasSeenHelpWindow)
    }

    @MainActor
    func testUpdatingLanguageRefreshesHelpWindowPresenter() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let presenter = HelpWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in presenter }
        )

        model.openHelpWindow()
        presenter.reset()

        model.updateLanguage(.zhHans)

        XCTAssertEqual(presenter.refreshWindowCallCount, 1)
        XCTAssertEqual(model.helpWindowTitle, "使用帮助")
    }

    @MainActor
    func testDismissHelpWindowUpdatesStateAndPresenter() {
        let presenter = HelpWindowControllerSpy()
        let model = DesktopAppModel(helpWindowFactory: { _ in presenter })

        model.openHelpWindow()
        presenter.reset()

        model.dismissHelpWindow()

        XCTAssertFalse(model.isHelpPresented)
        XCTAssertEqual(presenter.closeWindowCallCount, 1)
    }

    @MainActor
    func testDismissHelpWindowAutoPresentsOnboardingWhenAccountsAreEmpty() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let helpPresenter = HelpWindowControllerSpy()
        let onboardingPresenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in helpPresenter },
            onboardingWindowFactory: { _ in onboardingPresenter }
        )

        model.openHelpWindow()
        helpPresenter.reset()

        model.dismissHelpWindow()

        XCTAssertFalse(model.isHelpPresented)
        XCTAssertTrue(model.isOnboardingPresented)
        XCTAssertEqual(helpPresenter.closeWindowCallCount, 1)
        XCTAssertEqual(onboardingPresenter.showWindowCallCount, 1)
        XCTAssertTrue(preferencesStore.load().hasAutoPresentedOnboardingAfterHelp)
    }

    @MainActor
    func testDismissHelpWindowDoesNotAutoPresentOnboardingInMinimalMode() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let helpPresenter = HelpWindowControllerSpy()
        let onboardingPresenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in helpPresenter },
            onboardingWindowFactory: { _ in onboardingPresenter }
        )

        model.openHelpWindow()
        helpPresenter.reset()

        model.dismissHelpWindow()

        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertEqual(onboardingPresenter.showWindowCallCount, 0)
        XCTAssertFalse(preferencesStore.load().hasAutoPresentedOnboardingAfterHelp)
    }

    @MainActor
    func testDismissHelpWindowDoesNotAutoPresentOnboardingWhenAccountsExist() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let helpPresenter = HelpWindowControllerSpy()
        let onboardingPresenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in helpPresenter },
            onboardingWindowFactory: { _ in onboardingPresenter }
        )
        model.accounts = [
            Self.makeAccount(id: "account-1", label: "Primary", accountID: "acct-1"),
        ]

        model.openHelpWindow()
        helpPresenter.reset()

        model.dismissHelpWindow()

        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertEqual(onboardingPresenter.showWindowCallCount, 0)
        XCTAssertFalse(preferencesStore.load().hasAutoPresentedOnboardingAfterHelp)
    }

    @MainActor
    func testHelpDismissAutoOnboardingOnlyRunsOnce() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let helpPresenter = HelpWindowControllerSpy()
        let onboardingPresenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in helpPresenter },
            onboardingWindowFactory: { _ in onboardingPresenter }
        )

        model.openHelpWindow()
        model.dismissHelpWindow()
        XCTAssertTrue(model.isOnboardingPresented)
        XCTAssertEqual(onboardingPresenter.showWindowCallCount, 1)

        model.dismissOnboarding()
        model.openHelpWindow()
        model.dismissHelpWindow()

        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertEqual(onboardingPresenter.showWindowCallCount, 1)
        XCTAssertTrue(preferencesStore.load().hasAutoPresentedOnboardingAfterHelp)
    }

    @MainActor
    func testHelpActionsDeepLinkToOnboardingAndProxyConfiguration() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let helpPresenter = HelpWindowControllerSpy()
        let onboardingPresenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            helpWindowFactory: { _ in helpPresenter },
            onboardingWindowFactory: { _ in onboardingPresenter }
        )

        model.openHelpWindow()
        model.openHelpAction(.settingsProxy)
        XCTAssertEqual(model.selectedPage, .settings)
        XCTAssertEqual(model.selectedSettingsTab, .proxy)

        model.openHelpAction(.proxyAccess)
        XCTAssertEqual(model.selectedPage, .proxy)
        XCTAssertEqual(model.selectedProxyWorkspaceTab, .access)

        model.openHelpWindow()
        model.openHelpAction(.onboarding)
        XCTAssertFalse(model.isHelpPresented)
        XCTAssertTrue(model.isOnboardingPresented)
        XCTAssertEqual(onboardingPresenter.showWindowCallCount, 1)
    }

    @MainActor
    func testOpenSettingsAppearancePageSelectsAppearanceTabAndSettingsDashboard() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let model = DesktopAppModel(preferencesStore: preferencesStore)
        model.selectedPage = .proxy
        model.selectedSettingsTab = .service

        model.openSettingsAppearancePage()

        XCTAssertEqual(model.selectedPage, .settings)
        XCTAssertEqual(model.selectedSettingsTab, .appearance)
    }

    @MainActor
    func testRemoteManagementStaysHiddenUntilThreeConsecutiveBrandTaps() {
        let model = DesktopAppModel()

        XCTAssertFalse(model.isRemoteManagementUnlocked)
        XCTAssertFalse(model.visiblePages.contains(.remote))

        let start = Date(timeIntervalSinceReferenceDate: 100)
        model.registerRemoteManagementRevealTap(now: start)
        model.registerRemoteManagementRevealTap(now: start.addingTimeInterval(0.4))

        XCTAssertFalse(model.isRemoteManagementUnlocked)
        XCTAssertFalse(model.visiblePages.contains(.remote))

        model.registerRemoteManagementRevealTap(now: start.addingTimeInterval(0.8))

        XCTAssertTrue(model.isRemoteManagementUnlocked)
        XCTAssertTrue(model.visiblePages.contains(.remote))
    }

    @MainActor
    func testRemoteManagementRevealSequenceResetsAfterTimeout() {
        let model = DesktopAppModel()
        let start = Date(timeIntervalSinceReferenceDate: 200)

        model.registerRemoteManagementRevealTap(now: start)
        model.registerRemoteManagementRevealTap(now: start.addingTimeInterval(1.8))
        model.registerRemoteManagementRevealTap(now: start.addingTimeInterval(2.1))

        XCTAssertFalse(model.isRemoteManagementUnlocked)

        model.registerRemoteManagementRevealTap(now: start.addingTimeInterval(2.4))

        XCTAssertTrue(model.isRemoteManagementUnlocked)
    }

    @MainActor
    func testOpenDashboardIgnoresRemotePageUntilUnlocked() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        model.openDashboard(.remote)
        XCTAssertEqual(model.selectedPage, .overview)

        Self.unlockRemoteManagement(on: model)
        model.openDashboard(.remote)

        XCTAssertEqual(model.selectedPage, .remote)
    }

    @MainActor
    func testDisplayedSelectedPageFallsBackToOverviewUntilRemoteManagementUnlocks() {
        let model = DesktopAppModel()
        model.selectedPage = .remote

        XCTAssertEqual(model.displayedSelectedPage, .overview)

        Self.unlockRemoteManagement(on: model)

        XCTAssertEqual(model.selectedPage, .overview)
        XCTAssertEqual(model.displayedSelectedPage, .overview)
    }

    @MainActor
    func testSaveSelectedRemoteHostAndContinuePersistsHostAndMovesToVerification() async {
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.testConnectionHandler = { host in
            try await Task.sleep(for: .seconds(1))
            return Self.makeRemoteConnectionCheck(hostID: host.id)
        }
        let model = Self.makeRemoteModel(remoteDeploy: remoteDeploy)

        model.createNewRemoteHost()
        model.selectedRemoteHost.label = "Tokyo"
        model.selectedRemoteHost.host = "tokyo.example.com"

        await model.saveSelectedRemoteHostAndContinue()

        XCTAssertEqual(model.settings.remoteHosts.count, 1)
        XCTAssertEqual(model.settings.remoteHosts.first?.label, "Tokyo")
        XCTAssertEqual(model.selectedRemoteWorkflowStep, .verification)
        XCTAssertEqual(model.selectedRemoteHost.host, "tokyo.example.com")

        model.selectedRemoteWorkflowStep = .configuration
    }

    @MainActor
    func testEditingSavedRemoteHostInvalidatesConnectionCheckAndRetreatsToConfiguration() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(hostID: host.id, host: host.host, publicPort: host.publicPort)
        model.remoteLogsByHostID[host.id] = "logs"
        model.selectedRemoteWorkflowStep = .verification

        model.selectedRemoteHost.host = "new-tokyo.example.com"

        XCTAssertNil(model.remoteConnectionChecksByHostID[host.id])
        XCTAssertNil(model.remoteConnectionErrorsByHostID[host.id])
        XCTAssertNil(model.remoteStatuses[host.id])
        XCTAssertNil(model.remoteServiceLoadErrors[host.id])
        XCTAssertNil(model.remoteLogsByHostID[host.id])
        XCTAssertEqual(model.selectedRemoteWorkflowStep, .configuration)
    }

    @MainActor
    func testRemovingSelectedRemoteHostClearsTransientStateAndSelectsRemainingHost() async {
        let first = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let second = Self.makeRemoteHost(id: "host-2", label: "Seoul", host: "seoul.example.com")
        let model = Self.makeRemoteModel(
            settings: AppConfig(remoteHosts: [first, second]),
            confirmDeleteRemoteHostHandler: { _ in true }
        )
        model.selectedRemoteHost = first
        model.remoteConnectionChecksByHostID[first.id] = Self.makeRemoteConnectionCheck(hostID: first.id)
        model.remoteStatuses[first.id] = Self.makeRemoteDeployStatus(hostID: first.id, host: first.host, publicPort: first.publicPort)
        model.remoteLogsByHostID[first.id] = "first logs"

        await model.removeSelectedRemoteHost()

        XCTAssertEqual(model.settings.remoteHosts.map(\.id), [second.id])
        XCTAssertEqual(model.selectedRemoteHost.id, second.id)
        XCTAssertNil(model.remoteConnectionChecksByHostID[first.id])
        XCTAssertNil(model.remoteStatuses[first.id])
        XCTAssertNil(model.remoteLogsByHostID[first.id])
        XCTAssertEqual(model.selectedRemoteWorkflowStep, .hosts)
    }

    @MainActor
    func testRemoteTransientStateStaysScopedToSelectedHost() {
        let first = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let second = Self.makeRemoteHost(id: "host-2", label: "Seoul", host: "seoul.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [first, second]))
        let firstCheck = Self.makeRemoteConnectionCheck(hostID: first.id, architecture: "arm64")
        let secondCheck = Self.makeRemoteConnectionCheck(hostID: second.id, architecture: "x86_64")
        model.remoteConnectionChecksByHostID[first.id] = firstCheck
        model.remoteConnectionChecksByHostID[second.id] = secondCheck
        model.remoteLogsByHostID[first.id] = "tokyo logs"
        model.remoteLogsByHostID[second.id] = "seoul logs"

        model.selectRemoteHost(id: first.id)
        XCTAssertEqual(model.selectedRemoteConnectionCheck, firstCheck)
        XCTAssertEqual(model.currentRemoteLogs, "tokyo logs")

        model.selectRemoteHost(id: second.id)
        XCTAssertEqual(model.selectedRemoteConnectionCheck, secondCheck)
        XCTAssertEqual(model.currentRemoteLogs, "seoul logs")
    }

    @MainActor
    func testSelectingSavedRemoteHostMovesWorkflowToConfiguration() {
        let first = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let second = Self.makeRemoteHost(id: "host-2", label: "Seoul", host: "seoul.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [first, second]))

        XCTAssertEqual(model.selectedRemoteWorkflowStep, .hosts)

        model.selectRemoteHost(id: second.id)

        XCTAssertEqual(model.selectedRemoteHost.id, second.id)
        XCTAssertEqual(model.selectedRemoteWorkflowStep, .configuration)
    }

    @MainActor
    func testEnteringVerificationAutomaticallyTestsConnectionAndAdvancesToOperations() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.testConnectionHandler = { host in
            Self.makeRemoteConnectionCheck(hostID: host.id, architecture: "arm64")
        }
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(
                hostID: host.id,
                host: host.host,
                publicPort: host.publicPort,
                running: true
            )
        }
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)

        model.selectRemoteHost(id: host.id)
        model.selectRemoteWorkflowStep(.verification)

        await Self.waitForCondition {
            model.selectedRemoteWorkflowStep == .operations &&
                remoteDeploy.testConnectionCalls.count == 1 &&
                remoteDeploy.statusCalls.count == 1
        }

        XCTAssertEqual(model.remoteConnectionChecksByHostID[host.id]?.hostID, host.id)
        XCTAssertEqual(model.remoteStatuses[host.id]?.hostID, host.id)
        XCTAssertTrue(model.remoteStatuses[host.id]?.running == true)
    }

    @MainActor
    func testEnteringOperationsAutomaticallyRefreshesRemoteStatus() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(
                hostID: host.id,
                host: host.host,
                publicPort: host.publicPort,
                running: true
            )
        }
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)

        model.selectRemoteHost(id: host.id)
        model.selectRemoteWorkflowStep(.operations)

        await Self.waitForCondition {
            remoteDeploy.statusCalls.count == 1 &&
                model.remoteStatuses[host.id]?.running == true
        }

        XCTAssertEqual(model.selectedRemoteWorkflowStep, .operations)
        XCTAssertEqual(remoteDeploy.statusCalls.map(\.id), [host.id])
    }

    @MainActor
    func testAutomaticRemoteVerificationFailureStaysOnVerificationAndDoesNotRefreshStatus() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.testConnectionHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)

        model.selectRemoteHost(id: host.id)
        model.selectRemoteWorkflowStep(.verification)

        await Self.waitForCondition {
            model.remoteConnectionErrorsByHostID[host.id]?.isEmpty == false
        }

        XCTAssertEqual(model.selectedRemoteWorkflowStep, .verification)
        XCTAssertEqual(remoteDeploy.testConnectionCalls.count, 1)
        XCTAssertTrue(remoteDeploy.statusCalls.isEmpty)
    }

    @MainActor
    func testRemoteWorkflowAutomationDoesNotRepeatForSameStepSelectionOrSync() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.testConnectionHandler = { host in
            Self.makeRemoteConnectionCheck(hostID: host.id, architecture: "arm64")
        }
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(
                hostID: host.id,
                host: host.host,
                publicPort: host.publicPort,
                running: true
            )
        }
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)

        model.selectRemoteHost(id: host.id)
        model.selectRemoteWorkflowStep(.verification)

        await Self.waitForCondition {
            model.selectedRemoteWorkflowStep == .operations &&
                remoteDeploy.testConnectionCalls.count == 1 &&
                remoteDeploy.statusCalls.count == 1
        }

        model.selectRemoteWorkflowStep(.operations)
        model.syncSelectedRemoteHost(suppressSideEffects: true)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(remoteDeploy.testConnectionCalls.count, 1)
        XCTAssertEqual(remoteDeploy.statusCalls.count, 1)
    }

    @MainActor
    func testRemoteOperationsUnlockOnlyAfterSuccessfulConnectionTest() async throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.testConnectionHandler = { host in
            Self.makeRemoteConnectionCheck(hostID: host.id, architecture: "arm64")
        }
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)

        XCTAssertFalse(model.canEnterRemoteWorkflowStep(.operations))

        await model.testSelectedRemoteConnection()

        XCTAssertEqual(remoteDeploy.testConnectionCalls.map(\.id), [host.id])
        XCTAssertEqual(model.remoteConnectionChecksByHostID[host.id]?.hostID, host.id)
        XCTAssertTrue(model.canEnterRemoteWorkflowStep(.operations))
        XCTAssertEqual(model.remoteWorkflowStepStatusText(.verification), model.text(.statusReady))
    }

    @MainActor
    func testRemoteOperationsUnlockWhenBundledArtifactsAreMissingButRuntimeChecksPass() async throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.testConnectionHandler = { host in
            Self.makeRemoteConnectionCheck(hostID: host.id, architecture: "arm64", localArtifactAvailable: false)
        }
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)

        XCTAssertFalse(model.canEnterRemoteWorkflowStep(.operations))

        await model.testSelectedRemoteConnection()

        XCTAssertTrue(model.canEnterRemoteWorkflowStep(.operations))
        XCTAssertTrue(model.canManageRemoteHostOperations(for: host.id))
        XCTAssertFalse(model.canDeployRemoteHost(for: host.id))
        XCTAssertEqual(model.remoteWorkflowStepStatusText(.verification), model.text(.statusReady))
        XCTAssertEqual(model.remoteWorkflowStepTone(.verification), .success)
        XCTAssertNotNil(model.remoteDeployDisabledMessage(for: host.id))
    }

    @MainActor
    func testDeploySelectedRemoteDoesNotRunWhenBundledArtifactsAreMissing() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(
            hostID: host.id,
            localArtifactAvailable: false
        )

        await model.deploySelectedRemote()

        XCTAssertTrue(model.canManageRemoteHostOperations(for: host.id))
        XCTAssertFalse(model.canDeployRemoteHost(for: host.id))
        XCTAssertTrue(remoteDeploy.deployCalls.isEmpty)
        XCTAssertNil(model.remoteStatuses[host.id])
    }

    @MainActor
    func testRemoteDeployButtonDefaultsToDeployWhenStatusHasNotLoaded() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)

        XCTAssertEqual(model.remoteDeployActionMode(for: host.id), .deploy)
        XCTAssertEqual(model.remoteDeployButtonTitle(for: host.id), model.text(.actionDeploy))
        XCTAssertEqual(model.remoteDeployButtonHelpText(for: host.id), model.remoteWorkflowStepSubtitle(.operations))
    }

    @MainActor
    func testRemoteDeployButtonSwitchesToRedeployForInstalledHost() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            installed: true
        )

        XCTAssertEqual(model.remoteDeployActionMode(for: host.id), .redeploy)
        XCTAssertEqual(model.remoteDeployButtonTitle(for: host.id), model.text(.actionRedeploy))
        XCTAssertEqual(model.remoteDeployButtonHelpText(for: host.id), model.text(.helperRemoteRedeploy))
    }

    @MainActor
    func testRemoteDeployButtonStaysDeployForNotInstalledHost() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            installed: false
        )

        XCTAssertEqual(model.remoteDeployActionMode(for: host.id), .deploy)
        XCTAssertEqual(model.remoteDeployButtonTitle(for: host.id), model.text(.actionDeploy))
    }

    @MainActor
    func testRemoteRedeployButtonRemainsDisabledWithoutBundledArtifacts() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            installed: true
        )
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(
            hostID: host.id,
            localArtifactAvailable: false
        )

        XCTAssertEqual(model.remoteDeployActionMode(for: host.id), .redeploy)
        XCTAssertEqual(model.remoteDeployButtonTitle(for: host.id), model.text(.actionRedeploy))
        XCTAssertFalse(model.canDeployRemoteHost(for: host.id))
        XCTAssertEqual(model.remoteDeployButtonHelpText(for: host.id), model.text(.helperRemoteDeployUnavailable))
    }

    @MainActor
    func testRemoteRedeployUsesExistingDeployPipeline() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            installed: true
        )
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)

        await model.deploySelectedRemote()

        XCTAssertEqual(model.remoteDeployActionMode(for: host.id), .redeploy)
        XCTAssertEqual(remoteDeploy.deployCalls.map(\.id), [host.id])
    }

    @MainActor
    func testRemoteRedeployButtonShowsRedeployingWhileOperationIsRunning() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            installed: true
        )
        model.remoteOperation = .deploying(hostID: host.id)

        XCTAssertEqual(model.remoteDeployButtonTitle(for: host.id), model.text(.statusRedeploying))
    }

    @MainActor
    func testRemoteManagementRemainsAvailableWhenBundledArtifactsAreMissing() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(
                hostID: host.id,
                host: host.host,
                publicPort: host.publicPort,
                running: true
            )
        }
        remoteDeploy.logsHandler = { _, _ in
            "journal excerpt"
        }
        var createdSpy: RemoteAdminWindowControllerSpy?
        let model = Self.makeRemoteModel(
            settings: AppConfig(remoteHosts: [host]),
            remoteDeploy: remoteDeploy,
            remoteAdminWindowFactory: { host, _, _, onClose, _ in
                let spy = RemoteAdminWindowControllerSpy(hostID: host.id, onClose: onClose)
                createdSpy = spy
                return spy
            }
        )
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(
            hostID: host.id,
            localArtifactAvailable: false
        )

        await model.refreshSelectedRemote()
        await model.loadSelectedRemoteLogs()

        XCTAssertEqual(remoteDeploy.statusCalls.map(\.id), [host.id])
        XCTAssertEqual(remoteDeploy.logsCalls.map(\.host.id), [host.id])
        XCTAssertEqual(model.remoteStatuses[host.id]?.running, true)
        XCTAssertEqual(model.remoteLogsByHostID[host.id], "journal excerpt")
        XCTAssertTrue(model.canOpenRemoteAdminWindow(for: host.id))

        model.openSelectedRemoteAdminWindow()
        XCTAssertEqual(createdSpy?.showWindowCallCount, 1)
    }

    @MainActor
    func testRemoteOperationsStayLockedWhenRuntimeChecksFail() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))

        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(
            hostID: host.id,
            systemctlAvailable: false,
            localArtifactAvailable: false
        )
        XCTAssertFalse(model.canEnterRemoteWorkflowStep(.operations))

        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(
            hostID: host.id,
            sudoAvailable: false,
            localArtifactAvailable: false
        )
        XCTAssertFalse(model.canEnterRemoteWorkflowStep(.operations))

        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(
            hostID: host.id,
            remoteDirectoryWritable: false,
            localArtifactAvailable: false
        )
        XCTAssertFalse(model.canEnterRemoteWorkflowStep(.operations))
    }

    @MainActor
    func testRemoteAdminWindowRequiresVerifiedRunningRemoteService() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        var createdSpy: RemoteAdminWindowControllerSpy?
        let model = Self.makeRemoteModel(
            settings: AppConfig(remoteHosts: [host]),
            remoteAdminWindowFactory: { host, _, _, onClose, _ in
                let spy = RemoteAdminWindowControllerSpy(hostID: host.id, onClose: onClose)
                createdSpy = spy
                return spy
            }
        )

        XCTAssertFalse(model.canOpenRemoteAdminWindow(for: host.id))

        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        XCTAssertFalse(model.canOpenRemoteAdminWindow(for: host.id))

        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            running: false
        )
        XCTAssertFalse(model.canOpenRemoteAdminWindow(for: host.id))

        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            running: true
        )
        XCTAssertTrue(model.canOpenRemoteAdminWindow(for: host.id))

        model.openSelectedRemoteAdminWindow()
        XCTAssertEqual(createdSpy?.showWindowCallCount, 1)

        model.openSelectedRemoteAdminWindow()
        XCTAssertEqual(createdSpy?.showWindowCallCount, 2)
        XCTAssertEqual(createdSpy?.refreshWindowCallCount, 1)
    }

    @MainActor
    func testEditingSavedRemoteHostClosesRemoteAdminWindow() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        var createdSpy: RemoteAdminWindowControllerSpy?
        let model = Self.makeRemoteModel(
            settings: AppConfig(remoteHosts: [host]),
            remoteAdminWindowFactory: { host, _, _, onClose, _ in
                let spy = RemoteAdminWindowControllerSpy(hostID: host.id, onClose: onClose)
                createdSpy = spy
                return spy
            }
        )
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            running: true
        )

        model.openSelectedRemoteAdminWindow()
        XCTAssertEqual(createdSpy?.showWindowCallCount, 1)

        var edited = model.selectedRemoteHost
        edited.adminPort = 8899
        model.selectedRemoteHost = edited

        XCTAssertEqual(createdSpy?.closeWindowCallCount, 1)
        await Self.waitForCondition {
            model.remoteAdminWindowControllers[host.id] == nil
        }
    }

    @MainActor
    func testSyncRemoteAdminDiscoveredPortPersistsWithoutClosingOpenWindow() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com", adminPort: 8788)
        var createdSpy: RemoteAdminWindowControllerSpy?
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(
                hostID: host.id,
                host: host.host,
                publicPort: host.publicPort,
                running: true
            )
        }
        let model = Self.makeRemoteModel(
            settings: AppConfig(remoteHosts: [host]),
            remoteDeploy: remoteDeploy,
            remoteAdminWindowFactory: { host, _, _, onClose, _ in
                let spy = RemoteAdminWindowControllerSpy(hostID: host.id, onClose: onClose)
                createdSpy = spy
                return spy
            }
        )
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            running: true
        )
        model.remoteLogsByHostID[host.id] = "journal excerpt"
        model.selectedRemoteWorkflowStep = .operations

        model.openSelectedRemoteAdminWindow()
        let result = await model.syncRemoteAdminDiscoveredPort(hostID: host.id, adminPort: 9911)

        XCTAssertEqual(result, .synced(adminPort: 9911))
        XCTAssertEqual(model.settings.remoteHosts.first?.adminPort, 9911)
        XCTAssertEqual(model.selectedRemoteHost.adminPort, 9911)
        XCTAssertEqual(createdSpy?.closeWindowCallCount, 0)
        XCTAssertNotNil(model.remoteAdminWindowControllers[host.id])
        XCTAssertEqual(model.remoteStatuses[host.id]?.running, true)
        XCTAssertEqual(model.remoteLogsByHostID[host.id], "journal excerpt")
        XCTAssertNotNil(model.remoteConnectionChecksByHostID[host.id])
        XCTAssertEqual(model.selectedRemoteWorkflowStep, .operations)
    }

    @MainActor
    func testSyncRemoteAdminDiscoveredPortFailureKeepsWindowOpenAndLeavesSavedPortUntouched() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com", adminPort: 8788)
        var createdSpy: RemoteAdminWindowControllerSpy?
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            saveSettingsHandler: { _ in throw ProxyError.message("disk full") },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let model = Self.makeRemoteModel(
            settings: AppConfig(remoteHosts: [host]),
            admin: admin,
            remoteAdminWindowFactory: { host, _, _, onClose, _ in
                let spy = RemoteAdminWindowControllerSpy(hostID: host.id, onClose: onClose)
                createdSpy = spy
                return spy
            }
        )
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            running: true
        )

        model.openSelectedRemoteAdminWindow()
        let result = await model.syncRemoteAdminDiscoveredPort(hostID: host.id, adminPort: 9911)

        XCTAssertEqual(result, .failed("disk full"))
        XCTAssertEqual(model.settings.remoteHosts.first?.adminPort, 8788)
        XCTAssertEqual(model.selectedRemoteHost.adminPort, 8788)
        XCTAssertEqual(createdSpy?.closeWindowCallCount, 0)
        XCTAssertNotNil(model.remoteAdminWindowControllers[host.id])
    }

    @MainActor
    func testDeletingSavedRemoteHostClosesRemoteAdminWindow() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        var createdSpy: RemoteAdminWindowControllerSpy?
        let model = Self.makeRemoteModel(
            settings: AppConfig(remoteHosts: [host]),
            confirmDeleteRemoteHostHandler: { _ in true },
            remoteAdminWindowFactory: { host, _, _, onClose, _ in
                let spy = RemoteAdminWindowControllerSpy(hostID: host.id, onClose: onClose)
                createdSpy = spy
                return spy
            }
        )
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)
        model.remoteStatuses[host.id] = Self.makeRemoteDeployStatus(
            hostID: host.id,
            host: host.host,
            publicPort: host.publicPort,
            running: true
        )

        model.openSelectedRemoteAdminWindow()
        XCTAssertEqual(createdSpy?.showWindowCallCount, 1)

        await model.removeSelectedRemoteHost()

        XCTAssertEqual(createdSpy?.closeWindowCallCount, 1)
        await Self.waitForCondition {
            model.remoteAdminWindowControllers[host.id] == nil
        }
    }

    @MainActor
    func testAdminAPIClientRemoteTargetUsesInjectedTunnelURLAndToken() async throws {
        let capture = LockedRequestCapture()
        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.store(request)
            let data = try JSONEncoder().encode(Self.makeProxyStatus(running: true))
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session
        )

        _ = try await client.getStatus()
        let request = capture.snapshot()
        XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:9911/admin/status")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer remote-admin-token")
    }

    @MainActor
    func testAdminAPIClientRemoteTargetDoesNotFallbackWhenTunnelIsUnavailable() async throws {
        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { _ in
            throw URLError(.cannotConnectToHost)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session
        )

        do {
            _ = try await client.getStatus()
            XCTFail("Expected remote admin request to throw when the tunnel is unavailable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("http://127.0.0.1:9911/admin"))
            XCTAssertTrue(error.localizedDescription.contains("different admin port"))
        }
    }

    @MainActor
    func testAdminAPIClientRemoteTargetReconnectsAndReloadsTokenAfterUnauthorized() async throws {
        let probe = LockedRemoteAdminReconnectProbe(tokens: ["stale-token", "fresh-token"])
        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            let requestCount = probe.recordAuthorizationHeader(request.value(forHTTPHeaderField: "Authorization"))
            if requestCount == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "http://127.0.0.1")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let data = Data(#"{"error":{"message":"unauthorized"}}"#.utf8)
                return (response, data)
            }

            let data = try JSONEncoder().encode(Self.makeProxyStatus(running: true))
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { probe.nextToken() },
                    reconnectHandler: { probe.recordReconnect() },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session
        )

        let status = try await client.getStatus()
        let snapshot = probe.snapshot()

        XCTAssertTrue(status.running)
        XCTAssertEqual(snapshot.reconnectCount, 1)
        XCTAssertEqual(snapshot.requestCount, 2)
        XCTAssertEqual(snapshot.authorizationHeaders, ["Bearer stale-token", "Bearer fresh-token"])
    }

    @MainActor
    func testAdminAPIClientRemoteTunnelCapabilitiesEnableProxyTestingWithoutImportCurrent() {
        let capabilities = AdminAPIClient.Capabilities.remoteTunnel

        XCTAssertTrue(capabilities.supportsProxyTesting)
        XCTAssertFalse(capabilities.supportsImportCurrent)
        XCTAssertFalse(capabilities.supportsOAuth)
    }

    @MainActor
    func testAdminAPIClientRemoteTargetFetchesProxyTestModelsWhenCapabilityIsEnabled() async throws {
        let capture = LockedRequestCapture()
        let expectedCatalog = ProxyTestModelCatalog.defaultCatalog

        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.store(request)
            let data = try JSONEncoder().encode(expectedCatalog)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session
        )

        let catalog = try await client.getProxyTestModels()
        let request = capture.snapshot()

        XCTAssertEqual(catalog, expectedCatalog)
        XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:9911/admin/proxy-test/models")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer remote-admin-token")
    }

    @MainActor
    func testProxyTestConsoleRefreshPassesPinnedSelectedAccountKeyWhenLoadingModels() async throws {
        let capture = LockedRequestCapture()
        let expectedCatalog = ProxyTestModelCatalog.defaultCatalog

        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.store(request)
            let data = try JSONEncoder().encode(expectedCatalog)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session,
            getStatusHandler: {
                ProxyStatus(
                    running: true,
                    publicBaseURL: "http://0.0.0.0:8787/v1",
                    anthropicBaseURL: "http://0.0.0.0:8787",
                    geminiBaseURL: "http://0.0.0.0:8787",
                    adminBaseURL: "http://127.0.0.1:8788/admin",
                    apiKey: "sk-remote",
                    activeAccountKey: nil,
                    activeAccountID: nil,
                    activeAccountLabel: nil,
                    lastError: nil,
                    daemonVersion: "1.0.0 Beta版",
                    proxyTestAdminTransportMode: .full
                )
            }
        )
        let publicClient = ProxyPublicAPIClient(healthHandler: { _ in })
        let model = DesktopAppModel(admin: admin, publicProxyClient: publicClient)
        model.remoteAccessibleHostOverride = "tokyo.example.com"
        model.settings.proxyAPIKey = "sk-remote"
        model.accounts = [
            Self.makeAccount(
                id: "manual-account",
                label: "Manual API Key",
                accountID: "manual-account",
                authMode: .openAIAPIKey
            )
        ]
        model.setProxyTestSelectedAccountKey("key-manual-account")

        await model.refreshProxyTestConsole()

        let request = capture.snapshot()
        XCTAssertEqual(
            request?.url?.absoluteString,
            "http://127.0.0.1:9911/admin/proxy-test/models?selected_account_key=key-manual-account"
        )
    }

    @MainActor
    func testProxyTestSelectedAccountChangeLoadsCurrentAccountDiscoveredModels() async throws {
        let capture = LockedRequestCapture()
        let expectedCatalog = Self.makeProxyTestGPTCatalog(models: ["gpt-5.5"])

        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.store(request)
            let data = try JSONEncoder().encode(expectedCatalog)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session
        )
        let model = DesktopAppModel(admin: admin)
        model.isProxyTestPresented = true
        model.proxyTestDraft.userPrompt = "Keep this prompt"
        model.proxyTestDraft.model = "claude-sonnet-4-6"
        model.accounts = [
            Self.makeAccount(
                id: "manual-account",
                label: "Manual API Key",
                accountID: "manual-account",
                authMode: .openAIAPIKey
            )
        ]

        model.setProxyTestSelectedAccountKey("key-manual-account")

        await Self.waitForCondition {
            model.proxyTestAvailableModels == ["gpt-5.5"]
        }
        let request = capture.snapshot()
        XCTAssertEqual(
            request?.url?.absoluteString,
            "http://127.0.0.1:9911/admin/proxy-test/models?selected_account_key=key-manual-account"
        )
        XCTAssertEqual(model.proxyTestDraft.model, "gpt-5.5")
        XCTAssertEqual(model.proxyTestDraft.userPrompt, "Keep this prompt")
    }

    @MainActor
    func testProxyTestSelectedAccountClearingLoadsDefaultModelsWithoutAccountQuery() async throws {
        let capture = LockedRequestCapture()
        let expectedCatalog = ProxyTestModelCatalog.defaultCatalog

        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.store(request)
            let data = try JSONEncoder().encode(expectedCatalog)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session
        )
        let model = DesktopAppModel(admin: admin)
        model.isProxyTestPresented = true
        model.proxyTestDraft.selectedAccountKey = "key-manual-account"

        model.setProxyTestSelectedAccountKey("")

        await Self.waitForCondition {
            capture.snapshot() != nil
                && model.proxyTestAvailableModels == ProxyTestModelCatalog.defaultCatalog.chatCompletions.models
        }
        let request = capture.snapshot()
        XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:9911/admin/proxy-test/models")
    }

    @MainActor
    func testProxyTestSelectedAccountModelLoadIgnoresStaleSelectionResponse() async throws {
        let capture = LockedRequestCapture()
        let slowCatalog = Self.makeProxyTestGPTCatalog(models: ["gpt-5.5"])
        let fastCatalog = Self.makeProxyTestGPTCatalog(models: ["gpt-5.6"])

        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.store(request)
            let absoluteString = request.url?.absoluteString ?? ""
            if absoluteString.contains("key-slow-account") {
                Thread.sleep(forTimeInterval: 0.15)
            }
            let data = try JSONEncoder().encode(
                absoluteString.contains("key-slow-account") ? slowCatalog : fastCatalog
            )
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session
        )
        let model = DesktopAppModel(admin: admin)
        model.isProxyTestPresented = true
        model.accounts = [
            Self.makeAccount(
                id: "slow-account",
                label: "Slow API Key",
                accountID: "slow-account",
                authMode: .openAIAPIKey
            ),
            Self.makeAccount(
                id: "fast-account",
                label: "Fast API Key",
                accountID: "fast-account",
                authMode: .openAIAPIKey
            ),
        ]

        model.setProxyTestSelectedAccountKey("key-slow-account")
        await Self.waitForCondition {
            capture.snapshot()?.url?.absoluteString.contains("key-slow-account") == true
        }

        model.setProxyTestSelectedAccountKey("key-fast-account")

        await Self.waitForCondition {
            model.proxyTestAvailableModels == ["gpt-5.6"]
        }
        try? await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(model.proxyTestDraft.selectedAccountKey, "key-fast-account")
        XCTAssertEqual(model.proxyTestAvailableModels, ["gpt-5.6"])
    }

    @MainActor
    func testRemoteAdminTunnelControllerEstablishesTunnelReadsTokenAndClosesIt() async throws {
        let host = Self.makeRemoteHost(
            id: "host-1",
            label: "Tokyo",
            host: "tokyo.example.com",
            authMode: .password,
            remoteDirectory: "/srv/codex-proxy"
        )
        let ssh = RemoteAdminSSHStub()
        ssh.runHandler = { _, command in
            if command.contains("systemctl cat") {
                return "ExecStart=/srv/codex-proxy/codex-proxyd serve --data-dir /srv/codex-proxy/data --public-host 0.0.0.0 --public-port 8787 --admin-port 8788\n"
            }
            if command.contains("admin-token.txt") {
                XCTAssertTrue(command.contains("/srv/codex-proxy/data/admin-token.txt"))
                return "remote-admin-token\n"
            }
            if command.contains("mihomo.out.log") {
                XCTAssertTrue(command.contains("/srv/codex-proxy/data/mihomo/mihomo.out.log"))
                XCTAssertTrue(command.contains("/srv/codex-proxy/data/mihomo/mihomo.err.log"))
                return "[mihomo stdout]\nready"
            }
            XCTFail("Unexpected SSH command: \(command)")
            return ""
        }

        let controller = RemoteAdminTunnelController(host: host, ssh: ssh)
        let state = try await controller.ensureConnected()
        let logs = try await controller.loadManagedProxyLogs(lines: 25)
        let token = try await controller.currentToken()
        let connectedSnapshot = await controller.snapshot()
        await controller.close()
        let closedSnapshot = await controller.snapshot()

        XCTAssertEqual(state.hostID, host.id)
        XCTAssertEqual(state.localPort, connectedSnapshot.localPort)
        XCTAssertTrue((state.localPort ?? 0) > 0)
        XCTAssertEqual(state.adminBaseURL?.host, "127.0.0.1")
        XCTAssertEqual(state.configuredAdminPort, host.adminPort)
        XCTAssertEqual(state.effectiveAdminPort, host.adminPort)
        XCTAssertEqual(state.discoveredAdminPort, host.adminPort)
        XCTAssertFalse(state.adminPortDriftDetected)
        XCTAssertEqual(token, "remote-admin-token")
        XCTAssertEqual(logs, "[mihomo stdout]\nready")
        XCTAssertNil(closedSnapshot.localPort)
        XCTAssertNil(closedSnapshot.adminBaseURL)
        XCTAssertEqual(ssh.openTunnelCalls.count, 1)
        XCTAssertEqual(ssh.openTunnelCalls.first?.hostID, host.id)
        XCTAssertEqual(ssh.openTunnelCalls.first?.remotePort, host.adminPort)
        XCTAssertEqual(ssh.closeTunnelCalls.count, 1)
        XCTAssertEqual(ssh.closeTunnelCalls.first?.hostID, host.id)
    }

    @MainActor
    func testRemoteAdminTunnelControllerReportsHelpfulErrorWhenTokenFileIsMissing() async {
        let host = Self.makeRemoteHost(
            id: "host-1",
            label: "Tokyo",
            host: "tokyo.example.com",
            authMode: .password,
            remoteDirectory: "/srv/codex-proxy"
        )
        let ssh = RemoteAdminSSHStub()
        ssh.runHandler = { _, command in
            if command.contains("systemctl cat") {
                return "ExecStart=/srv/codex-proxy/codex-proxyd serve --data-dir /srv/codex-proxy/data --public-host 0.0.0.0 --public-port 8787 --admin-port 8788\n"
            }
            if command.contains("admin-token.txt") {
                throw ProxyError.message("cat: /srv/codex-proxy/data/admin-token.txt: No such file or directory")
            }
            XCTFail("Unexpected SSH command: \(command)")
            return ""
        }

        let controller = RemoteAdminTunnelController(host: host, ssh: ssh)

        do {
            _ = try await controller.ensureConnected()
            XCTFail("Expected remote admin tunnel setup to fail when the token file is missing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Remote admin token file is missing"))
            XCTAssertTrue(error.localizedDescription.contains("/srv/codex-proxy/data/admin-token.txt"))
            XCTAssertTrue(error.localizedDescription.contains("Redeploy the remote host"))
            XCTAssertTrue(error.localizedDescription.contains("restart the remote proxy service once with the fixed build"))
        }

        let snapshot = await controller.snapshot()
        if case .failed(let detail) = snapshot.tunnelStatus {
            XCTAssertTrue(detail.contains("/srv/codex-proxy/data/admin-token.txt"))
        } else {
            XCTFail("Expected tunnel status to capture the missing token file failure")
        }
        if case .failed(let detail) = snapshot.reachabilityStatus {
            XCTAssertTrue(detail.contains("/srv/codex-proxy/data/admin-token.txt"))
        } else {
            XCTFail("Expected reachability status to capture the missing token file failure")
        }
        XCTAssertEqual(ssh.openTunnelCalls.count, 1)
        XCTAssertEqual(ssh.closeTunnelCalls.count, 1)
    }

    @MainActor
    func testRemoteAdminTunnelControllerUsesDiscoveredAdminPortWhenSavedPortDrifts() async throws {
        let host = Self.makeRemoteHost(
            id: "host-1",
            label: "Tokyo",
            host: "tokyo.example.com",
            authMode: .password,
            remoteDirectory: "/srv/codex-proxy",
            adminPort: 8788
        )
        let ssh = RemoteAdminSSHStub()
        ssh.runHandler = { _, command in
            if command.contains("systemctl cat") {
                return "ExecStart=/srv/codex-proxy/codex-proxyd serve --data-dir /srv/codex-proxy/data --public-host 0.0.0.0 --public-port 8787 --admin-port 9911\n"
            }
            if command.contains("admin-token.txt") {
                return "remote-admin-token\n"
            }
            XCTFail("Unexpected SSH command: \(command)")
            return ""
        }

        let controller = RemoteAdminTunnelController(host: host, ssh: ssh)
        let state = try await controller.ensureConnected()

        XCTAssertEqual(state.configuredAdminPort, 8788)
        XCTAssertEqual(state.effectiveAdminPort, 9911)
        XCTAssertEqual(state.discoveredAdminPort, 9911)
        XCTAssertTrue(state.adminPortDriftDetected)
        XCTAssertEqual(state.remoteEndpoint, "tokyo.example.com:9911")
        XCTAssertEqual(ssh.openTunnelCalls.first?.remotePort, 9911)
    }

    @MainActor
    func testRemoteAdminTunnelControllerFallsBackToSavedPortWhenDiscoveryCannotParseExecStart() async throws {
        let host = Self.makeRemoteHost(
            id: "host-1",
            label: "Tokyo",
            host: "tokyo.example.com",
            authMode: .password,
            remoteDirectory: "/srv/codex-proxy",
            adminPort: 8788
        )
        let ssh = RemoteAdminSSHStub()
        ssh.runHandler = { _, command in
            if command.contains("systemctl cat") {
                return "ExecStart=/srv/codex-proxy/codex-proxyd serve --data-dir /srv/codex-proxy/data --public-host 0.0.0.0 --public-port 8787\n"
            }
            if command.contains("admin-token.txt") {
                return "remote-admin-token\n"
            }
            XCTFail("Unexpected SSH command: \(command)")
            return ""
        }

        let controller = RemoteAdminTunnelController(host: host, ssh: ssh)
        let state = try await controller.ensureConnected()

        XCTAssertEqual(state.configuredAdminPort, host.adminPort)
        XCTAssertEqual(state.effectiveAdminPort, host.adminPort)
        XCTAssertNil(state.discoveredAdminPort)
        XCTAssertFalse(state.adminPortDriftDetected)
        XCTAssertEqual(ssh.openTunnelCalls.first?.remotePort, host.adminPort)
    }

    @MainActor
    func testRemoteAdminWindowModelSurfacesHostScopedEmptyStates() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        model.appModel.status = Self.makeProxyStatus(running: false)

        XCTAssertEqual(model.accountEmptyState?.title, "远端账号池还是空的")
        XCTAssertEqual(model.proxyEmptyState?.title, "远端代理能力还没配置")
    }

    @MainActor
    func testRemoteAdminWindowModelDisplaysEffectiveAdminPortWhenSessionDetectsDrift() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com", adminPort: 8788)
        let model = Self.makeRemoteAdminWindowModel(host: host)
        model.sessionState = RemoteAdminSessionState(
            hostID: host.id,
            remoteEndpoint: "tokyo.example.com:9911",
            configuredAdminPort: 8788,
            effectiveAdminPort: 9911,
            discoveredAdminPort: 9911,
            adminPortDriftDetected: true
        )

        XCTAssertEqual(model.remoteEndpointText, "tokyo.example.com:9911")
        XCTAssertEqual(model.remoteAdminBindText, "127.0.0.1:9911/admin")
        XCTAssertTrue(model.adminPortResolutionNotice?.detail.contains("8788") == true)
        XCTAssertTrue(model.adminPortResolutionNotice?.detail.contains("9911") == true)
    }

    @MainActor
    func testRemoteAdminWindowModelHeaderStartsCollapsed() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)

        XCTAssertFalse(model.isHeaderExpanded)
        XCTAssertEqual(model.selectedPage, .overview)
        XCTAssertEqual(model.appModel.selectedPage, .overview)
        XCTAssertEqual(model.appModel.preferences.interfaceMode, .full)
    }

    @MainActor
    func testRemoteAdminWindowModelBuildsExportContextFromAppliedFiltersAndPendingDrafts() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        model.appModel.status = Self.makeProxyStatus(running: true)

        let account = Self.makeAccount(
            id: "account-1",
            label: "Prod Relay",
            accountID: "acct-1"
        )
        model.appModel.accounts = [account]

        model.appModel.requestLogsAppliedFilterState.selectedAccountKey = account.accountKey
        model.appModel.requestLogsAppliedFilterState.selectedModel = "gpt-4.1"
        model.appModel.requestLogsDraftFilterState = model.appModel.requestLogsAppliedFilterState
        model.appModel.requestLogsDraftFilterState.selectedAPIKey = "sk-remote"

        XCTAssertTrue(model.requestLogsAppliedFilterSummaryText.contains("Prod Relay"))
        XCTAssertTrue(model.requestLogsAppliedFilterSummaryText.contains("gpt-4.1"))
        XCTAssertTrue(model.requestLogsExportNotes.contains { $0.contains("gpt-4.1") })
    }

    @MainActor
    func testRemoteAdminWindowModelRefreshLoadsRemoteWorkspace() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let account = Self.makeAccount(id: "account-1", label: "Remote", accountID: "acct-1")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(hostID: host.id, host: host.host, publicPort: host.publicPort, running: true)
        }

        let admin = AdminAPIClient(
            accountsHandler: { [account] },
            getStatusHandler: {
                var status = Self.makeProxyStatus(running: true)
                status.publicBaseURL = "http://\(host.host):\(host.publicPort)/v1"
                return status
            },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 42) },
            getSettingsHandler: {
                var config = AppConfig()
                config.chatGPTBaseURL = "https://remote-admin.example.com"
                return config
            },
            getManagedProxySnapshotHandler: {
                ManagedProxySnapshot(subscriptionConfigured: true)
            },
            proxyAPIKeyUsageHandler: { _ in
                ProxyAPIKeyUsageReport(from: 0, to: 0)
            }
        )
        let tunnel = RemoteAdminTunnelStub(
            state: RemoteAdminSessionState(
                hostID: host.id,
                adminBaseURL: URL(string: "http://127.0.0.1:9911/admin"),
                remoteEndpoint: "\(host.host):\(host.adminPort)",
                configuredAdminPort: host.adminPort,
                effectiveAdminPort: host.adminPort,
                localPort: 9911,
                tunnelStatus: .connected(localPort: 9911),
                reachabilityStatus: .unknown
            )
        )
        let model = Self.makeRemoteAdminWindowModel(
            host: host,
            remoteDeploy: remoteDeploy,
            admin: admin,
            tunnelController: tunnel
        )

        await model.refresh()

        XCTAssertTrue(model.hasLoadedInitialContent)
        XCTAssertNotNil(model.lastSuccessfulRefreshAt)
        XCTAssertEqual(model.appModel.accounts.map(\.id), [account.id])
        XCTAssertEqual(model.appModel.stats.totalRequests, 42)
        XCTAssertEqual(model.appModel.settings.chatGPTBaseURL, "https://remote-admin.example.com")
        XCTAssertTrue(model.appModel.localServiceStatus?.running == true)
        XCTAssertGreaterThanOrEqual(remoteDeploy.statusCalls.count, 2)
        let ensureConnectedCallCount = await tunnel.ensureConnectedCallCount
        let updateReachabilityCalls = await tunnel.updateReachabilityCalls
        XCTAssertEqual(ensureConnectedCallCount, 1)
        XCTAssertEqual(updateReachabilityCalls.last, .reachable)
    }

    @MainActor
    func testRemoteAdminWindowModelImportLocalAccountsToRemoteSendsBackupAndRefreshesRemoteState() async throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let probe = RemoteAdminLocalImportProbe()
        let importedAccount = Self.makeAccount(id: "remote-imported-account", label: "Remote Import", accountID: "acct-remote-imported")
        let exported = #"""
        {
          "version": 1,
          "exportedAt": 1710000000,
          "accounts": [
            {
              "label": "Local Export",
              "authJSON": "{\"OPENAI_API_KEY\":\"sk-test-local-export\"}"
            }
          ]
        }
        """#

        let admin = AdminAPIClient(
            accountsHandler: {
                probe.accounts()
            },
            importAuthJSONItemsHandler: { items in
                probe.recordImport(items)
                probe.setAccounts([importedAccount])
                return ImportAccountsResult(totalCount: 1, importedCount: 1, updatedCount: 0, failures: [])
            },
            getStatusHandler: {
                var status = Self.makeProxyStatus(running: true)
                status.publicBaseURL = "http://\(host.host):\(host.publicPort)/v1"
                return status
            },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 7) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let model = Self.makeRemoteAdminWindowModel(
            host: host,
            admin: admin,
            localAccountsExportHandler: {
                probe.recordLocalExport()
                return Data(exported.utf8)
            },
            confirmImportLocalAccountsHandler: { content in
                probe.recordConfirmation(content)
                return true
            }
        )

        await model.importLocalAccountsToRemote()

        let importCalls = probe.importCalls()
        let confirmationContents = probe.confirmationContents()
        let localExportCallCount = probe.localExportCallCount()
        XCTAssertEqual(localExportCallCount, 1)
        XCTAssertEqual(importCalls.count, 1)
        XCTAssertEqual(confirmationContents.count, 1)
        XCTAssertTrue(confirmationContents[0].informativeText.contains("Tokyo"))
        XCTAssertTrue(confirmationContents[0].informativeText.contains("1"))
        XCTAssertEqual(importCalls[0].count, 1)
        XCTAssertEqual(importCalls[0][0].source, "local-desktop-accounts.json")
        XCTAssertEqual(importCalls[0][0].content, exported)
        XCTAssertEqual(model.appModel.accounts.map(\.id), [importedAccount.id])
        XCTAssertEqual(model.appModel.banners.first?.tone, .success)
        XCTAssertEqual(model.appModel.banners.first?.title, model.appModel.localization.successTitle(for: .importLocalAccountsToRemote))
        XCTAssertEqual(
            model.appModel.banners.first?.detail,
            model.localized(zh: "新增 1 个，更新 0 个，失败 0 个。", en: "Imported 1, updated 0, failed 0.")
        )
    }

    @MainActor
    func testRemoteAdminWindowModelImportLocalAccountsToRemoteStopsWhenConfirmationCancelled() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let probe = RemoteAdminLocalImportProbe()
        let admin = AdminAPIClient(
            accountsHandler: { probe.accounts() },
            importAuthJSONItemsHandler: { items in
                probe.recordImport(items)
                return ImportAccountsResult(totalCount: 1, importedCount: 1, updatedCount: 0, failures: [])
            },
            getStatusHandler: { Self.makeProxyStatus(running: true) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let model = Self.makeRemoteAdminWindowModel(
            host: host,
            admin: admin,
            localAccountsExportHandler: {
                probe.recordLocalExport()
                return Data(#"{"version":1,"accounts":[{"authJSON":"{\"OPENAI_API_KEY\":\"sk-cancel\"}"}]}"#.utf8)
            },
            confirmImportLocalAccountsHandler: { content in
                probe.recordConfirmation(content)
                return false
            }
        )

        await model.importLocalAccountsToRemote()

        XCTAssertEqual(probe.localExportCallCount(), 1)
        XCTAssertEqual(probe.confirmationContents().count, 1)
        XCTAssertTrue(probe.importCalls().isEmpty)
        XCTAssertTrue(model.appModel.banners.isEmpty)
    }

    @MainActor
    func testRemoteAdminWindowModelImportLocalAccountsToRemoteWarnsWhenNoLocalAccountsExist() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let probe = RemoteAdminLocalImportProbe()
        let admin = AdminAPIClient(
            accountsHandler: { probe.accounts() },
            importAuthJSONItemsHandler: { items in
                probe.recordImport(items)
                return ImportAccountsResult(totalCount: 0, importedCount: 0, updatedCount: 0, failures: [])
            },
            getStatusHandler: { Self.makeProxyStatus(running: true) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let model = Self.makeRemoteAdminWindowModel(
            host: host,
            admin: admin,
            localAccountsExportHandler: {
                probe.recordLocalExport()
                return Data(#"{"version":1,"accounts":[]}"#.utf8)
            },
            confirmImportLocalAccountsHandler: { content in
                probe.recordConfirmation(content)
                return true
            }
        )

        await model.importLocalAccountsToRemote()

        XCTAssertEqual(probe.localExportCallCount(), 1)
        XCTAssertTrue(probe.importCalls().isEmpty)
        XCTAssertTrue(probe.confirmationContents().isEmpty)
        XCTAssertEqual(model.appModel.banners.first?.tone, .warning)
        XCTAssertEqual(model.appModel.banners.first?.title, model.localized(zh: "本地还没有可导入的账号", en: "There are no local accounts to import yet"))
    }

    @MainActor
    func testRemoteAdminWindowModelImportLocalAccountsToRemoteWarnsWhenRemoteImportHasFailures() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let probe = RemoteAdminLocalImportProbe()
        let importedAccount = Self.makeAccount(id: "remote-imported-account", label: "Remote Import", accountID: "acct-remote-imported")
        let admin = AdminAPIClient(
            accountsHandler: { probe.accounts() },
            importAuthJSONItemsHandler: { items in
                probe.recordImport(items)
                probe.setAccounts([importedAccount])
                return ImportAccountsResult(
                    totalCount: 1,
                    importedCount: 1,
                    updatedCount: 2,
                    failures: [.init(source: "local-desktop-accounts.json", error: "token expired")]
                )
            },
            getStatusHandler: { Self.makeProxyStatus(running: true) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let model = Self.makeRemoteAdminWindowModel(
            host: host,
            admin: admin,
            localAccountsExportHandler: {
                probe.recordLocalExport()
                return Data(#"{"version":1,"accounts":[{"authJSON":"{\"OPENAI_API_KEY\":\"sk-warning\"}"}]}"#.utf8)
            },
            confirmImportLocalAccountsHandler: { content in
                probe.recordConfirmation(content)
                return true
            }
        )

        await model.importLocalAccountsToRemote()

        XCTAssertEqual(probe.importCalls().count, 1)
        XCTAssertEqual(model.appModel.accounts.map(\.id), [importedAccount.id])
        XCTAssertEqual(model.appModel.banners.first?.tone, .warning)
        XCTAssertTrue(model.appModel.banners.first?.detail?.contains("updated 2") == true || model.appModel.banners.first?.detail?.contains("更新 2 个") == true)
        XCTAssertTrue(model.appModel.banners.first?.detail?.contains("token expired") == true)
    }

    @MainActor
    func testRemoteAdminWindowModelRemoteDaemonAdapterUsesRemoteDeploy() async throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(hostID: host.id, host: host.host, publicPort: host.publicPort, running: false)
        }
        remoteDeploy.startHandler = { host in
            Self.makeRemoteDeployStatus(hostID: host.id, host: host.host, publicPort: host.publicPort, running: true)
        }
        remoteDeploy.stopHandler = { host in
            Self.makeRemoteDeployStatus(hostID: host.id, host: host.host, publicPort: host.publicPort, running: false)
        }
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let model = Self.makeRemoteAdminWindowModel(host: host, remoteDeploy: remoteDeploy, admin: admin)

        let initialStatus = await model.appModel.daemon.status()
        model.appModel.localServiceStatus = initialStatus
        model.appModel.status = Self.makeProxyStatus(running: false)

        XCTAssertEqual(initialStatus.launchctlState, "registered")
        XCTAssertEqual(model.appModel.localServicePrimaryStatusText, model.appModel.text(.statusInstalledNotRunning))
        XCTAssertEqual(model.appModel.localStartButtonTitle, model.appModel.text(.actionStartDaemon))

        try await model.appModel.daemon.start(config: AppConfig())
        XCTAssertEqual(remoteDeploy.startCalls.map(\.id), [host.id])

        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(hostID: host.id, host: host.host, publicPort: host.publicPort, running: true)
        }
        model.appModel.localServiceStatus = await model.appModel.daemon.status()
        model.appModel.status = Self.makeProxyStatus(running: true)

        XCTAssertEqual(model.appModel.localServicePrimaryStatusText, model.appModel.text(.statusRunning))
        XCTAssertTrue(model.appModel.localCanStopService)

        try await model.appModel.daemon.stop()
        XCTAssertEqual(remoteDeploy.stopCalls.map(\.id), [host.id])
    }

    @MainActor
    func testRemoteAdminWindowViewShowsHeaderSidebarAndWorkspaceShell() throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(model, host: host)
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RemoteAdminWindowView.swift")
        let (window, hostingView) = Self.makeRemoteAdminHostingView(model: model)
        defer { window.orderOut(nil) }

        Self.renderHostedView(hostingView)

        XCTAssertEqual(model.hostDisplayName, "Tokyo")
        XCTAssertEqual(model.tunnelStatusText, "Connected :9911")
        XCTAssertEqual(model.reachabilityText, "Reachable")
        XCTAssertEqual(model.daemonStatusText, "Running")
        XCTAssertGreaterThanOrEqual(Self.remoteAdminTopBarItemFrames(in: hostingView).count, 3)
        XCTAssertFalse(source.contains("DashboardHeader("))
        XCTAssertFalse(source.contains("remote-admin-tab-strip"))
        XCTAssertFalse(source.contains("RemoteAdminSectionStrip"))
        XCTAssertTrue(source.contains("SidebarPageButton("))
        XCTAssertTrue(source.contains("OverviewView(model: self.model.appModel)"))
        XCTAssertTrue(source.contains("presentationContext: .remoteAdmin"))
        XCTAssertTrue(source.contains("onImportLocalAccountsToRemote:"))
        XCTAssertTrue(source.contains("ProxyView(model: self.model.appModel)"))
        XCTAssertTrue(source.contains("SettingsProxyPanel(model: self.model.appModel)"))
        XCTAssertTrue(source.contains("Proxy Test Available"))
        XCTAssertFalse(source.contains("Proxy Test Hidden"))
    }

    @MainActor
    func testRemoteAdminWindowWideLayoutExpandsDetailContentBeyondFormerGlobalCap() throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(model, host: host)
        let (window, hostingView) = Self.makeRemoteAdminHostingView(model: model, width: 1840, height: 980)
        defer { window.orderOut(nil) }

        Self.renderHostedView(hostingView)

        let detailFrame = try XCTUnwrap(
            Self.hostedViewFrame(withAccessibilityIdentifier: "remote-admin-workspace-detail-content", in: hostingView)
        )

        XCTAssertGreaterThan(detailFrame.width, 1320)
    }

    @MainActor
    func testRemoteAdminWindowViewExpandedHeaderPushesWorkspaceLower() throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let collapsedModel = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(collapsedModel, host: host)
        let (collapsedWindow, collapsedHostingView) = Self.makeRemoteAdminHostingView(model: collapsedModel)
        defer { collapsedWindow.orderOut(nil) }

        let expandedModel = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(expandedModel, host: host)
        expandedModel.isHeaderExpanded = true
        let (expandedWindow, expandedHostingView) = Self.makeRemoteAdminHostingView(model: expandedModel)
        defer { expandedWindow.orderOut(nil) }

        Self.renderHostedView(collapsedHostingView)
        Self.renderHostedView(expandedHostingView)

        let collapsedGraphicsViews = Self.hostedSubviewCount(in: collapsedHostingView, named: "SwiftUI._NSGraphicsView")
        let expandedGraphicsViews = Self.hostedSubviewCount(in: expandedHostingView, named: "SwiftUI._NSGraphicsView")
        let collapsedTopLevelViewCount = collapsedHostingView.subviews.count
        let expandedTopLevelViewCount = expandedHostingView.subviews.count

        XCTAssertGreaterThan(expandedTopLevelViewCount, collapsedTopLevelViewCount)
        XCTAssertGreaterThan(expandedGraphicsViews, collapsedGraphicsViews)
    }

    @MainActor
    func testRemoteAdminWindowViewCollapsedHeaderStillShowsAdminPortNoticeInLayout() throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com", adminPort: 8788)
        let baselineModel = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(baselineModel, host: host)
        let (baselineWindow, baselineHostingView) = Self.makeRemoteAdminHostingView(model: baselineModel)
        defer { baselineWindow.orderOut(nil) }

        let modelWithNotice = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(modelWithNotice, host: host)
        modelWithNotice.sessionState = RemoteAdminSessionState(
            hostID: host.id,
            adminBaseURL: URL(string: "http://127.0.0.1:9911/admin"),
            remoteEndpoint: "tokyo.example.com:9911",
            configuredAdminPort: 8788,
            effectiveAdminPort: 9911,
            discoveredAdminPort: 9911,
            adminPortDriftDetected: true,
            localPort: 9911,
            tunnelStatus: .connected(localPort: 9911),
            reachabilityStatus: .reachable
        )
        let (noticeWindow, noticeHostingView) = Self.makeRemoteAdminHostingView(model: modelWithNotice)
        defer { noticeWindow.orderOut(nil) }

        Self.renderHostedView(baselineHostingView)
        Self.renderHostedView(noticeHostingView)

        let baselineTopBarCount = Self.remoteAdminTopBarItemFrames(in: baselineHostingView).count
        let noticeTopBarCount = Self.remoteAdminTopBarItemFrames(in: noticeHostingView).count
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RemoteAdminWindowView.swift")

        XCTAssertFalse(modelWithNotice.isHeaderExpanded)
        XCTAssertNotNil(modelWithNotice.adminPortResolutionNotice)
        XCTAssertEqual(noticeTopBarCount, baselineTopBarCount)
        XCTAssertTrue(source.contains("remote-admin-header-admin-port-notice"))
    }

    @MainActor
    func testRemoteAdminWindowModelDefaultsToOverviewPerWindow() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let firstModel = Self.makeRemoteAdminWindowModel(host: host)

        XCTAssertEqual(firstModel.selectedPage, .overview)

        firstModel.selectPage(.accounts)
        XCTAssertEqual(firstModel.selectedPage, .accounts)
        XCTAssertEqual(firstModel.appModel.selectedPage, .accounts)

        let secondModel = Self.makeRemoteAdminWindowModel(host: host)

        XCTAssertEqual(secondModel.selectedPage, .overview)
        XCTAssertEqual(secondModel.appModel.selectedPage, .overview)
    }

    @MainActor
    func testRemoteAdminSidebarLocalizationMatchesSharedDesktopTitlesAcrossLanguageChanges() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        var englishPreferences = DesktopPreferences()
        englishPreferences.languageMode = .english
        let model = Self.makeRemoteAdminWindowModel(host: host, preferences: englishPreferences)

        XCTAssertEqual(model.title(for: .overview), model.appModel.pageTitle(.overview))
        XCTAssertEqual(model.subtitle(for: .overview), model.appModel.pageSubtitle(.overview))
        XCTAssertEqual(model.title(for: .accounts), model.appModel.pageTitle(.accounts))
        XCTAssertEqual(model.subtitle(for: .accounts), model.appModel.pageSubtitle(.accounts))
        XCTAssertEqual(model.title(for: .proxy), model.appModel.pageTitle(.proxy))
        XCTAssertEqual(model.subtitle(for: .proxy), model.appModel.pageSubtitle(.proxy))
        XCTAssertEqual(model.title(for: .overview), "Overview")
        XCTAssertEqual(model.title(for: .outboundProxy), model.appModel.outboundProxyPageTitle)
        XCTAssertEqual(model.subtitle(for: .outboundProxy), model.appModel.outboundProxyPageSubtitle)
        XCTAssertEqual(model.title(for: .outboundProxy), "Outbound Proxy")
        XCTAssertNotEqual(model.title(for: .outboundProxy), model.appModel.pageTitle(.settings))

        var chinesePreferences = englishPreferences
        chinesePreferences.languageMode = .zhHans
        model.applyPreferences(chinesePreferences)

        XCTAssertEqual(model.title(for: .overview), model.appModel.pageTitle(.overview))
        XCTAssertEqual(model.subtitle(for: .overview), model.appModel.pageSubtitle(.overview))
        XCTAssertEqual(model.title(for: .accounts), model.appModel.pageTitle(.accounts))
        XCTAssertEqual(model.subtitle(for: .accounts), model.appModel.pageSubtitle(.accounts))
        XCTAssertEqual(model.title(for: .proxy), model.appModel.pageTitle(.proxy))
        XCTAssertEqual(model.subtitle(for: .proxy), model.appModel.pageSubtitle(.proxy))
        XCTAssertEqual(model.title(for: .overview), "总览")
        XCTAssertEqual(model.title(for: .outboundProxy), model.appModel.outboundProxyPageTitle)
        XCTAssertEqual(model.subtitle(for: .outboundProxy), model.appModel.outboundProxyPageSubtitle)
        XCTAssertEqual(model.title(for: .outboundProxy), "出站代理")
        XCTAssertNotEqual(model.title(for: .outboundProxy), model.appModel.pageTitle(.settings))
    }

    @MainActor
    func testRemoteAdminWindowViewSwitchesBetweenMirroredPages() throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(model, host: host)
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RemoteAdminWindowView.swift")

        model.selectPage(.accounts)
        XCTAssertEqual(model.appModel.selectedPage, .accounts)

        model.selectPage(.proxy)
        XCTAssertEqual(model.appModel.selectedPage, .proxy)

        model.selectPage(.outboundProxy)
        XCTAssertEqual(model.appModel.selectedPage, .settings)
        XCTAssertEqual(model.appModel.selectedSettingsTab, .proxy)
        XCTAssertTrue(source.contains("OverviewView(model: self.model.appModel)"))
        XCTAssertTrue(source.contains("presentationContext: .remoteAdmin"))
        XCTAssertTrue(source.contains("onImportLocalAccountsToRemote:"))
        XCTAssertTrue(source.contains("ProxyView(model: self.model.appModel)"))
        XCTAssertTrue(source.contains("SettingsProxyPanel(model: self.model.appModel)"))
        XCTAssertFalse(source.contains("DashboardHeader("))
        XCTAssertFalse(source.contains("remote-admin-tab-strip"))
        XCTAssertFalse(source.contains("RemoteAdminSectionStrip"))
    }

    @MainActor
    func testRemoteAdminWindowViewAccountsPageRendersAccountPoolDetailDrawerInViewportOverlay() async throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(model, host: host)
        model.selectPage(.accounts)
        model.appModel.preferences.accountPoolDisplayMode = .list

        let selectedAccount = Self.makeAccount(
            id: "remote-admin-selected-account",
            label: "Remote Drawer",
            accountID: "acct-remote-admin"
        )
        model.appModel.accounts = [
            selectedAccount,
            Self.makeAccount(
                id: "remote-admin-other-account",
                label: "Remote Sibling",
                accountID: "acct-remote-admin-other"
            ),
        ]

        let (window, hostingView) = Self.makeRemoteAdminHostingView(model: model, width: 1480, height: 920)
        defer { window.orderOut(nil) }

        Self.renderHostedView(hostingView)
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RemoteAdminWindowView.swift")
        var renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")

        XCTAssertEqual(model.selectedPage, .accounts)
        XCTAssertEqual(model.appModel.selectedPage, .accounts)
        XCTAssertEqual(model.appModel.preferences.interfaceMode, .full)
        XCTAssertEqual(model.appModel.accountPoolDisplayMode, .list)
        XCTAssertFalse(model.appModel.isAccountPoolDetailDrawerPresented)
        XCTAssertTrue(source.contains("remote-admin-account-drawer"))
        XCTAssertTrue(source.contains("remote-admin-account-drawer-backdrop"))
        XCTAssertFalse(renderedText.contains(selectedAccount.accountID))

        model.appModel.presentAccountPoolDetailDrawer(for: selectedAccount)
        XCTAssertEqual(model.appModel.selectedAccountPoolAccountID, selectedAccount.id)
        XCTAssertTrue(model.appModel.isAccountPoolDetailDrawerPresented)
        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            let text = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
            return text.contains(selectedAccount.accountID)
        }

        renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertTrue(renderedText.contains(selectedAccount.accountID))

        model.appModel.dismissAccountPoolDetailDrawer()
        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            let text = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
            return text.contains(selectedAccount.accountID) == false
        }

        renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertFalse(renderedText.contains(selectedAccount.accountID))
        XCTAssertEqual(model.appModel.selectedAccountPoolAccountID, selectedAccount.id)
        XCTAssertFalse(model.appModel.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testRemoteAdminWindowViewAccountsPageShowsTestProxyQuickAction() throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(model, host: host)
        model.selectPage(.accounts)
        model.appModel.accounts = [
            Self.makeAccount(
                id: "remote-admin-account-1",
                label: "Remote Account",
                accountID: "acct-remote-1"
            )
        ]

        let (window, hostingView) = Self.makeRemoteAdminHostingView(model: model, width: 1520, height: 920)
        defer { window.orderOut(nil) }
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/AccountsView.swift")

        Self.renderHostedView(hostingView)

        XCTAssertTrue(model.appModel.adminSupportsProxyTesting)
        XCTAssertGreaterThan(Self.hostedSubviewCount(in: hostingView, named: "NSButton"), 0)
        XCTAssertTrue(source.contains("case .importLocalToRemote:"))
        XCTAssertTrue(source.contains("title: self.model.text(.actionImportLocalAccountsToRemote)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"accounts-import-local-to-remote-button\")"))
        XCTAssertTrue(source.contains("title: self.model.text(.actionTestProxy)"))
        XCTAssertTrue(source.contains("case .testProxy:"))
        XCTAssertTrue(source.contains("return self.model.adminSupportsProxyTesting"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"accounts-test-proxy-button\")"))
    }

    @MainActor
    func testRemoteAdminWindowViewProxyPageShowsTestProxyActionAndOpensConsole() async throws {
        _ = NSApplication.shared

        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(model, host: host)
        model.selectPage(.proxy)

        let (window, hostingView) = Self.makeRemoteAdminHostingView(model: model, width: 1520, height: 920)
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/ProxyView.swift")
        defer {
            model.appModel.dismissProxyTestConsole()
            window.orderOut(nil)
        }

        Self.renderHostedView(hostingView)

        XCTAssertTrue(model.appModel.adminSupportsProxyTesting)
        XCTAssertTrue(source.contains("ProxyTopUtilityControls"))
        XCTAssertTrue(source.contains("if self.model.adminSupportsProxyTesting"))
        XCTAssertTrue(source.contains("title: self.model.text(.actionTestProxy)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"proxy-test-proxy-button\")"))
        XCTAssertFalse(model.appModel.isProxyTestPresented)

        model.appModel.openProxyTestConsole()
        await Task.yield()

        XCTAssertTrue(model.appModel.isProxyTestPresented)

        model.appModel.dismissProxyTestConsole()
        XCTAssertFalse(model.appModel.isProxyTestPresented)
    }

    @MainActor
    func testRemoteAdminWindowModelPublicBaseURLTextUsesRemoteHostForWildcardRuntimeAddress() {
        let host = Self.makeRemoteHost(id: "host-remote", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        model.appModel.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://0.0.0.0:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://localhost:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-remote",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )

        XCTAssertEqual(model.publicBaseURLText, "http://tokyo.example.com:8787/v1")
    }

    @MainActor
    func testRemoteAdminWindowViewShowsBlockingOverlayWhenTunnelIsUnavailable() throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteAdminWindowModel(host: host)
        Self.prepareRemoteAdminWindowModelForVisibleLayout(model, host: host)
        model.sessionState.reachabilityStatus = .failed("tunnel down")

        let (window, hostingView) = Self.makeRemoteAdminHostingView(model: model)
        defer { window.orderOut(nil) }

        Self.renderHostedView(hostingView)
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RemoteAdminWindowView.swift")

        XCTAssertTrue(model.contentIsBlocked)
        XCTAssertTrue(source.contains("remote-admin-blocking-overlay"))
    }

    @MainActor
    func testRemoteReadinessIssuesExplainRemoteCapablePackageRequirementWhenBundledArtifactsAreMissing() {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(
            hostID: host.id,
            localArtifactAvailable: false
        )

        let issues = model.remoteReadinessIssues(for: host.id)

        XCTAssertTrue(issues.contains { $0.contains("Scripts/build-macos-app.sh") })
        XCTAssertTrue(issues.contains { $0.contains("Scripts/package-release.sh") })
        XCTAssertTrue(
            issues.contains {
                $0.contains("当前构建不包含应用内置 Linux 部署包") ||
                    $0.contains("does not include bundled Linux deployment packages")
            }
        )
        XCTAssertTrue(
            issues.contains {
                $0.contains("仍可进入远端运维") ||
                    $0.contains("still inspect remote status")
            }
        )
    }

    @MainActor
    func testDeployFailureBackfillsStatusAndLogsForSelectedHost() async {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let remoteDeploy = RemoteDeployStub()
        remoteDeploy.deployHandler = { _, _, _ in
            throw ProxyError.message("install failed")
        }
        remoteDeploy.statusHandler = { host in
            Self.makeRemoteDeployStatus(hostID: host.id, host: host.host, publicPort: host.publicPort)
        }
        remoteDeploy.logsHandler = { _, _ in
            "journal excerpt"
        }
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]), remoteDeploy: remoteDeploy)
        model.remoteConnectionChecksByHostID[host.id] = Self.makeRemoteConnectionCheck(hostID: host.id)

        await model.deploySelectedRemote()

        XCTAssertEqual(model.remoteStatuses[host.id]?.hostID, host.id)
        XCTAssertEqual(model.remoteLogsByHostID[host.id], "journal excerpt")
        XCTAssertNil(model.remoteServiceLoadErrors[host.id])
        XCTAssertEqual(remoteDeploy.statusCalls.map(\.id), [host.id])
        XCTAssertEqual(remoteDeploy.logsCalls.map(\.host.id), [host.id])
    }

    @MainActor
    func testSwitchInterfaceModeRoutesToDestinationWhenConfirmed() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            confirmInterfaceModeSwitchHandler: { _ in true }
        )

        model.switchInterfaceMode(target: .full, destination: .proxyAccess)

        XCTAssertEqual(model.preferences.interfaceMode, .full)
        XCTAssertEqual(model.selectedPage, .proxy)
        XCTAssertEqual(model.selectedProxyWorkspaceTab, .access)
        XCTAssertEqual(preferencesStore.load().interfaceMode, .full)
    }

    @MainActor
    func testSwitchInterfaceModePreservesLastFullPageAcrossRoundTrip() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            confirmInterfaceModeSwitchHandler: { _ in true }
        )
        Self.unlockRemoteManagement(on: model)
        model.selectedPage = .remote

        model.switchInterfaceMode(target: .minimal)
        XCTAssertEqual(model.preferences.interfaceMode, .minimal)

        model.switchInterfaceMode(target: .full)

        XCTAssertEqual(model.preferences.interfaceMode, .full)
        XCTAssertEqual(model.selectedPage, .remote)
    }

    @MainActor
    func testSwitchInterfaceModeDoesNotChangeStateWhenCancelled() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            confirmInterfaceModeSwitchHandler: { _ in false }
        )

        model.switchInterfaceMode(target: .full, destination: .settingsProxy)

        XCTAssertEqual(model.preferences.interfaceMode, .minimal)
        XCTAssertEqual(model.selectedPage, .overview)
        XCTAssertEqual(model.selectedSettingsTab, .appearance)
    }

    @MainActor
    func testOpenInterfaceModeWindowActivatesMainWindowWhenAlreadyInMinimalMode() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var openCount = 0
        DesktopMainWindow.configureOpenAction {
            openCount += 1
        }
        defer { DesktopMainWindow.configureOpenAction {} }

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        model.openInterfaceModeWindow(target: .minimal)

        XCTAssertEqual(model.preferences.interfaceMode, .minimal)
        XCTAssertEqual(preferencesStore.load().interfaceMode, .minimal)
        XCTAssertEqual(openCount, 1)
    }

    @MainActor
    func testOpenInterfaceModeWindowSwitchesToFullModeAndActivatesMainWindowWhenConfirmed() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var openCount = 0
        DesktopMainWindow.configureOpenAction {
            openCount += 1
        }
        defer { DesktopMainWindow.configureOpenAction {} }

        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            confirmInterfaceModeSwitchHandler: { _ in true }
        )

        model.openInterfaceModeWindow(target: .full)

        XCTAssertEqual(model.preferences.interfaceMode, .full)
        XCTAssertEqual(preferencesStore.load().interfaceMode, .full)
        XCTAssertEqual(openCount, 1)
    }

    @MainActor
    func testOpenInterfaceModeWindowDoesNotActivateMainWindowWhenFullModeSwitchCancelled() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var openCount = 0
        DesktopMainWindow.configureOpenAction {
            openCount += 1
        }
        defer { DesktopMainWindow.configureOpenAction {} }

        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            confirmInterfaceModeSwitchHandler: { _ in false }
        )

        model.openInterfaceModeWindow(target: .full)

        XCTAssertEqual(model.preferences.interfaceMode, .minimal)
        XCTAssertEqual(preferencesStore.load().interfaceMode, .minimal)
        XCTAssertEqual(openCount, 0)
    }

    @MainActor
    func testOpenInterfaceModeWindowSwitchesToMinimalModeAndActivatesMainWindowWhenConfirmed() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        var openCount = 0
        DesktopMainWindow.configureOpenAction {
            openCount += 1
        }
        defer { DesktopMainWindow.configureOpenAction {} }

        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            confirmInterfaceModeSwitchHandler: { _ in true }
        )

        model.openInterfaceModeWindow(target: .minimal)

        XCTAssertEqual(model.preferences.interfaceMode, .minimal)
        XCTAssertEqual(preferencesStore.load().interfaceMode, .minimal)
        XCTAssertEqual(openCount, 1)
    }

    @MainActor
    func testOpenInterfaceModeWindowDoesNotActivateMainWindowWhenMinimalModeSwitchCancelled() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferencesStore.save(DesktopPreferences(interfaceMode: .full))

        var openCount = 0
        DesktopMainWindow.configureOpenAction {
            openCount += 1
        }
        defer { DesktopMainWindow.configureOpenAction {} }

        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            confirmInterfaceModeSwitchHandler: { _ in false }
        )

        model.openInterfaceModeWindow(target: .minimal)

        XCTAssertEqual(model.preferences.interfaceMode, .full)
        XCTAssertEqual(preferencesStore.load().interfaceMode, .full)
        XCTAssertEqual(openCount, 0)
    }

    @MainActor
    func testStartAndDismissOnboardingUseWindowPresenter() {
        let presenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(onboardingWindowFactory: { _ in presenter })
        model.onboardingManualAPIKeyDraft = DesktopAppModel.ManualAPIKeyDraft()

        model.startOnboarding(step: .clientAccess)

        XCTAssertTrue(model.isOnboardingPresented)
        XCTAssertEqual(model.onboardingStep, .clientAccess)
        XCTAssertNil(model.onboardingManualAPIKeyDraft)
        XCTAssertEqual(presenter.showWindowCallCount, 1)

        model.onboardingManualAPIKeyDraft = DesktopAppModel.ManualAPIKeyDraft()
        model.dismissOnboarding()

        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertNil(model.onboardingManualAPIKeyDraft)
        XCTAssertEqual(presenter.closeWindowCallCount, 1)
    }

    @MainActor
    func testOnboardingWindowDidCloseSynchronizesState() {
        let presenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(onboardingWindowFactory: { _ in presenter })

        model.startOnboarding()
        model.onboardingManualAPIKeyDraft = DesktopAppModel.ManualAPIKeyDraft()
        model.onboardingWindowDidClose()

        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertNil(model.onboardingManualAPIKeyDraft)
        XCTAssertEqual(presenter.closeWindowCallCount, 0)

        model.onboardingWindowDidClose()

        XCTAssertFalse(model.isOnboardingPresented)
        XCTAssertNil(model.onboardingManualAPIKeyDraft)
    }

    @MainActor
    func testUpdatingPreferencesRefreshesOnboardingWindow() {
        let presenter = OnboardingWindowControllerSpy()
        let model = DesktopAppModel(onboardingWindowFactory: { _ in presenter })

        model.startOnboarding()
        presenter.reset()
        model.updatePreferences(showSuccessNotice: false) { preferences in
            preferences.themeMode = .dark
        }

        XCTAssertEqual(presenter.refreshWindowCallCount, 1)
    }

    @MainActor
    func testUpdateAccountPoolDisplayModePersistsWithoutChangingOtherPreferences() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try preferencesStore.save(
            DesktopPreferences(
                languageMode: .english,
                themeMode: .dark,
                interfaceMode: .full,
                accountPoolDisplayMode: .cards,
                hasSeenHelpWindow: true
            )
        )

        let model = DesktopAppModel(preferencesStore: preferencesStore)

        model.updateAccountPoolDisplayMode(.list)

        XCTAssertEqual(model.preferences.languageMode, .english)
        XCTAssertEqual(model.preferences.themeMode, .dark)
        XCTAssertEqual(model.preferences.interfaceMode, .full)
        XCTAssertEqual(model.preferences.accountPoolDisplayMode, .list)
        XCTAssertTrue(model.preferences.hasSeenHelpWindow)
        XCTAssertEqual(preferencesStore.load().accountPoolDisplayMode, .list)
    }

    @MainActor
    func testOpenAIBaseURLLabelIsLocalized() {
        let model = DesktopAppModel()

        model.preferences.languageMode = .english
        XCTAssertEqual(model.text(.labelOpenAIBaseURL), "OpenAI Base URL")
        XCTAssertEqual(model.text(.labelNaturalTokenUsage), "Natural Range Token Usage")
        XCTAssertEqual(model.text(.providerPresetGenericOpenAICompatible), "Generic OpenAI Compatible")
        XCTAssertEqual(model.text(.providerPresetAliyunQwenCodingPlan), "Aliyun / Qwen Coding Plan")
        XCTAssertEqual(model.text(.proxyTestTitle), "Test Console")
        XCTAssertEqual(
            model.text(.helperQuickActionTestProxy),
            "Open the test console to verify the current proxy path without leaving the app."
        )

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(model.text(.labelOpenAIBaseURL), "OpenAI 兼容根地址")
        XCTAssertEqual(model.text(.labelNaturalTokenUsage), "自然时间范围 Token 用量")
        XCTAssertEqual(model.text(.providerPresetGenericOpenAICompatible), "通用 OpenAI 兼容")
        XCTAssertEqual(model.text(.providerPresetAliyunQwenCodingPlan), "阿里百炼 / Qwen Coding Plan")
        XCTAssertEqual(model.text(.proxyTestTitle), "测试控制台")
        XCTAssertEqual(
            model.text(.helperQuickActionTestProxy),
            "直接打开测试控制台，在应用内验证当前代理链路是否正常。"
        )
    }

    @MainActor
    func testOverviewTrafficHintIsLocalized() {
        let model = DesktopAppModel()

        model.preferences.languageMode = .english
        XCTAssertEqual(
            model.text(.overviewTrafficHint),
            "Review local request totals at a glance, compare Today, This Week, and This Month, then inspect the latest four weeks through daily and weekly token trends."
        )

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(
            model.text(.overviewTrafficHint),
            "先看本地请求汇总，再对比今天、本周和本月的 Token 用量，并结合最近 4 周的按日、按周趋势判断流量变化。"
        )
    }

    @MainActor
    func testOutboundProxyGlobalModeHintIsLocalized() {
        let model = DesktopAppModel()

        model.preferences.languageMode = .english
        XCTAssertEqual(
            model.text(.helperOutboundProxyGlobalModeDisabled),
            "If your local proxy app is already running in global mode, keep Proxy Mode set to `Disabled` here to avoid adding an extra proxy hop."
        )

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(
            model.text(.helperOutboundProxyGlobalModeDisabled),
            "如果你本机运行的代理软件已经开启全局代理，这里的代理模式应选择 `关闭`，避免请求再次经过一层代理。"
        )
    }

    @MainActor
    func testOpenProxyTestConsoleKeepsExistingSelectedAccountDraftState() async {
        _ = NSApplication.shared

        let model = DesktopAppModel()
        model.proxyTestDraft.selectedAccountKey = "selected-account"
        model.proxyTestDraft.userPrompt = "hello from accounts"
        model.proxyTestDraft.model = "gpt-5.4"

        model.openProxyTestConsole()
        await Task.yield()

        XCTAssertTrue(model.isProxyTestPresented)
        XCTAssertEqual(model.proxyTestDraft.selectedAccountKey, "selected-account")
        XCTAssertEqual(model.proxyTestDraft.userPrompt, "hello from accounts")
        XCTAssertEqual(model.proxyTestDraft.model, "gpt-5.4")

        model.dismissProxyTestConsole()
    }

    func testAccountsQuickActionLayoutGroupsKeepPlannedOrder() {
        XCTAssertEqual(
            AccountsQuickActionLayoutGroups.primary,
            [.openAILogin, .anthropicLogin, .geminiLogin, .importCurrent, .manualAdd]
        )
        XCTAssertEqual(
            AccountsQuickActionLayoutGroups.secondary,
            [.importJSON, .exportBackup, .testProxy, .refreshUsage]
        )
        XCTAssertEqual(
            AccountsQuickActionLayoutGroups.all,
            AccountsQuickActionLayoutGroups.primary + AccountsQuickActionLayoutGroups.secondary
        )
    }

    @MainActor
    func testConnectionFieldsPreferRuntimeStatusValues() {
        let model = DesktopAppModel()
        model.settings.publicHost = "fallback.internal"
        model.settings.publicPort = 8484
        model.settings.proxyAPIKey = "sk-fallback"
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "primary", label: "Primary", key: "sk-primary-fallback", enabled: true, createdAt: 1),
        ]
        model.settings.primaryProxyAPIKeyID = "primary"
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://127.0.0.1:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://127.0.0.1:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-runtime",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )

        XCTAssertEqual(model.openAICompatibleBaseURL, "http://127.0.0.1:8787/v1")
        XCTAssertEqual(model.anthropicBaseURL, "http://127.0.0.1:8787")
        XCTAssertEqual(model.geminiBaseURL, "http://127.0.0.1:8787")
        XCTAssertEqual(model.localProxyAPIKeyValue, "sk-runtime")
        XCTAssertEqual(
            model.geminiCLIEnvironmentSnippet,
            """
            export GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:8787
            export GEMINI_API_KEY=sk-runtime
            """
        )
    }

    @MainActor
    func testConnectionFieldsFallBackToSettingsAndPrimaryAPIKey() {
        let model = DesktopAppModel()
        model.settings.publicHost = "proxy.internal"
        model.settings.publicPort = 9393
        model.settings.proxyAPIKey = "sk-legacy-fallback"
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "secondary", label: "Secondary", key: "sk-secondary", enabled: true, createdAt: 2),
            ProxyAPIKeyRecord(id: "primary", label: "Primary", key: "sk-primary", enabled: true, createdAt: 1),
        ]
        model.settings.primaryProxyAPIKeyID = "primary"
        model.status = nil

        XCTAssertEqual(model.openAICompatibleBaseURL, "http://proxy.internal:9393/v1")
        XCTAssertEqual(model.anthropicBaseURL, "http://proxy.internal:9393")
        XCTAssertEqual(model.geminiBaseURL, "http://proxy.internal:9393")
        XCTAssertEqual(model.localProxyAPIKeyValue, "sk-primary")
        XCTAssertNil(model.anthropicAccessProxyAPIKeyValue)
        XCTAssertEqual(model.anthropicAccessProxyAPIKeyDisplayValue, model.text(.statusUnavailable))
        XCTAssertEqual(model.claudeCodeEnvironmentSnippet, model.text(.statusUnavailable))
        XCTAssertEqual(
            model.geminiCLIEnvironmentSnippet,
            """
            export GOOGLE_GEMINI_BASE_URL=http://proxy.internal:9393
            export GEMINI_API_KEY=sk-primary
            """
        )
    }

    @MainActor
    func testRemoteConnectionFieldsReplaceWildcardRuntimeHostWithRemoteHost() {
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                target: .remote(
                    .init(
                        adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                        tokenProvider: { "remote-admin-token" },
                        capabilities: AdminAPIClient.Capabilities.remoteTunnel
                    )
                )
            )
        )
        model.remoteAccessibleHostOverride = "tokyo.example.com"
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://0.0.0.0:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://localhost:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-runtime",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )
        NSPasteboard.general.clearContents()

        XCTAssertEqual(model.openAICompatibleBaseURL, "http://tokyo.example.com:8787/v1")
        XCTAssertEqual(model.anthropicBaseURL, "http://tokyo.example.com:8787")
        XCTAssertEqual(model.geminiBaseURL, "http://tokyo.example.com:8787")

        model.copyCurrentProxyTestEndpoint()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "http://tokyo.example.com:8787/v1")
    }

    @MainActor
    func testRemoteConnectionFieldsKeepReachableRuntimeHostUnchanged() {
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                target: .remote(
                    .init(
                        adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                        tokenProvider: { "remote-admin-token" },
                        capabilities: AdminAPIClient.Capabilities.remoteTunnel
                    )
                )
            )
        )
        model.remoteAccessibleHostOverride = "tokyo.example.com"
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://reachable.example.com:8787/v1",
            anthropicBaseURL: "http://reachable.example.com:8787",
            geminiBaseURL: "http://reachable.example.com:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-runtime",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )

        XCTAssertEqual(model.openAICompatibleBaseURL, "http://reachable.example.com:8787/v1")
        XCTAssertEqual(model.anthropicBaseURL, "http://reachable.example.com:8787")
        XCTAssertEqual(model.geminiBaseURL, "http://reachable.example.com:8787")
    }

    @MainActor
    func testOverviewServiceButtonsUseStoppedStateTitlesAndAvailability() {
        let model = DesktopAppModel()
        model.localServiceStatus = Self.makeLocalServiceStatus(running: false)
        model.status = nil

        XCTAssertEqual(model.localStartButtonTitle, model.text(.actionStartDaemon))
        XCTAssertTrue(model.localCanStartService)
        XCTAssertEqual(model.localStopButtonTitle, model.text(.actionDaemonAlreadyStopped))
        XCTAssertFalse(model.localCanStopService)
    }

    @MainActor
    func testOverviewServiceButtonsUseRunningStateTitlesAndAvailability() {
        let model = DesktopAppModel()
        model.localServiceStatus = Self.makeLocalServiceStatus(running: true)
        model.status = Self.makeProxyStatus(running: true)

        XCTAssertEqual(model.localStartButtonTitle, model.text(.actionDaemonAlreadyRunning))
        XCTAssertFalse(model.localCanStartService)
        XCTAssertEqual(model.localStopButtonTitle, model.text(.actionStopDaemon))
        XCTAssertTrue(model.localCanStopService)
    }

    @MainActor
    func testOverviewServiceButtonsReflectTransitionStates() {
        let model = DesktopAppModel()
        model.localServiceStatus = Self.makeLocalServiceStatus(running: true)
        model.status = Self.makeProxyStatus(running: true)

        model.localServiceOperation = .starting
        XCTAssertEqual(model.localStartButtonTitle, model.text(.statusStarting))
        XCTAssertFalse(model.localCanStartService)
        XCTAssertFalse(model.localCanStopService)

        model.localServiceOperation = .stopping
        XCTAssertEqual(model.localStopButtonTitle, model.text(.statusStopping))
        XCTAssertFalse(model.localCanStartService)
        XCTAssertFalse(model.localCanStopService)
    }

    @MainActor
    func testSidebarBrandSummaryUsesTotalAccountCountInsteadOfFilteredResults() {
        let model = DesktopAppModel()
        model.accounts = [
            Self.makeAccount(id: "account-1", label: "Primary Account", accountID: "acct-primary"),
            Self.makeAccount(id: "account-2", label: "Backup Account", accountID: "acct-backup"),
        ]
        model.accountPoolFilters = AccountPoolFilterState(searchQuery: "Primary")

        let summary = model.sidebarBrandSummary

        XCTAssertEqual(model.visibleAccountPoolAccounts.count, 1)
        XCTAssertEqual(summary.accountCountText, model.accountPoolTotalCountText)
        XCTAssertEqual(summary.accountCountText, "2")
    }

    @MainActor
    func testSidebarBrandSummaryUsesShellServiceStatusPresentation() {
        let model = DesktopAppModel()
        model.localServiceStatus = LocalServiceStatus(
            installed: true,
            running: true,
            launchctlState: "running",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://127.0.0.1:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://127.0.0.1:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-local",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )
        model.stats = AdminStatsSummary(
            totalRequests: 42,
            totalFailures: 1,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 120,
            totalOutputTokens: 320,
            totalTokens: 440,
            latestBuckets: []
        )

        let summary = model.sidebarBrandSummary

        XCTAssertEqual(summary.serviceText, model.shellServiceStatusText)
        XCTAssertEqual(summary.serviceTone, model.shellServiceStatusTone)
        XCTAssertEqual(summary.requestCountText, "42")
    }

    @MainActor
    func testOverviewNaturalTokenCardsFollowTodayWeekMonthOrder() {
        let model = DesktopAppModel()
        model.stats = AdminStatsSummary(
            totalRequests: 0,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            naturalTokenUsage: .init(
                today: .init(requestCount: 2, inputTokens: 12, outputTokens: 8),
                week: .init(requestCount: 6, inputTokens: 48, outputTokens: 16),
                month: .init(requestCount: 12, inputTokens: 120, outputTokens: 40)
            ),
            latestBuckets: []
        )

        let cards = model.overviewNaturalTokenCards

        XCTAssertEqual(cards.map(\.title), [
            model.text(.optionToday),
            model.text(.optionThisWeek),
            model.text(.optionThisMonth),
        ])
        XCTAssertEqual(cards.map(\.requestCount), [2, 6, 12])
        XCTAssertEqual(cards.map(\.inputTokens), [12, 48, 120])
        XCTAssertEqual(cards.map(\.outputTokens), [8, 16, 40])
        XCTAssertEqual(cards.map(\.totalTokens), [20, 64, 160])
    }

    @MainActor
    func testOverviewNaturalTokenCardsDeriveTotalTokensFromInputAndOutput() {
        let model = DesktopAppModel()
        model.stats = AdminStatsSummary(
            totalRequests: 0,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            naturalTokenUsage: .init(
                today: .init(requestCount: 4, inputTokens: 1_200, outputTokens: 3_400),
                week: .init(requestCount: 1, inputTokens: 50, outputTokens: 70),
                month: .init(requestCount: 9, inputTokens: 0, outputTokens: 999)
            ),
            latestBuckets: []
        )

        let cards = model.overviewNaturalTokenCards

        XCTAssertEqual(cards[0].totalTokens, cards[0].inputTokens + cards[0].outputTokens)
        XCTAssertEqual(cards[1].totalTokens, cards[1].inputTokens + cards[1].outputTokens)
        XCTAssertEqual(cards[2].totalTokens, cards[2].inputTokens + cards[2].outputTokens)
    }

    @MainActor
    func testOverviewNaturalTokenCardsPreserveZeroValueRanges() {
        let model = DesktopAppModel()
        model.stats = AdminStatsSummary(
            totalRequests: 0,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            naturalTokenUsage: .init(
                today: .init(requestCount: 0, inputTokens: 0, outputTokens: 0),
                week: .init(requestCount: 0, inputTokens: 0, outputTokens: 0),
                month: .init(requestCount: 0, inputTokens: 0, outputTokens: 0)
            ),
            latestBuckets: []
        )

        let cards = model.overviewNaturalTokenCards

        XCTAssertEqual(cards.map(\.requestCount), [0, 0, 0])
        XCTAssertEqual(cards.map(\.totalTokens), [0, 0, 0])
        XCTAssertEqual(cards.map(\.inputTokens), [0, 0, 0])
        XCTAssertEqual(cards.map(\.outputTokens), [0, 0, 0])
    }

    @MainActor
    func testOverviewRecentWeekOptionsDefaultToThisWeekAndStayLocalized() {
        let model = DesktopAppModel()

        XCTAssertEqual(model.selectedOverviewTrafficWeekOffset, 0)

        model.preferences.languageMode = .english
        XCTAssertEqual(model.overviewRecentWeekOptions.map(\.title), [
            model.text(.optionThisWeek),
            model.text(.optionLastWeek),
            model.text(.optionTwoWeeksAgo),
            model.text(.optionThreeWeeksAgo),
        ])

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(model.overviewRecentWeekOptions.map(\.title), [
            model.text(.optionThisWeek),
            model.text(.optionLastWeek),
            model.text(.optionTwoWeeksAgo),
            model.text(.optionThreeWeeksAgo),
        ])
    }

    @MainActor
    func testOverviewRecentWeekRangeTextFollowsLanguageMode() throws {
        let model = DesktopAppModel()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        func makeDate(year: Int, month: Int, day: Int) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 15)

        model.preferences.languageMode = .english
        XCTAssertEqual(
            model.overviewSelectedRecentWeekOption(now: now, calendar: calendar).rangeText,
            "Apr 13 - Apr 19"
        )
        XCTAssertEqual(
            model.overviewRecentFourWeeksRangeText(now: now, calendar: calendar),
            "Mar 23 - Apr 19"
        )

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(
            model.overviewSelectedRecentWeekOption(now: now, calendar: calendar).rangeText,
            "4月13日 - 4月19日"
        )
        XCTAssertEqual(
            model.overviewRecentFourWeeksRangeText(now: now, calendar: calendar),
            "3月23日 - 4月19日"
        )
    }

    @MainActor
    func testOverviewSelectedDailyTrendPointsProvideSevenSlotsAndFutureDaysStayEmpty() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 15, hour: 12, minute: 30)
        let monday = try makeDate(year: 2026, month: 4, day: 13)
        let wednesday = try makeDate(year: 2026, month: 4, day: 15)

        model.stats = AdminStatsSummary(
            totalRequests: 0,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            naturalTokenUsage: .init(
                dailyTrend: [
                    .init(bucketStart: Int64(monday.timeIntervalSince1970), windowSeconds: 86_400, requestCount: 1, inputTokens: 10, outputTokens: 5),
                    .init(bucketStart: Int64(wednesday.timeIntervalSince1970), windowSeconds: 86_400, requestCount: 2, inputTokens: 20, outputTokens: 6),
                ]
            ),
            latestBuckets: []
        )

        let points = model.overviewSelectedDailyTrendPoints(now: now, calendar: calendar)

        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points[0].xAxisPrimaryLabel, "Mon")
        XCTAssertEqual(points[0].xAxisSecondaryLabel, "Apr 13")
        XCTAssertEqual(points[0].title, "Apr 13")
        XCTAssertEqual(points[0].detailText, "Mon")
        XCTAssertEqual(points[2].xAxisPrimaryLabel, "Wed")
        XCTAssertEqual(points[2].xAxisSecondaryLabel, "Apr 15")
        XCTAssertEqual(points[0].totalTokens, 15)
        XCTAssertEqual(points[0].inputTokens, 10)
        XCTAssertEqual(points[0].outputTokens, 5)
        XCTAssertEqual(points[1].totalTokens, 0)
        XCTAssertEqual(points[1].inputTokens, 0)
        XCTAssertEqual(points[1].outputTokens, 0)
        XCTAssertEqual(points[2].totalTokens, 26)
        XCTAssertEqual(points[2].inputTokens, 20)
        XCTAssertEqual(points[2].outputTokens, 6)
        XCTAssertNil(points[3].totalTokens)
        XCTAssertNil(points[3].inputTokens)
        XCTAssertNil(points[3].outputTokens)
        XCTAssertNil(points[6].totalTokens)
        XCTAssertNil(points[6].inputTokens)
        XCTAssertNil(points[6].outputTokens)
    }

    @MainActor
    func testOverviewSelectedDailyTrendPointsLocalizeXAxisLabelsForZhHans() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 15, hour: 12, minute: 30)

        let points = model.overviewSelectedDailyTrendPoints(now: now, calendar: calendar)

        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points[0].xAxisPrimaryLabel, "周一")
        XCTAssertEqual(points[0].xAxisSecondaryLabel, "4月13日")
        XCTAssertEqual(points[0].title, "4月13日")
        XCTAssertEqual(points[0].detailText, "周一")
        XCTAssertEqual(points[2].xAxisPrimaryLabel, "周三")
        XCTAssertEqual(points[2].xAxisSecondaryLabel, "4月15日")
    }

    @MainActor
    func testOverviewWeeklyTrendPointsStayAscendingAcrossRecentFourWeeks() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        func makeDate(year: Int, month: Int, day: Int) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 15)
        let currentWeek = try makeDate(year: 2026, month: 4, day: 13)
        let lastWeek = try makeDate(year: 2026, month: 4, day: 6)
        let twoWeeksAgo = try makeDate(year: 2026, month: 3, day: 30)
        let threeWeeksAgo = try makeDate(year: 2026, month: 3, day: 23)

        model.stats = AdminStatsSummary(
            totalRequests: 0,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            naturalTokenUsage: .init(
                weeklyTrend: [
                    .init(bucketStart: Int64(threeWeeksAgo.timeIntervalSince1970), windowSeconds: 604_800, requestCount: 1, inputTokens: 11, outputTokens: 1),
                    .init(bucketStart: Int64(twoWeeksAgo.timeIntervalSince1970), windowSeconds: 604_800, requestCount: 2, inputTokens: 22, outputTokens: 2),
                    .init(bucketStart: Int64(lastWeek.timeIntervalSince1970), windowSeconds: 604_800, requestCount: 3, inputTokens: 33, outputTokens: 3),
                    .init(bucketStart: Int64(currentWeek.timeIntervalSince1970), windowSeconds: 604_800, requestCount: 4, inputTokens: 44, outputTokens: 4),
                ]
            ),
            latestBuckets: []
        )

        let points = model.overviewWeeklyTrendPoints(now: now, calendar: calendar)

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.map(\.title), [
            model.text(.optionThreeWeeksAgo),
            model.text(.optionTwoWeeksAgo),
            model.text(.optionLastWeek),
            model.text(.optionThisWeek),
        ])
        XCTAssertEqual(points.map(\.xAxisPrimaryLabel), [
            model.text(.optionThreeWeeksAgo),
            model.text(.optionTwoWeeksAgo),
            model.text(.optionLastWeek),
            model.text(.optionThisWeek),
        ])
        XCTAssertEqual(points.map(\.xAxisSecondaryLabel), [
            "Mar 23-Mar 29",
            "Mar 30-Apr 5",
            "Apr 6-Apr 12",
            "Apr 13-Apr 19",
        ])
        XCTAssertEqual(points.map { $0.totalTokens ?? -1 }, [12, 24, 36, 48])
        XCTAssertEqual(points.map { $0.inputTokens ?? -1 }, [11, 22, 33, 44])
        XCTAssertEqual(points.map { $0.outputTokens ?? -1 }, [1, 2, 3, 4])
        XCTAssertTrue(points.map(\.bucketStart) == points.map(\.bucketStart).sorted())

        model.selectedOverviewTrafficWeekOffset = 2
        let unchanged = model.overviewWeeklyTrendPoints(now: now, calendar: calendar)
        XCTAssertEqual(unchanged, points)
    }

    @MainActor
    func testOverviewWeeklyTrendPointsLocalizeXAxisLabelsForZhHans() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        func makeDate(year: Int, month: Int, day: Int) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            return try XCTUnwrap(calendar.date(from: components))
        }

        let now = try makeDate(year: 2026, month: 4, day: 15)
        let points = model.overviewWeeklyTrendPoints(now: now, calendar: calendar)

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.map(\.xAxisPrimaryLabel), [
            model.text(.optionThreeWeeksAgo),
            model.text(.optionTwoWeeksAgo),
            model.text(.optionLastWeek),
            model.text(.optionThisWeek),
        ])
        XCTAssertEqual(points.map(\.xAxisSecondaryLabel), [
            "3月23日-3月29日",
            "3月30日-4月5日",
            "4月6日-4月12日",
            "4月13日-4月19日",
        ])
        XCTAssertEqual(points[3].title, model.text(.optionThisWeek))
        XCTAssertEqual(points[3].detailText, "4月13日 - 4月19日")
    }

    @MainActor
    func testOverviewTrendPointSelectionHelpersMapPlotCoordinatesToNearestBucket() throws {
        let model = DesktopAppModel()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        func makeDate(year: Int, month: Int, day: Int) throws -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            return try XCTUnwrap(calendar.date(from: components))
        }

        let monday = try makeDate(year: 2026, month: 4, day: 13)
        let tuesday = try makeDate(year: 2026, month: 4, day: 14)
        let points = [
            OverviewTrafficTrendPoint(
                bucketStart: Int64(monday.timeIntervalSince1970),
                date: monday,
                xAxisPrimaryLabel: "Mon",
                xAxisSecondaryLabel: "Apr 13",
                title: "Apr 13",
                detailText: "Mon",
                totalTokens: 15,
                inputTokens: 10,
                outputTokens: 5,
                requestCount: 1,
                isFuture: false
            ),
            OverviewTrafficTrendPoint(
                bucketStart: Int64(tuesday.timeIntervalSince1970),
                date: tuesday,
                xAxisPrimaryLabel: "Tue",
                xAxisSecondaryLabel: "Apr 14",
                title: "Apr 14",
                detailText: "Tue",
                totalTokens: 26,
                inputTokens: 20,
                outputTokens: 6,
                requestCount: 2,
                isFuture: false
            ),
        ]

        XCTAssertEqual(model.overviewTrendPointIndex(for: -5, plotWidth: 200, pointCount: points.count), 0)
        XCTAssertEqual(model.overviewTrendPointIndex(for: 190, plotWidth: 200, pointCount: points.count), 1)
        XCTAssertEqual(model.overviewTrendPoint(for: 140, plotWidth: 200, points: points)?.bucketStart, points[1].bucketStart)
        XCTAssertEqual(model.overviewTrendPointXPosition(at: 1, plotWidth: 200, pointCount: points.count), 200)

        let repeatedHover = model.overviewHoverBucketStart(
            current: points[1].bucketStart,
            plotX: 160,
            plotWidth: 200,
            points: points
        )
        XCTAssertEqual(repeatedHover, points[1].bucketStart)

        let clearedHover = model.overviewHoverBucketStart(
            current: points[1].bucketStart,
            plotX: nil,
            plotWidth: 200,
            points: points
        )
        XCTAssertNil(clearedHover)
    }

    @MainActor
    func testStatsAutoRefreshImmediatelyLoadsLatestRequestCount() async {
        let probe = StatsRefreshProbe(
            responses: [Self.makeStatsSummary(totalRequests: 7)]
        )
        let admin = AdminAPIClient(
            getStatsHandler: { await probe.nextStats() }
        )
        let model = DesktopAppModel(admin: admin)
        defer { model.stopStatsAutoRefresh() }

        model.startStatsAutoRefreshIfNeeded()

        await Self.waitForCondition { model.stats.totalRequests == 7 }

        let callCount = await probe.snapshot()
        XCTAssertGreaterThanOrEqual(callCount, 1)
        XCTAssertEqual(model.stats.totalRequests, 7)
        XCTAssertEqual(model.sidebarBrandSummary.requestCountText, "7")
    }

    @MainActor
    func testStatsAutoRefreshRepeatsUsingConfiguredInterval() async {
        let probe = StatsRefreshProbe(
            responses: [
                Self.makeStatsSummary(totalRequests: 11),
                Self.makeStatsSummary(totalRequests: 12),
            ]
        )
        let admin = AdminAPIClient(
            getStatsHandler: { await probe.nextStats() }
        )
        let model = DesktopAppModel(admin: admin)
        model.statsAutoRefreshInterval = .milliseconds(40)
        defer { model.stopStatsAutoRefresh() }

        model.startStatsAutoRefreshIfNeeded()

        await Self.waitForCondition(timeout: .seconds(1.5)) {
            model.stats.totalRequests == 12
        }
        model.stopStatsAutoRefresh()

        let callCount = await probe.snapshot()
        XCTAssertGreaterThanOrEqual(callCount, 2)
        XCTAssertEqual(model.stats.totalRequests, 12)
    }

    @MainActor
    func testStopStatsAutoRefreshPreventsFurtherPolling() async {
        let probe = StatsRefreshProbe(
            responses: [
                Self.makeStatsSummary(totalRequests: 21),
                Self.makeStatsSummary(totalRequests: 22),
            ]
        )
        let admin = AdminAPIClient(
            getStatsHandler: { await probe.nextStats() }
        )
        let model = DesktopAppModel(admin: admin)
        model.statsAutoRefreshInterval = .milliseconds(80)

        model.startStatsAutoRefreshIfNeeded()
        await Self.waitForCondition { model.stats.totalRequests == 21 }
        model.stopStatsAutoRefresh()

        try? await Task.sleep(for: .milliseconds(180))

        let callCount = await probe.snapshot()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(model.stats.totalRequests, 21)
    }

    @MainActor
    func testPresentManualAPIKeySheetUsesDefaultBaseURLAndEnabledState() {
        let model = DesktopAppModel()

        model.presentManualAPIKeySheet()

        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, OpenAICompatibleUpstream.defaultBaseURL)
        XCTAssertEqual(model.manualAPIKeyDraft?.enabled, true)
    }

    @MainActor
    func testUpdateManualAPIKeyProviderPresetSwitchesOnlyDefaultBaseURL() {
        let model = DesktopAppModel()
        model.presentManualAPIKeySheet()

        model.updateManualAPIKeyProviderPreset(.aliyunQwenCodingPlan)
        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .aliyunQwenCodingPlan)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, OpenAICompatibleProviderPreset.aliyunQwenCodingPlan.defaultBaseURL)

        model.manualAPIKeyDraft?.baseURL = "https://custom.example.com"
        model.updateManualAPIKeyProviderPreset(.genericOpenAICompatible)

        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, "https://custom.example.com")
    }

    @MainActor
    func testManualAPIKeyDraftUpstreamAdapterSwitchesBackToResponses() {
        let model = DesktopAppModel()
        let chatDraft = DesktopAppModel.ManualAPIKeyDraft(
            providerPreset: .genericOpenAICompatible,
            baseURL: "https://api.example.com",
            upstreamAdapter: .chatCompletions,
            apiKey: "sk-test"
        )

        let responsesDraft = model.manualAPIKeyDraft(
            chatDraft,
            updatingUpstreamAdapter: .responses
        )

        XCTAssertEqual(responsesDraft.upstreamAdapter, .responses)

        let chatAgainDraft = model.manualAPIKeyDraft(
            responsesDraft,
            updatingUpstreamAdapter: .chatCompletions
        )

        XCTAssertEqual(chatAgainDraft.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(chatAgainDraft.upstreamAdapter, .chatCompletions)
    }

    @MainActor
    func testManualAPIKeyPresetTextHelpAndPlaceholdersCoverAnthropicAndGemini() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        XCTAssertTrue(model.manualAPIKeyProviderPresetHelp(.genericOpenAICompatible).contains("Google Gemini Compatible"))
        XCTAssertEqual(
            model.providerPresetText(.anthropicAPICompatible),
            model.text(.providerPresetAnthropicAPICompatible)
        )
        XCTAssertEqual(
            model.manualAPIKeyBaseURLPlaceholder(for: .anthropicAPICompatible),
            model.text(.placeholderAnthropicAPICompatibleBaseURL)
        )
        XCTAssertTrue(model.manualAPIKeyProviderPresetHelp(.anthropicAPICompatible).contains("Anthropic"))

        XCTAssertEqual(
            model.providerPresetText(.googleGeminiCompatible),
            model.text(.providerPresetGoogleGeminiCompatible)
        )
        XCTAssertEqual(
            model.manualAPIKeyBaseURLPlaceholder(for: .googleGeminiCompatible),
            model.text(.placeholderGoogleGeminiCompatibleBaseURL)
        )
        XCTAssertTrue(model.manualAPIKeyProviderPresetHelp(.googleGeminiCompatible).contains("Gemini"))
        XCTAssertTrue(model.manualAPIKeyProviderPresetHelp(.googleGeminiCompatible).contains("Google AI Studio"))
        XCTAssertFalse(model.manualAPIKeyProviderPresetHelp(.googleGeminiCompatible).contains("Google AI Pro"))
        XCTAssertFalse(model.manualAPIKeyProviderPresetHelp(.googleGeminiCompatible).localizedCaseInsensitiveContains("account pool"))
    }

    @MainActor
    func testUpdateManualAPIKeyProviderPresetSwitchesAnthropicAndGeminiDefaultsOnlyWhenStillDefault() {
        let model = DesktopAppModel()
        model.presentManualAPIKeySheet()

        model.updateManualAPIKeyProviderPreset(.anthropicAPICompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .anthropicAPICompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, AnthropicAPIKeyUpstream.defaultBaseURL)

        model.updateManualAPIKeyProviderPreset(.googleGeminiCompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .googleGeminiCompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, OpenAICompatibleUpstream.defaultGeminiBaseURL)

        model.manualAPIKeyDraft?.baseURL = "https://custom.example.com/root"
        model.updateManualAPIKeyProviderPreset(.anthropicAPICompatible)

        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .anthropicAPICompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, "https://custom.example.com/root")
    }

    @MainActor
    func testAccountProviderPresetTextSupportsAnthropicAndGeminiManualAccounts() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        let anthropic = Self.makeAccount(
            id: "anthropic-api",
            label: "Anthropic API",
            accountID: "acct-anthropic-api",
            authMode: .anthropicAPIKey,
            providerPreset: .anthropicAPICompatible,
            upstreamBaseURL: "https://api.anthropic.com"
        )
        let gemini = Self.makeAccount(
            id: "gemini-api",
            label: "Gemini API",
            accountID: "acct-gemini-api",
            authMode: .openAIAPIKey,
            providerPreset: .googleGeminiCompatible,
            upstreamBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
        )

        XCTAssertEqual(model.accountProviderPresetText(anthropic), model.text(.providerPresetAnthropicAPICompatible))
        XCTAssertEqual(model.accountProviderPresetText(gemini), model.text(.providerPresetGoogleGeminiCompatible))
        XCTAssertEqual(model.accountAuthModeText(anthropic), "Anthropic API Key")
    }

    @MainActor
    func testAccountsHelpDocumentDescribesCompatibleManualAPIKeyPresets() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        let accountsTopic = model.helpDocument.topic(for: .accounts)
        let importSection = accountsTopic.sections.first { $0.id == "accounts-import" }

        XCTAssertNotNil(importSection)
        XCTAssertTrue(importSection?.bullets.contains(where: {
            $0.contains("Anthropic API-compatible")
                && $0.contains("Google Gemini-compatible")
                && $0.contains("OpenAI-compatible")
        }) == true)
        XCTAssertTrue(importSection?.bullets.contains(where: {
            $0.contains("Google / Gemini Login")
                && $0.contains("free-tier auto-onboarding")
        }) == true)
        XCTAssertFalse(importSection?.bullets.contains(where: {
            $0.contains("OpenAI-compatible API key accounts and requires")
        }) == true)
    }

    @MainActor
    func testManualAPIKeyPresetHelperTextExplains404FallbackHelloProbe() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        XCTAssertTrue(model.text(.helperManualAccountGenericOpenAICompatible).contains("final upstream API prefix"))
        XCTAssertTrue(model.text(.helperManualAccountAnthropicAPICompatible).contains("/v1/messages"))
        XCTAssertTrue(model.text(.helperManualAccountAnthropicAPICompatible).contains("你好"))
        XCTAssertTrue(model.text(.helperManualAccountGoogleGeminiCompatible).contains("404/405"))
        XCTAssertTrue(model.text(.helperManualAccountGoogleGeminiCompatible).contains("chat/completions"))

        model.preferences.languageMode = .zhHans

        XCTAssertTrue(model.text(.helperManualAccountGenericOpenAICompatible).contains("最终 API 前缀"))
        XCTAssertTrue(model.text(.helperManualAccountAnthropicAPICompatible).contains("`/v1/messages`"))
        XCTAssertTrue(model.text(.helperManualAccountGoogleGeminiCompatible).contains("chat/completions"))
    }

    @MainActor
    func testGeminiOAuthCopyUsesGoogleGeminiLoginBranding() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let geminiOAuth = Self.makeAccount(
            id: "gemini-oauth",
            label: "Gemini OAuth",
            accountID: "acct-gemini-oauth",
            authMode: .geminiOAuth
        )

        XCTAssertEqual(model.accountAuthModeText(geminiOAuth), "Google / Gemini Login")
        XCTAssertEqual(model.oauthLoginTitle(for: .gemini), "Google / Gemini Login")
        XCTAssertEqual(model.oauthFlowTitle(for: .gemini), "Google / Gemini Web Sign-In")
        XCTAssertTrue(model.oauthQuickActionHelp(for: .gemini).contains("Google / Gemini"))
        XCTAssertTrue(model.oauthQuickActionHelp(for: .gemini).contains("Gemini CLI"))
        XCTAssertFalse(model.oauthQuickActionHelp(for: .gemini).contains("Google AI Pro"))
        XCTAssertTrue(model.oauthManualHint(for: .gemini).contains("Google / Gemini"))
        XCTAssertFalse(model.proxyDataSourceDetailText(.gemini).contains("Google AI Pro"))
    }

    @MainActor
    func testToolsHelpDocumentExplainsGeminiLoopDetectionIsClientSide() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        let toolsTopic = model.helpDocument.topic(for: .tools)
        let requestLogsSection = toolsTopic.sections.first { $0.id == "tools-request-logs" }

        XCTAssertNotNil(requestLogsSection)
        XCTAssertTrue(requestLogsSection?.bullets.contains(where: {
            $0.contains("A potential loop was detected")
                && $0.contains("Gemini CLI itself")
                && $0.contains("request logs")
        }) == true)
    }

    @MainActor
    func testProxyHelpDocumentAdvancedSectionOmitsGeminiModelMapping() {
        let englishModel = DesktopAppModel()
        englishModel.preferences.languageMode = .english

        let englishSection = englishModel.helpDocument
            .topic(for: .proxy)
            .sections
            .first { $0.id == "proxy-tools" }

        XCTAssertNotNil(englishSection)
        XCTAssertFalse(englishSection?.summary.localizedCaseInsensitiveContains("gemini model mapping") == true)
        XCTAssertTrue(englishSection?.summary.localizedCaseInsensitiveContains("network settings") == true)
        XCTAssertTrue(englishSection?.bullets.contains(where: {
            $0.contains("Anthropic model mapping")
                && $0.contains("local network settings")
        }) == true)

        let chineseModel = DesktopAppModel()
        chineseModel.preferences.languageMode = .zhHans

        let chineseSection = chineseModel.helpDocument
            .topic(for: .proxy)
            .sections
            .first { $0.id == "proxy-tools" }

        XCTAssertNotNil(chineseSection)
        XCTAssertFalse(chineseSection?.summary.contains("Gemini 模型映射") == true)
        XCTAssertTrue(chineseSection?.summary.contains("本地网络设置") == true)
        XCTAssertTrue(chineseSection?.bullets.contains(where: {
            $0.contains("Anthropic 模型映射")
                && $0.contains("本地网络设置")
        }) == true)
    }

    @MainActor
    func testHelpDocumentHidesRemoteTopicUntilRemoteManagementUnlocks() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        XCTAssertFalse(model.helpDocument.topics.contains(where: { $0.id == .remote }))

        Self.unlockRemoteManagement(on: model)

        XCTAssertTrue(model.helpDocument.topics.contains(where: { $0.id == .remote }))
    }

    @MainActor
    func testOpenEditAPIKeyAccountSheetLoadsEditableFieldsFromAdminDetails() async throws {
        let account = Self.makeAccount(
            id: "api-account",
            label: "Editable API",
            accountID: "acct-api",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/proxy"
        )
        let admin = AdminAPIClient(
            manualAPIKeyAccountDetailsHandler: { id in
                XCTAssertEqual(id, account.id)
                return ManualAPIKeyAccountDetails(
                    label: "Loaded API",
                    providerPreset: .aliyunQwenCodingPlan,
                    baseURL: "https://loaded.example.com/root",
                    apiKey: "sk-loaded-secret",
                    enabled: false,
                    automaticCooldownDisabled: true
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        await model.openEditAPIKeyAccountSheet(account)

        XCTAssertEqual(model.manualAPIKeyDraft?.editingAccountID, account.id)
        XCTAssertEqual(model.manualAPIKeyDraft?.originalAccountKey, account.accountKey)
        XCTAssertEqual(model.manualAPIKeyDraft?.label, "Loaded API")
        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .aliyunQwenCodingPlan)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, "https://loaded.example.com/root")
        XCTAssertEqual(model.manualAPIKeyDraft?.apiKey, "sk-loaded-secret")
        XCTAssertEqual(model.manualAPIKeyDraft?.enabled, false)
        XCTAssertEqual(model.manualAPIKeyDraft?.automaticCooldownDisabled, true)
        let draft = try XCTUnwrap(model.manualAPIKeyDraft)
        XCTAssertEqual(model.manualAPIKeySheetTitle(for: draft), model.text(.actionEditAPIKey))
    }

    @MainActor
    func testOpenEditAPIKeyAccountSheetIgnoresNonAPIKeyAccounts() async {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "chatgpt-account",
            label: "ChatGPT",
            accountID: "acct-chatgpt"
        )

        await model.openEditAPIKeyAccountSheet(account)

        XCTAssertNil(model.manualAPIKeyDraft)
    }

    @MainActor
    func testResolvedManualAPIKeyDraftFallsBackToPresentedEditDraftAfterDismiss() {
        let model = DesktopAppModel()
        let presentedDraft = DesktopAppModel.ManualAPIKeyDraft(
            label: "Editable API",
            baseURL: "https://example.com/edit",
            apiKey: "sk-edit",
            enabled: false,
            editingAccountID: "api-account",
            originalAccountKey: "key-before-edit"
        )
        model.manualAPIKeyDraft = presentedDraft

        model.dismissManualAPIKeySheet()

        let resolvedDraft = model.resolvedManualAPIKeyDraft(for: presentedDraft)
        XCTAssertEqual(resolvedDraft, presentedDraft)
        XCTAssertTrue(resolvedDraft.isEditing)
    }

    @MainActor
    func testManualAPIKeySheetTitleUsesPresentedEditDraftAfterDismiss() {
        let model = DesktopAppModel()
        let presentedDraft = DesktopAppModel.ManualAPIKeyDraft(
            label: "Editable API",
            baseURL: "https://example.com/edit",
            apiKey: "sk-edit",
            enabled: false,
            editingAccountID: "api-account",
            originalAccountKey: "key-before-edit"
        )
        model.manualAPIKeyDraft = presentedDraft

        model.dismissManualAPIKeySheet()

        XCTAssertEqual(
            model.manualAPIKeySheetTitle(for: presentedDraft),
            model.text(.actionEditAPIKey)
        )
    }

    @MainActor
    func testOpenEditAPIKeyAccountSheetFailureShowsErrorBanner() async {
        let account = Self.makeAccount(
            id: "api-account",
            label: "Editable API",
            accountID: "acct-api",
            authMode: .openAIAPIKey
        )
        let admin = AdminAPIClient(
            manualAPIKeyAccountDetailsHandler: { _ in
                throw ProxyError.message("cannot load saved API key")
            }
        )
        let model = DesktopAppModel(admin: admin)

        await model.openEditAPIKeyAccountSheet(account)

        XCTAssertNil(model.manualAPIKeyDraft)
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertEqual(model.banners.first?.title, model.text(.errorAccountManagementFailed))
        XCTAssertTrue(model.banners.first?.detail?.contains("cannot load saved API key") == true)
    }

    @MainActor
    func testOpenEditAPIKeyAccountSheetIgnoresStaleResponse() async {
        let firstAccount = Self.makeAccount(
            id: "api-account-1",
            label: "First API",
            accountID: "acct-api-1",
            authMode: .openAIAPIKey
        )
        let secondAccount = Self.makeAccount(
            id: "api-account-2",
            label: "Second API",
            accountID: "acct-api-2",
            authMode: .openAIAPIKey
        )
        let admin = AdminAPIClient(
            manualAPIKeyAccountDetailsHandler: { id in
                if id == firstAccount.id {
                    try? await Task.sleep(for: .milliseconds(80))
                    return ManualAPIKeyAccountDetails(
                        label: "First Loaded",
                        baseURL: "https://first.example.com",
                        apiKey: "sk-first",
                        enabled: true
                    )
                }
                try? await Task.sleep(for: .milliseconds(10))
                return ManualAPIKeyAccountDetails(
                    label: "Second Loaded",
                    baseURL: "https://second.example.com",
                    apiKey: "sk-second",
                    enabled: false
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        let firstTask = Task { await model.openEditAPIKeyAccountSheet(firstAccount) }
        try? await Task.sleep(for: .milliseconds(5))
        let secondTask = Task { await model.openEditAPIKeyAccountSheet(secondAccount) }

        _ = await firstTask.value
        _ = await secondTask.value

        XCTAssertEqual(model.manualAPIKeyDraft?.editingAccountID, secondAccount.id)
        XCTAssertEqual(model.manualAPIKeyDraft?.label, "Second Loaded")
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, "https://second.example.com")
        XCTAssertEqual(model.manualAPIKeyDraft?.apiKey, "sk-second")
        XCTAssertEqual(model.manualAPIKeyDraft?.enabled, false)
    }

    @MainActor
    func testOpenRenameAccountSheetPrefillsOAuthLabel() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "chatgpt-account",
            label: "Primary OAuth",
            accountID: "acct-chatgpt"
        )

        model.openRenameAccountSheet(account)

        XCTAssertEqual(model.accountLabelDraft?.accountID, account.id)
        XCTAssertEqual(model.accountLabelDraft?.accountKey, account.accountKey)
        XCTAssertEqual(model.accountLabelDraft?.label, account.label)
        XCTAssertEqual(model.accountLabelSheetTitle, model.text(.actionEditAccountName))
    }

    @MainActor
    func testOpenRenameAccountSheetSupportsAnthropicOAuthAccounts() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "anthropic-account",
            label: "Claude OAuth",
            accountID: "acct-anthropic",
            authMode: .anthropicSubscriptionOAuth
        )

        model.openRenameAccountSheet(account)

        XCTAssertEqual(model.accountLabelDraft?.accountID, account.id)
        XCTAssertEqual(model.accountLabelDraft?.accountKey, account.accountKey)
        XCTAssertEqual(model.accountLabelDraft?.label, account.label)
    }

    @MainActor
    func testOpenRenameAccountSheetIgnoresAPIKeyAccounts() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "api-account",
            label: "API Key",
            accountID: "acct-api",
            authMode: .openAIAPIKey
        )

        model.openRenameAccountSheet(account)

        XCTAssertNil(model.accountLabelDraft)
    }

    @MainActor
    func testSubmitManualAPIKeyAccountInEditModeCallsUpdateAndPublishesSuccess() async {
        let updatedAccount = Self.makeAccount(
            id: "api-account",
            label: "Edited API",
            accountID: "acct-updated",
            enabled: false,
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/updated"
        )
        let probe = ManualAPIKeyUpdateProbe()
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            updateManualAPIKeyAccountHandler: { id, input in
                await probe.record(id: id, input: input)
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.manualAPIKeyDraft = DesktopAppModel.ManualAPIKeyDraft(
            label: "Edited API",
            baseURL: "https://example.com/updated",
            upstreamAdapter: .chatCompletions,
            apiKey: "sk-original",
            enabled: false,
            automaticCooldownDisabled: true,
            editingAccountID: updatedAccount.id,
            originalAccountKey: "key-before-edit"
        )

        await model.submitManualAPIKeyAccount()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.id, updatedAccount.id)
        XCTAssertEqual(
            snapshot.input,
            UpdateManualAPIKeyAccountRequest(
                label: "Edited API",
                baseURL: "https://example.com/updated",
                baseURLMode: .exactAPIPrefix,
                upstreamAdapter: .chatCompletions,
                apiKey: "sk-original",
                enabled: false,
                automaticCooldownDisabled: true
            )
        )
        XCTAssertNil(model.manualAPIKeyDraft)
        XCTAssertEqual(model.accounts.count, 1)
        XCTAssertEqual(model.accounts.first, updatedAccount)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.localization.successTitle(for: OperationContext.manualUpdateAccount))
        XCTAssertEqual(
            model.banners.first?.detail,
            model.localization.successDetail(for: OperationContext.manualUpdateAccount, rawDetail: updatedAccount.label)
        )
    }

    @MainActor
    func testSubmitManualAPIKeyAccountSendsOnlyUpstreamAdapter() async {
        let updatedAccount = Self.makeAccount(
            id: "api-responses-account",
            label: "Responses API",
            accountID: "acct-responses",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://api.example.com"
        )
        let probe = ManualAPIKeyUpdateProbe()
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            updateManualAPIKeyAccountHandler: { id, input in
                await probe.record(id: id, input: input)
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.manualAPIKeyDraft = DesktopAppModel.ManualAPIKeyDraft(
            label: "Responses API",
            baseURL: "https://api.example.com",
            upstreamAdapter: .responses,
            apiKey: "sk-responses",
            enabled: true,
            editingAccountID: updatedAccount.id,
            originalAccountKey: "key-responses"
        )

        await model.submitManualAPIKeyAccount()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.id, updatedAccount.id)
        XCTAssertEqual(snapshot.input?.upstreamAdapter, .responses)
    }

    @MainActor
    func testSubmitManualAPIKeyAccountRejectsGenericPresetForOfficialGeminiRootBeforeRequest() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let admin = AdminAPIClient(dataDirectory: directory)
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = DesktopLanguageMode.english
        model.manualAPIKeyDraft = DesktopAppModel.ManualAPIKeyDraft(
            label: "Gemini Wrong Preset",
            providerPreset: .genericOpenAICompatible,
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "sk-gemini-runtime",
            enabled: true
        )

        await model.submitManualAPIKeyAccount()

        XCTAssertNotNil(model.manualAPIKeyDraft)
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(model.banners.first?.title, model.text(LocalizedTextKey.errorAccountManagementFailed))
        XCTAssertEqual(model.banners.first?.detail, model.text(LocalizedTextKey.errorManualAccountGoogleGeminiPresetRequired))
    }

    @MainActor
    func testSubmitManualAPIKeyAccountRejectsGoogleAIOAuthLikeCredentialForGeminiPresetBeforeRequest() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let admin = AdminAPIClient(dataDirectory: directory)
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .english
        model.manualAPIKeyDraft = DesktopAppModel.ManualAPIKeyDraft(
            label: "Gemini AI Pro",
            providerPreset: .googleGeminiCompatible,
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "AQ.test-google-session",
            enabled: true
        )

        await model.submitManualAPIKeyAccount()

        XCTAssertNotNil(model.manualAPIKeyDraft)
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(model.banners.first?.title, model.text(.errorAccountManagementFailed))
        XCTAssertEqual(model.banners.first?.detail, model.text(.errorManualAccountGoogleGeminiAPIKeyOnly))
    }

    @MainActor
    func testPresentGoogleGeminiManualAPIKeySheetPrefillsGeminiPreset() {
        let model = DesktopAppModel()

        model.presentGoogleGeminiManualAPIKeySheet()

        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .googleGeminiCompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, OpenAICompatibleUpstream.defaultGeminiBaseURL)
        XCTAssertEqual(model.manualAPIKeyDraft?.apiKey, "")
        XCTAssertEqual(model.manualAPIKeyDraft?.label, "")
    }

    @MainActor
    func testRefreshUsageButtonTextSwitchesToRefreshingCopy() {
        let model = DesktopAppModel()
        let accountID = "account-refreshing"

        XCTAssertEqual(model.refreshUsageButtonText(for: accountID), model.text(.actionRefreshUsage))

        model.refreshingAccountIDs.insert(accountID)

        XCTAssertEqual(model.text(.actionRefreshingUsage), "刷新中")
        XCTAssertEqual(model.refreshUsageButtonText(for: accountID), model.text(.actionRefreshingUsage))
    }

    @MainActor
    func testRefreshUsageForAccountPublishesManualAPIKeySuccessAndClearsRefreshingState() async {
        let updatedAccount = Self.makeAccount(
            id: "api-account",
            label: "Refreshed API",
            accountID: "acct-api",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1"
        )
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            refreshAccountUsageHandler: { id in
                XCTAssertEqual(id, updatedAccount.id)
                try? await Task.sleep(for: .milliseconds(80))
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)

        let task = Task { await model.refreshUsage(for: updatedAccount) }

        await Self.waitForCondition { model.isRefreshingUsage(for: updatedAccount.id) }
        XCTAssertEqual(model.refreshUsageButtonText(for: updatedAccount.id), model.text(.actionRefreshingUsage))

        _ = await task.value

        XCTAssertFalse(model.isRefreshingUsage(for: updatedAccount.id))
        XCTAssertEqual(model.refreshUsageButtonText(for: updatedAccount.id), model.text(.actionRefreshUsage))
        XCTAssertEqual(model.accounts.first, updatedAccount)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.text(.successAccountUsageRefreshed))
        XCTAssertEqual(model.banners.first?.detail, model.text(.helperAPIKeyAccountNoStandardUsage))
    }

    @MainActor
    func testRefreshUsageForManualAPIKeyAccountWithValidationIssuePublishesWarningInsteadOfSuccess() async {
        let updatedAccount = Self.makeAccount(
            id: "api-warning-account",
            label: "Warning API",
            accountID: "acct-api-warning",
            authMode: .anthropicAPIKey,
            providerPreset: .anthropicAPICompatible,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600,
            usageError: "HTTP 404"
        )
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            refreshAccountUsageHandler: { id in
                XCTAssertEqual(id, updatedAccount.id)
                try? await Task.sleep(for: .milliseconds(80))
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)

        let task = Task { await model.refreshUsage(for: updatedAccount) }

        await Self.waitForCondition { model.isRefreshingUsage(for: updatedAccount.id) }
        _ = await task.value

        guard let reloaded = model.accounts.first else {
            XCTFail("Expected refreshed account to remain in the model.")
            return
        }
        XCTAssertEqual(reloaded.usageError, "HTTP 404")
        XCTAssertEqual(model.accountRuntimeStatusText(reloaded), model.text(.statusCoolingDown))
        XCTAssertNotNil(model.accountRuntimeIssueText(reloaded))
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(model.banners.first?.title, model.text(.errorUsageRefreshFailed))
        XCTAssertEqual(model.banners.first?.detail, "HTTP 404")
    }

    @MainActor
    func testRefreshUsageForCoolingManualAPIKeyAccountClearsCoolingStateAfterReload() async {
        let coolingAccount = Self.makeAccount(
            id: "cooling-api-account",
            label: "Cooling API",
            accountID: "acct-cooling-api",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600,
            usageError: "API key cooling down"
        )
        let updatedAccount = Self.makeAccount(
            id: coolingAccount.id,
            label: coolingAccount.label,
            accountID: coolingAccount.accountID,
            accountKey: coolingAccount.accountKey,
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1"
        )
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            refreshAccountUsageHandler: { id in
                XCTAssertEqual(id, coolingAccount.id)
                try? await Task.sleep(for: .milliseconds(80))
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accounts = [coolingAccount]

        XCTAssertEqual(model.accountRuntimeStatusText(coolingAccount), model.text(.statusCoolingDown))
        XCTAssertNotNil(model.accountRuntimeIssueText(coolingAccount))

        let task = Task { await model.refreshUsage(for: coolingAccount) }

        await Self.waitForCondition { model.isRefreshingUsage(for: coolingAccount.id) }
        _ = await task.value

        guard let reloaded = model.accounts.first else {
            XCTFail("Expected refreshed account to remain in the model.")
            return
        }
        XCTAssertEqual(reloaded.consecutiveFailureCount, 0)
        XCTAssertNil(reloaded.cooldownUntil)
        XCTAssertNil(reloaded.usageError)
        XCTAssertEqual(model.accountRuntimeStatusText(reloaded), model.text(.statusRunning))
        XCTAssertNil(model.accountRuntimeIssueText(reloaded))
    }

    @MainActor
    func testRefreshUsageBatchClearsCoolingStateForManualAPIKeyAccounts() async {
        let coolingAccount = Self.makeAccount(
            id: "batch-cooling-api-account",
            label: "Batch Cooling API",
            accountID: "acct-batch-cooling-api",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600,
            usageError: "API key cooling down"
        )
        let updatedAccount = Self.makeAccount(
            id: coolingAccount.id,
            label: coolingAccount.label,
            accountID: coolingAccount.accountID,
            accountKey: coolingAccount.accountKey,
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1"
        )
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            refreshUsageHandler: { [updatedAccount] in
                try? await Task.sleep(for: .milliseconds(80))
                return [updatedAccount]
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accounts = [coolingAccount]

        XCTAssertEqual(model.accountRuntimeStatusText(coolingAccount), model.text(.statusCoolingDown))
        XCTAssertNotNil(model.accountRuntimeIssueText(coolingAccount))

        await model.refreshUsage()

        guard let refreshed = model.accounts.first else {
            XCTFail("Expected refreshed account list to remain populated.")
            return
        }
        XCTAssertEqual(refreshed.consecutiveFailureCount, 0)
        XCTAssertNil(refreshed.cooldownUntil)
        XCTAssertNil(refreshed.usageError)
        XCTAssertEqual(model.accountRuntimeStatusText(refreshed), model.text(.statusRunning))
        XCTAssertNil(model.accountRuntimeIssueText(refreshed))
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.text(.successUsageRefreshed))
    }

    @MainActor
    func testRefreshUsageBatchFailureKeepsCoolingStateForManualAPIKeyAccount() async {
        let coolingAccount = Self.makeAccount(
            id: "batch-failing-api-account",
            label: "Batch Failing API",
            accountID: "acct-batch-failing-api",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600,
            usageError: "API key cooling down"
        )
        let admin = AdminAPIClient(
            refreshUsageHandler: {
                try? await Task.sleep(for: .milliseconds(80))
                throw ProxyError.message("cannot refresh all usage")
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accounts = [coolingAccount]

        await model.refreshUsage()

        guard let retained = model.accounts.first else {
            XCTFail("Expected cooling account to remain in the model after refresh failure.")
            return
        }
        XCTAssertEqual(retained.consecutiveFailureCount, coolingAccount.consecutiveFailureCount)
        XCTAssertEqual(retained.cooldownUntil, coolingAccount.cooldownUntil)
        XCTAssertEqual(retained.usageError, coolingAccount.usageError)
        XCTAssertEqual(model.accountRuntimeStatusText(retained), model.text(.statusCoolingDown))
        XCTAssertNotNil(model.accountRuntimeIssueText(retained))
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertTrue(model.banners.first?.detail?.contains("cannot refresh all usage") == true)
    }

    @MainActor
    func testStopAccountCooldownConfirmsCallsAdminReloadsAccountsAndShowsSuccess() async {
        let coolingAccount = Self.makeAccount(
            id: "stop-cooling-api-account",
            label: "Stop Cooling API",
            accountID: "acct-stop-cooling-api",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600,
            usageError: "API key cooling down"
        )
        let probe = AccountCooldownStopProbe(account: coolingAccount)
        let admin = AdminAPIClient(
            accountsHandler: { await probe.accounts() },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            stopAccountCooldownHandler: { id in try await probe.stop(id: id) }
        )
        var confirmationContent: DesktopAppModel.AccountCooldownStopConfirmationContent?
        let model = DesktopAppModel(
            admin: admin,
            confirmStopAccountCooldownHandler: { content in
                confirmationContent = content
                return true
            }
        )
        model.preferences.languageMode = .zhHans
        model.accounts = [coolingAccount]

        XCTAssertTrue(model.canStopAccountCooldown(coolingAccount))

        await model.stopAccountCooldown(coolingAccount)

        XCTAssertEqual(confirmationContent?.title, model.text(.confirmStopAccountCooldownTitle))
        XCTAssertEqual(confirmationContent?.actionTitle, model.text(.confirmStopAccountCooldownAction))
        XCTAssertTrue(confirmationContent?.informativeText.contains(coolingAccount.label) == true)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1)
        guard let updated = model.accounts.first else {
            XCTFail("Expected account list to be reloaded.")
            return
        }
        XCTAssertEqual(updated.consecutiveFailureCount, 0)
        XCTAssertNil(updated.cooldownUntil)
        XCTAssertNil(updated.usageError)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.text(.successAccountCooldownStopped))
        XCTAssertTrue(model.banners.first?.detail?.contains(updated.label) == true)
    }

    @MainActor
    func testStopAccountCooldownCancelDoesNotCallAdmin() async {
        let coolingAccount = Self.makeAccount(
            id: "cancel-stop-cooling-api-account",
            label: "Cancel Stop Cooling API",
            accountID: "acct-cancel-stop-cooling-api",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 4,
            cooldownUntil: Helpers.now() + 3_600,
            usageError: "API key cooling down"
        )
        let probe = AccountCooldownStopProbe(account: coolingAccount)
        let admin = AdminAPIClient(
            accountsHandler: { await probe.accounts() },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            stopAccountCooldownHandler: { id in try await probe.stop(id: id) }
        )
        var confirmationContent: DesktopAppModel.AccountCooldownStopConfirmationContent?
        let model = DesktopAppModel(
            admin: admin,
            confirmStopAccountCooldownHandler: { content in
                confirmationContent = content
                return false
            }
        )
        model.accounts = [coolingAccount]

        await model.stopAccountCooldown(coolingAccount)

        XCTAssertNotNil(confirmationContent)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(model.accounts.first, coolingAccount)
        XCTAssertTrue(model.banners.isEmpty)
    }

    @MainActor
    func testCanStopAccountCooldownOnlyForCoolingManualAPIKeyAccounts() {
        let model = DesktopAppModel()
        let coolingOpenAIAPIKey = Self.makeAccount(
            id: "cooling-openai-api-key",
            label: "Cooling OpenAI API Key",
            accountID: "acct-cooling-openai-api-key",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600
        )
        let coolingAnthropicAPIKey = Self.makeAccount(
            id: "cooling-anthropic-api-key",
            label: "Cooling Anthropic API Key",
            accountID: "acct-cooling-anthropic-api-key",
            authMode: .anthropicAPIKey,
            upstreamBaseURL: "https://example.com",
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600
        )
        let runningAPIKey = Self.makeAccount(
            id: "running-api-key",
            label: "Running API Key",
            accountID: "acct-running-api-key",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1",
            consecutiveFailureCount: 0,
            cooldownUntil: nil
        )
        let coolingOAuth = Self.makeAccount(
            id: "cooling-oauth",
            label: "Cooling OAuth",
            accountID: "acct-cooling-oauth",
            authMode: .chatGPT,
            consecutiveFailureCount: 3,
            cooldownUntil: Helpers.now() + 3_600
        )

        XCTAssertTrue(model.canStopAccountCooldown(coolingOpenAIAPIKey))
        XCTAssertTrue(model.canStopAccountCooldown(coolingAnthropicAPIKey))
        XCTAssertFalse(model.canStopAccountCooldown(runningAPIKey))
        XCTAssertFalse(model.canStopAccountCooldown(coolingOAuth))
    }

    @MainActor
    func testToggleAccountCooldownPolicyCallsAdminReloadsAccountsAndShowsSuccess() async {
        let apiKeyAccount = Self.makeAccount(
            id: "cooldown-policy-api-key",
            label: "Cooldown Policy API Key",
            accountID: "acct-cooldown-policy-api-key",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1"
        )
        let probe = AccountCooldownPolicyUpdateProbe(account: apiKeyAccount)
        let admin = AdminAPIClient(
            accountsHandler: { await probe.accounts() },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            updateAccountCooldownPolicyHandler: { id, input in
                try await probe.update(id: id, input: input)
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accounts = [apiKeyAccount]

        XCTAssertTrue(model.canUpdateAccountCooldownPolicy(apiKeyAccount))
        XCTAssertEqual(model.accountCooldownPolicyText(apiKeyAccount), model.localized(zh: "自动", en: "Automatic"))
        XCTAssertEqual(model.accountCooldownPolicyActionTitle(apiKeyAccount), model.text(.actionDisableAutomaticCooldown))

        await model.toggleAccountCooldownPolicy(apiKeyAccount)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.id, apiKeyAccount.id)
        XCTAssertEqual(snapshot.input, UpdateAccountCooldownPolicyRequest(automaticCooldownDisabled: true))
        guard let updated = model.accounts.first else {
            XCTFail("Expected account list to be reloaded.")
            return
        }
        XCTAssertTrue(updated.automaticCooldownDisabled)
        XCTAssertEqual(model.accountCooldownPolicyText(updated), model.localized(zh: "已禁用", en: "Disabled"))
        XCTAssertEqual(model.accountCooldownPolicyActionTitle(updated), model.text(.actionEnableAutomaticCooldown))
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.text(.successAccountCooldownPolicyUpdated))
        XCTAssertTrue(model.banners.first?.detail?.contains(updated.label) == true)
    }

    @MainActor
    func testRefreshUsageForAccountFailureClearsRefreshingStateAndPublishesError() async {
        let account = Self.makeAccount(
            id: "oauth-account",
            label: "Broken OAuth",
            accountID: "acct-oauth"
        )
        let admin = AdminAPIClient(
            refreshAccountUsageHandler: { id in
                XCTAssertEqual(id, account.id)
                try? await Task.sleep(for: .milliseconds(80))
                throw ProxyError.message("cannot refresh usage")
            }
        )
        let model = DesktopAppModel(admin: admin)

        let task = Task { await model.refreshUsage(for: account) }

        await Self.waitForCondition { model.isRefreshingUsage(for: account.id) }
        XCTAssertEqual(model.refreshUsageButtonText(for: account.id), model.text(.actionRefreshingUsage))

        _ = await task.value

        XCTAssertFalse(model.isRefreshingUsage(for: account.id))
        XCTAssertEqual(model.refreshUsageButtonText(for: account.id), model.text(.actionRefreshUsage))
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertTrue(model.banners.first?.detail?.contains("cannot refresh usage") == true)
    }

    @MainActor
    func testAccountsViewCardRefreshButtonRestoresIdleStateAfterSuccessfulRefresh() async {
        let updatedAccount = Self.makeAccount(
            id: "view-refresh-account",
            label: "View Refresh",
            accountID: "acct-view-refresh",
            authMode: .openAIAPIKey,
            upstreamBaseURL: "https://example.com/v1"
        )
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            refreshAccountUsageHandler: { id in
                XCTAssertEqual(id, updatedAccount.id)
                try? await Task.sleep(for: .milliseconds(80))
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accounts = [updatedAccount]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 1200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let hostingView = NSHostingView(
            rootView: AccountsView(model: model)
                .frame(width: 380, alignment: .leading)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView
        Self.renderHostedView(hostingView)

        XCTAssertEqual(Self.hostedProgressIndicatorCount(in: hostingView), 0)

        let task = Task { await model.refreshUsage(for: updatedAccount) }

        await Self.waitForCondition { model.isRefreshingUsage(for: updatedAccount.id) }
        Self.renderHostedView(hostingView)
        XCTAssertEqual(model.refreshUsageButtonText(for: updatedAccount.id), model.text(.actionRefreshingUsage))

        _ = await task.value

        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            return Self.hostedProgressIndicatorCount(in: hostingView) == 0
        }

        XCTAssertFalse(model.isRefreshingUsage(for: updatedAccount.id))
        XCTAssertEqual(model.refreshUsageButtonText(for: updatedAccount.id), model.text(.actionRefreshUsage))
        XCTAssertEqual(model.banners.first?.tone, .success)
    }

    @MainActor
    func testAccountsViewShowsClearOutboundNodesToolbarAction() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        XCTAssertEqual(model.text(.actionClearAccountManagedProxyNodes), "Clear Outbound Nodes")
        model.accounts = [
            Self.makeAccount(
                id: "toolbar-override",
                label: "Toolbar Override",
                accountID: "acct-toolbar-override",
                managedProxyNodeName: "Tokyo"
            )
        ]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let hostingView = NSHostingView(
            rootView: AccountsView(model: model)
                .frame(width: 1240, height: 900)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)
        XCTAssertGreaterThan(Self.hostedSubviewCount(in: hostingView, named: "NSButton"), 0)

        model.accounts = [
            Self.makeAccount(
                id: "toolbar-follow-global",
                label: "Toolbar Follow Global",
                accountID: "acct-toolbar-follow-global"
            )
        ]
        Self.renderHostedView(hostingView)
        XCTAssertGreaterThan(Self.hostedSubviewCount(in: hostingView, named: "NSButton"), 0)
    }

    @MainActor
    func testAccountPoolToolbarSourcePrefersSharedFilterAndActionSecondRow() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/AccountsView.swift")

        XCTAssertTrue(source.contains("self.twoLinePreferredToolbarLayout(palette: palette)"))
        XCTAssertTrue(source.contains("self.narrowToolbarLayout(palette: palette)"))
        XCTAssertTrue(source.contains("private func twoLinePreferredToolbarLayout(palette: AppearancePalette) -> some View"))
        XCTAssertTrue(
            source.contains(
                """
                HStack(alignment: .center, spacing: 10) {
                                self.filterMenusRow
                                Spacer(minLength: 0)
                                self.toolbarActionButtonsRow
                            }
                """
            )
        )
    }

    @MainActor
    func testAccountsViewToolbarKeepsFiltersAndActionsOnSharedSecondRowBeforeNarrowFallback() throws {
        let model = DesktopAppModel()
        model.preferences.languageMode = .zhHans
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [
            Self.makeAccount(
                id: "toolbar-medium-visible",
                label: "Toolbar Medium Visible",
                accountID: "acct-toolbar-medium-visible",
                managedProxyNodeName: "Tokyo"
            ),
            Self.makeAccount(
                id: "toolbar-medium-sibling",
                label: "Toolbar Medium Sibling",
                accountID: "acct-toolbar-medium-sibling"
            ),
        ]
        model.accountPoolFilters.searchQuery = "toolbar-search"
        model.accountPoolFilters.status = .enabled
        model.accountPoolFilters.plan = .pro
        model.accountPoolFilters.issue = .anyIssue

        let mediumWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 1100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { mediumWindow.orderOut(nil) }
        let mediumHostingView = NSHostingView(
            rootView: AccountsView(model: model)
                .frame(width: 960, alignment: .leading)
        )
        mediumHostingView.frame = mediumWindow.contentLayoutRect
        mediumWindow.contentView = mediumHostingView

        let narrowWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 1200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { narrowWindow.orderOut(nil) }
        let narrowHostingView = NSHostingView(
            rootView: AccountsView(model: model)
                .frame(width: 720, alignment: .leading)
        )
        narrowHostingView.frame = narrowWindow.contentLayoutRect
        narrowWindow.contentView = narrowHostingView

        Self.renderHostedView(mediumHostingView)
        Self.renderHostedView(narrowHostingView)

        let renderedText = Self.hostedTextValues(in: mediumHostingView).joined(separator: "\n")
        XCTAssertTrue(renderedText.contains("toolbar-search"))

        let mediumHeight = mediumHostingView.fittingSize.height
        let narrowHeight = narrowHostingView.fittingSize.height

        XCTAssertGreaterThan(mediumHeight, 0)
        XCTAssertGreaterThan(narrowHeight, mediumHeight + 20)
        XCTAssertEqual(Self.hostedSubviewCount(in: narrowHostingView, named: "NSTableView"), 0)
    }

    @MainActor
    func testAnthropicAPICompatibleClientAccessPresentationDoesNotApplyToOtherAccounts() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "anthropic-access",
                label: "Anthropic Access",
                key: "sk-anthropic",
                dataSource: .anthropic,
                enabled: true,
                createdAt: 1
            ),
        ]

        let openAIManual = Self.makeAccount(
            id: "openai-manual",
            label: "OpenAI Manual",
            accountID: "acct-openai-manual",
            authMode: .openAIAPIKey,
            providerPreset: .genericOpenAICompatible,
            upstreamBaseURL: "https://example.com/v1"
        )
        let anthropicOAuth = Self.makeAccount(
            id: "anthropic-oauth",
            label: "Anthropic OAuth",
            accountID: "acct-anthropic-oauth",
            authMode: .anthropicSubscriptionOAuth
        )

        XCTAssertNil(model.anthropicAPICompatibleClientAccessPresentation(for: openAIManual))
        XCTAssertNil(model.anthropicAPICompatibleClientAccessPresentation(for: anthropicOAuth))
    }

    @MainActor
    func testSubmitAccountLabelUpdateCallsRenameHandlerAndRefreshesStatus() async {
        let updatedAccount = Self.makeAccount(
            id: "chatgpt-account",
            label: "Renamed OAuth",
            accountID: "acct-chatgpt"
        )
        let updatedStatus = ProxyStatus(
            running: true,
            publicBaseURL: "http://127.0.0.1:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://127.0.0.1:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-local",
            activeAccountKey: updatedAccount.accountKey,
            activeAccountID: updatedAccount.accountID,
            activeAccountLabel: updatedAccount.label,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )
        let probe = AccountLabelUpdateProbe()
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            getStatusHandler: { updatedStatus },
            updateAccountLabelHandler: { id, input in
                await probe.record(id: id, input: input)
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accountLabelDraft = DesktopAppModel.AccountLabelDraft(
            accountID: updatedAccount.id,
            accountKey: updatedAccount.accountKey,
            label: "Renamed OAuth"
        )

        await model.submitAccountLabelUpdate()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.id, updatedAccount.id)
        XCTAssertEqual(snapshot.input, UpdateAccountLabelRequest(label: "Renamed OAuth"))
        XCTAssertNil(model.accountLabelDraft)
        XCTAssertEqual(model.accounts.first?.label, "Renamed OAuth")
        XCTAssertEqual(model.status?.activeAccountLabel, "Renamed OAuth")
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.localization.successTitle(for: .renameAccountLabel))
        XCTAssertEqual(
            model.banners.first?.detail,
            model.localization.successDetail(for: .renameAccountLabel, rawDetail: updatedAccount.label)
        )
    }

    @MainActor
    func testSubmitAccountLabelUpdateRejectsBlankLabel() async {
        let model = DesktopAppModel()
        model.accountLabelDraft = DesktopAppModel.AccountLabelDraft(
            accountID: "chatgpt-account",
            accountKey: "key-chatgpt-account",
            label: "   "
        )

        await model.submitAccountLabelUpdate()

        XCTAssertNotNil(model.accountLabelDraft)
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(model.banners.first?.title, model.text(.errorAccountManagementFailed))
        XCTAssertEqual(model.banners.first?.detail, model.text(.helperAccountLabelRequired))
    }

    @MainActor
    func testOpenAccountManagedProxyNodeSheetSupportsOAuthAndManualAccounts() {
        let model = DesktopAppModel()
        let oauthAccount = Self.makeAccount(
            id: "oauth-account",
            label: "OAuth Account",
            accountID: "acct-oauth"
        )
        let apiKeyAccount = Self.makeAccount(
            id: "api-account",
            label: "API Account",
            accountID: "acct-api",
            authMode: .openAIAPIKey,
            managedProxyNodeName: "Tokyo"
        )

        model.openAccountManagedProxyNodeSheet(oauthAccount)
        XCTAssertEqual(model.accountManagedProxyNodeDraft?.accountID, oauthAccount.id)
        XCTAssertNil(model.accountManagedProxyNodeDraft?.managedProxyNodeName)

        model.openAccountManagedProxyNodeSheet(apiKeyAccount)
        XCTAssertEqual(model.accountManagedProxyNodeDraft?.accountID, apiKeyAccount.id)
        XCTAssertEqual(model.accountManagedProxyNodeDraft?.managedProxyNodeName, "Tokyo")
    }

    @MainActor
    func testAccountPoolDisplayModeLabelsAreLocalized() {
        let model = DesktopAppModel()

        model.preferences.languageMode = .english
        XCTAssertEqual(model.text(.labelDisplay), "Display")
        XCTAssertEqual(model.label(for: .cards), "Cards")
        XCTAssertEqual(model.label(for: .list), "List")

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(model.text(.labelDisplay), "显示")
        XCTAssertEqual(model.label(for: .cards), "卡片")
        XCTAssertEqual(model.label(for: .list), "列表")
    }

    @MainActor
    func testAccountPoolSelectionStartsEmptyInListMode() {
        let model = DesktopAppModel()
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [
            Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1"),
            Self.makeAccount(id: "account-2", label: "Second", accountID: "acct-2"),
        ]

        XCTAssertNil(model.selectedAccountPoolAccountID)
        XCTAssertNil(model.selectedAccountPoolAccount)
        XCTAssertFalse(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testSelectAccountPoolAccountResolvesCurrentSelection() {
        let model = DesktopAppModel()
        let first = Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1")
        let second = Self.makeAccount(id: "account-2", label: "Second", accountID: "acct-2")
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [first, second]

        model.selectAccountPoolAccount(second)

        XCTAssertEqual(model.selectedAccountPoolAccountID, second.id)
        XCTAssertEqual(model.selectedAccountPoolAccount?.id, second.id)
    }

    @MainActor
    func testPresentAccountPoolDetailDrawerSelectsAccountAndOpensDrawer() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1")
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [account]

        model.presentAccountPoolDetailDrawer(for: account)

        XCTAssertEqual(model.selectedAccountPoolAccountID, account.id)
        XCTAssertEqual(model.selectedAccountPoolAccount?.id, account.id)
        XCTAssertTrue(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testDismissAccountPoolDetailDrawerKeepsSelection() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1")
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [account]
        model.presentAccountPoolDetailDrawer(for: account)

        model.dismissAccountPoolDetailDrawer()

        XCTAssertEqual(model.selectedAccountPoolAccountID, account.id)
        XCTAssertEqual(model.selectedAccountPoolAccount?.id, account.id)
        XCTAssertFalse(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testAccountPoolSelectionClearsWhenFilterHidesSelectedAccount() {
        let model = DesktopAppModel()
        let first = Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1")
        let second = Self.makeAccount(id: "account-2", label: "Second", accountID: "acct-2")
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [first, second]
        model.presentAccountPoolDetailDrawer(for: second)

        model.accountPoolFilters = AccountPoolFilterState(searchQuery: "First")

        XCTAssertNil(model.selectedAccountPoolAccountID)
        XCTAssertNil(model.selectedAccountPoolAccount)
        XCTAssertFalse(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testAccountPoolSelectionClearsWhenSelectedAccountRemoved() {
        let model = DesktopAppModel()
        let first = Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1")
        let second = Self.makeAccount(id: "account-2", label: "Second", accountID: "acct-2")
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [first, second]
        model.presentAccountPoolDetailDrawer(for: second)

        model.accounts = [first]

        XCTAssertNil(model.selectedAccountPoolAccountID)
        XCTAssertNil(model.selectedAccountPoolAccount)
        XCTAssertFalse(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testAccountPoolSelectionClearsWhenSwitchingBackToCardsMode() throws {
        let (preferencesStore, directory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DesktopAppModel(preferencesStore: preferencesStore)
        let account = Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1")
        model.preferences.accountPoolDisplayMode = .list
        model.accounts = [account]
        model.presentAccountPoolDetailDrawer(for: account)

        model.updateAccountPoolDisplayMode(.cards)

        XCTAssertEqual(model.preferences.accountPoolDisplayMode, .cards)
        XCTAssertNil(model.selectedAccountPoolAccountID)
        XCTAssertNil(model.selectedAccountPoolAccount)
        XCTAssertFalse(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testAccountPoolDetailDrawerClosesWhenLeavingAccountsPageButKeepsSelection() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(id: "account-1", label: "First", accountID: "acct-1")
        model.preferences.accountPoolDisplayMode = .list
        model.selectedPage = .accounts
        model.accounts = [account]
        model.presentAccountPoolDetailDrawer(for: account)

        model.selectedPage = .proxy
        model.selectedPage = .accounts

        XCTAssertEqual(model.selectedAccountPoolAccountID, account.id)
        XCTAssertEqual(model.selectedAccountPoolAccount?.id, account.id)
        XCTAssertFalse(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testAccountsViewStandaloneListModeDoesNotRenderDetailDrawer() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.preferences.accountPoolDisplayMode = .list
        model.selectedPage = .accounts
        let selectedAccount = Self.makeAccount(
            id: "list-account-selected",
            label: "Selected Row",
            accountID: "acct-selected-row",
            usageError: "Connection lost while refreshing usage"
        )
        model.accounts = [
            selectedAccount,
            Self.makeAccount(
                id: "list-account-other",
                label: "Other Row",
                accountID: "acct-other-row"
            ),
        ]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 880),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: AccountsView(model: model)
                .frame(width: 1240, height: 880)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        var renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertEqual(Self.hostedSubviewCount(in: hostingView, named: "NSScrollView"), 0)
        XCTAssertFalse(renderedText.contains("Select an account to view details"))

        model.presentAccountPoolDetailDrawer(for: selectedAccount)
        Self.renderHostedView(hostingView)

        renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertFalse(renderedText.contains(model.text(.labelDisplay).uppercased()))
        XCTAssertFalse(renderedText.contains(model.text(.labelAccounts).uppercased()))
        XCTAssertFalse(renderedText.contains(selectedAccount.accountID))
        XCTAssertEqual(Self.hostedSubviewCount(in: hostingView, named: "NSScrollView"), 0)
        XCTAssertFalse(renderedText.contains("Select an account to view details"))
    }

    @MainActor
    func testRootShellViewAccountsPageRendersAccountPoolDetailDrawerInViewportOverlay() async {
        let model = DesktopAppModel()
        model.preferences.interfaceMode = .full
        model.preferences.languageMode = .english
        model.preferences.accountPoolDisplayMode = .list
        model.selectedPage = .accounts
        let selectedAccount = Self.makeAccount(
            id: "root-shell-selected-account",
            label: "Viewport Drawer",
            accountID: "acct-root-shell"
        )
        model.accounts = [
            selectedAccount,
            Self.makeAccount(
                id: "root-shell-other-account",
                label: "Sibling Row",
                accountID: "acct-root-shell-other"
            ),
        ]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 920),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: RootShellView(model: model)
                .frame(width: 1480, height: 920)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        var renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertFalse(renderedText.contains(selectedAccount.accountID))

        model.presentAccountPoolDetailDrawer(for: selectedAccount)
        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            let text = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
            return text.contains(selectedAccount.accountID)
        }

        renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertTrue(renderedText.contains(selectedAccount.accountID))

        model.dismissAccountPoolDetailDrawer()
        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            let text = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
            return text.contains(selectedAccount.accountID) == false
        }

        renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertFalse(renderedText.contains(selectedAccount.accountID))
        XCTAssertEqual(model.selectedAccountPoolAccountID, selectedAccount.id)
        XCTAssertFalse(model.isAccountPoolDetailDrawerPresented)
    }

    @MainActor
    func testRemoteViewStartsWithHostManagementWithoutDetailWorkflowChrome() throws {
        let first = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let second = Self.makeRemoteHost(id: "host-2", label: "Seoul", host: "seoul.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [first, second]))
        model.preferences.languageMode = .english

        let (window, hostingView) = Self.makeHostedView(
            width: 1280,
            height: 900,
            rootView: AnyView(
                RemoteView(model: model)
                    .frame(width: 1280, height: 900)
            )
        )
        defer { window.orderOut(nil) }

        Self.renderHostedView(hostingView)

        XCTAssertNotNil(Self.hostedView(withAccessibilityIdentifier: "remote-host-management-card", in: hostingView))
        XCTAssertNotNil(Self.hostedViewFrame(withAccessibilityIdentifier: "remote-host-row-\(first.id)", in: hostingView))
        XCTAssertNil(Self.hostedView(withAccessibilityIdentifier: "remote-selected-host-card", in: hostingView))
        XCTAssertNil(Self.hostedView(withAccessibilityIdentifier: "remote-workflow-step-strip", in: hostingView))
        XCTAssertNil(Self.hostedTextFrame(in: hostingView, value: model.text(.sectionRemoteConnection)))
    }

    @MainActor
    func testRemoteViewShowsSelectedHostHeaderAndWorkflowStripAfterSelectingHost() async throws {
        let host = Self.makeRemoteHost(id: "host-1", label: "Tokyo", host: "tokyo.example.com")
        let model = Self.makeRemoteModel(settings: AppConfig(remoteHosts: [host]))
        model.preferences.languageMode = .english

        let (window, hostingView) = Self.makeHostedView(
            width: 1280,
            height: 900,
            rootView: AnyView(
                RemoteView(model: model)
                    .frame(width: 1280, height: 900)
            )
        )
        defer { window.orderOut(nil) }

        Self.renderHostedView(hostingView)

        model.selectRemoteHost(id: host.id)
        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            return Self.hostedView(withAccessibilityIdentifier: "remote-selected-host-card", in: hostingView) != nil
        }

        let selectedHostFrame = try XCTUnwrap(
            Self.hostedViewFrame(withAccessibilityIdentifier: "remote-selected-host-card", in: hostingView)
        )
        let workflowFrame = try XCTUnwrap(
            Self.hostedViewFrame(withAccessibilityIdentifier: "remote-workflow-step-strip", in: hostingView)
        )
        let switchHostFrame = try XCTUnwrap(
            Self.hostedViewFrame(withAccessibilityIdentifier: "remote-switch-host-button", in: hostingView)
        )

        XCTAssertNil(Self.hostedView(withAccessibilityIdentifier: "remote-host-management-card", in: hostingView))
        XCTAssertLessThan(selectedHostFrame.minY, workflowFrame.minY)
        XCTAssertGreaterThan(switchHostFrame.maxX, selectedHostFrame.midX)
        XCTAssertEqual(model.selectedRemoteWorkflowStep, .configuration)
    }

    func testMainWindowInstallsSharedTitlebarControlsInNativeRightAccessory() throws {
        let appSource = try Self.repoFileText("Sources/CodexProxyDesktop/CodexProxyDesktopApp.swift")
        let rootShellSource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RootShellView.swift")
        let sharedUISource = try Self.repoFileText("Sources/CodexProxyDesktop/Views/SharedUI.swift")

        XCTAssertTrue(appSource.contains("private var mainTitlebarControlsAccessory: NSTitlebarAccessoryViewController?"))
        XCTAssertTrue(appSource.contains("private var mainTitlebarControlsHostingController: NSHostingController<MainWindowTitlebarControlsHostView>?"))
        XCTAssertTrue(appSource.contains("private func installMainWindowTitlebarControls(on window: NSWindow)"))
        XCTAssertTrue(appSource.contains("newHostingController.sizingOptions = [.intrinsicContentSize, .preferredContentSize]"))
        XCTAssertTrue(appSource.contains("private func sizeMainTitlebarControlsView(_ view: NSView)"))
        XCTAssertTrue(appSource.contains("MainWindowTitlebarControlsMetrics.minimumWidth"))
        XCTAssertTrue(appSource.contains("static let minimumWidth: CGFloat = 720"))
        XCTAssertTrue(appSource.contains("static let minimumHeight: CGFloat = 44"))
        XCTAssertTrue(appSource.contains("static let topInset: CGFloat = 4"))
        XCTAssertTrue(appSource.contains("static let bottomInset: CGFloat = 2"))
        XCTAssertTrue(appSource.contains("static let trailingInset: CGFloat = 8"))
        XCTAssertTrue(appSource.contains(".frame(minWidth: MainWindowTitlebarControlsMetrics.minimumWidth, alignment: .trailing)"))
        XCTAssertTrue(appSource.contains(".padding(.top, MainWindowTitlebarControlsMetrics.topInset)"))
        XCTAssertTrue(appSource.contains(".padding(.bottom, MainWindowTitlebarControlsMetrics.bottomInset)"))
        XCTAssertTrue(appSource.contains(".padding(.trailing, MainWindowTitlebarControlsMetrics.trailingInset)"))
        XCTAssertTrue(appSource.contains("newAccessory.layoutAttribute = .right"))
        XCTAssertTrue(appSource.contains("window.titlebarAccessoryViewControllers.contains(where: { $0 === accessory }) == false"))
        XCTAssertTrue(appSource.contains("window.addTitlebarAccessoryViewController(accessory)"))
        XCTAssertTrue(appSource.contains("MainWindowTitlebarControls("))
        XCTAssertTrue(sharedUISource.contains("titlebar-request-logs-button"))
        XCTAssertFalse(rootShellSource.contains("MainWindowTitlebarControlsFrameProbe"))
        XCTAssertFalse(rootShellSource.contains("\"main-window-titlebar-controls\""))
    }

    @MainActor
    func testRootShellViewWideWindowExpandsDetailContentBeyondFormerGlobalCap() throws {
        let model = DesktopAppModel()
        model.preferences.interfaceMode = .full
        model.preferences.languageMode = .english

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1840, height: 980),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: RootShellView(model: model)
                .frame(width: 1840, height: 980)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        let detailFrame = try XCTUnwrap(
            Self.hostedViewFrame(withAccessibilityIdentifier: "main-workspace-detail-content", in: hostingView)
        )

        XCTAssertGreaterThan(detailFrame.width, 1320)
    }

    @MainActor
    func testRootShellViewAppliesCompactOverlayScrollbarsToHostedScrollViews() async {
        let model = DesktopAppModel()
        model.preferences.interfaceMode = .full
        model.preferences.languageMode = .english

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: RootShellView(model: model)
                .frame(width: 1280, height: 560)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)
        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            return Self.hasCompactOverlayScrollbars(in: hostingView, minimumCount: 2)
        }

        Self.assertCompactOverlayScrollbars(in: hostingView, minimumCount: 2)
    }

    @MainActor
    func testHelpViewAppliesCompactOverlayScrollbarsToSidebarAndDetailScrollViews() async {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: HelpView(model: model)
                .frame(width: 1120, height: 560)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)
        await Self.waitForCondition {
            Self.renderHostedView(hostingView)
            return Self.hasCompactOverlayScrollbars(in: hostingView, minimumCount: 2)
        }

        Self.assertCompactOverlayScrollbars(in: hostingView, minimumCount: 2)
    }

    @MainActor
    func testAccountCardActionTitlesUseCompactLocalizedLabels() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "compact-account",
            label: "Compact Account",
            accountID: "acct-compact"
        )

        model.preferences.languageMode = .english
        XCTAssertEqual(model.accountCardRefreshActionTitle(for: account.id), "Refresh")
        XCTAssertEqual(model.accountCardEditActionTitle(for: account), "Edit")
        XCTAssertEqual(model.accountCardNodeActionTitle, "Outbound Node")
        XCTAssertEqual(model.accountCardMoreActionTitle, "More")

        model.refreshingAccountIDs.insert(account.id)
        XCTAssertEqual(model.accountCardRefreshActionTitle(for: account.id), "Refreshing")

        model.preferences.languageMode = .zhHans
        model.refreshingAccountIDs.remove(account.id)
        XCTAssertEqual(model.accountCardRefreshActionTitle(for: account.id), "刷新")
        XCTAssertEqual(model.accountCardEditActionTitle(for: account), "编辑")
        XCTAssertEqual(model.accountCardNodeActionTitle, "出站节点")
        XCTAssertEqual(model.accountCardMoreActionTitle, "更多")

        model.refreshingAccountIDs.insert(account.id)
        XCTAssertEqual(model.accountCardRefreshActionTitle(for: account.id), "刷新中")
    }

    @MainActor
    func testPerformAccountCardEditActionRoutesOAuthAccountsToRenameSheet() async {
        let model = DesktopAppModel()
        let oauthAccount = Self.makeAccount(
            id: "oauth-edit-account",
            label: "OAuth Edit",
            accountID: "acct-oauth-edit"
        )

        await model.performAccountCardEditAction(for: oauthAccount)

        XCTAssertEqual(model.accountLabelDraft?.accountID, oauthAccount.id)
        XCTAssertNil(model.manualAPIKeyDraft)
    }

    @MainActor
    func testPerformAccountCardEditActionRoutesManualAccountsToAPIKeySheet() async {
        let manualAccount = Self.makeAccount(
            id: "manual-edit-account",
            label: "Manual Edit",
            accountID: "acct-manual-edit",
            authMode: .openAIAPIKey
        )
        let admin = AdminAPIClient(
            manualAPIKeyAccountDetailsHandler: { id in
                XCTAssertEqual(id, manualAccount.id)
                return ManualAPIKeyAccountDetails(
                    label: manualAccount.label,
                    baseURL: "https://example.com/v1",
                    apiKey: "sk-manual-edit",
                    enabled: true
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        await model.performAccountCardEditAction(for: manualAccount)

        XCTAssertNil(model.accountLabelDraft)
        XCTAssertEqual(model.manualAPIKeyDraft?.editingAccountID, manualAccount.id)
        XCTAssertEqual(model.manualAPIKeyDraft?.label, manualAccount.label)
        XCTAssertEqual(model.manualAPIKeyDraft?.upstreamAdapter, .responses)
        XCTAssertEqual(model.manualAPIKeyDraft?.apiKey, "sk-manual-edit")
    }

    @MainActor
    func testPerformAccountCardEditActionRestoresGenericUpstreamAdapter() async {
        let manualAccount = Self.makeAccount(
            id: "manual-chat-adapter-account",
            label: "Manual Chat Adapter",
            accountID: "acct-manual-chat-adapter",
            authMode: .openAIAPIKey
        )
        let admin = AdminAPIClient(
            manualAPIKeyAccountDetailsHandler: { id in
                XCTAssertEqual(id, manualAccount.id)
                return ManualAPIKeyAccountDetails(
                    label: manualAccount.label,
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "https://api.deepseek.com",
                    baseURLMode: .exactAPIPrefix,
                    upstreamAdapter: .chatCompletions,
                    apiKey: "sk-chat-adapter",
                    enabled: true
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        await model.performAccountCardEditAction(for: manualAccount)

        XCTAssertEqual(model.manualAPIKeyDraft?.editingAccountID, manualAccount.id)
        XCTAssertEqual(model.manualAPIKeyDraft?.providerPreset, .genericOpenAICompatible)
        XCTAssertEqual(model.manualAPIKeyDraft?.upstreamAdapter, .chatCompletions)
        XCTAssertEqual(model.manualAPIKeyDraft?.apiKey, "sk-chat-adapter")
    }

    @MainActor
    func testPerformAccountCardEditActionShowsEffectivePrefixForLegacyGenericManualAccount() async {
        let manualAccount = Self.makeAccount(
            id: "legacy-manual-edit-account",
            label: "Legacy Manual Edit",
            accountID: "acct-legacy-manual-edit",
            authMode: .openAIAPIKey
        )
        let admin = AdminAPIClient(
            manualAPIKeyAccountDetailsHandler: { id in
                XCTAssertEqual(id, manualAccount.id)
                return ManualAPIKeyAccountDetails(
                    label: manualAccount.label,
                    baseURL: "https://example.com/proxy/v1",
                    baseURLMode: .legacyAppendV1,
                    apiKey: "sk-legacy-manual-edit",
                    enabled: true
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        await model.performAccountCardEditAction(for: manualAccount)

        XCTAssertEqual(model.manualAPIKeyDraft?.editingAccountID, manualAccount.id)
        XCTAssertEqual(model.manualAPIKeyDraft?.baseURL, "https://example.com/proxy/v1")
        XCTAssertEqual(model.manualAPIKeyDraft?.apiKey, "sk-legacy-manual-edit")
    }

    @MainActor
    func testAccountManagedProxyNodeStatusTextShowsFollowGlobalSpecifiedAndUnavailable() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.outboundProxyMode = .subscription
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            nodes: [ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true)]
        )

        let followGlobal = Self.makeAccount(
            id: "follow-global",
            label: "Follow Global",
            accountID: "acct-follow-global"
        )
        let specified = Self.makeAccount(
            id: "specified-node",
            label: "Specified Node",
            accountID: "acct-specified-node",
            managedProxyNodeName: "Tokyo"
        )
        let unavailable = Self.makeAccount(
            id: "unavailable-node",
            label: "Unavailable Node",
            accountID: "acct-unavailable-node",
            managedProxyNodeName: "Seoul"
        )

        XCTAssertEqual(model.accountManagedProxyNodeStatusText(followGlobal), "Use Global")
        XCTAssertEqual(model.accountManagedProxyNodeStatusText(specified), "Tokyo")
        XCTAssertEqual(model.accountManagedProxyNodeStatusText(unavailable), "Node unavailable: Seoul")
        XCTAssertTrue(model.accountIssueText(unavailable)?.contains("Seoul") == true)
    }

    @MainActor
    func testAccountManagedProxyNodePickerHintReflectsModeAndAvailableNodes() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .manual,
            nodes: [ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true)]
        )

        model.settings.outboundProxyMode = .manual
        XCTAssertTrue(model.canSelectAccountManagedProxyNodeOptions)
        XCTAssertTrue(model.accountManagedProxyNodePickerHint().contains("prefers that outbound node"))

        model.managedProxySnapshot = ManagedProxySnapshot(mode: .manual, nodes: [])
        XCTAssertFalse(model.canSelectAccountManagedProxyNodeOptions)
        XCTAssertTrue(model.accountManagedProxyNodePickerHint().contains("No subscription nodes"))
    }

    @MainActor
    func testAccountManagedProxyNodeOverrideCountReflectsAccounts() {
        let model = DesktopAppModel()
        model.accounts = [
            Self.makeAccount(
                id: "override-1",
                label: "Override 1",
                accountID: "acct-override-1",
                managedProxyNodeName: "Tokyo"
            ),
            Self.makeAccount(
                id: "follow-global",
                label: "Follow Global",
                accountID: "acct-follow-global"
            ),
            Self.makeAccount(
                id: "override-2",
                label: "Override 2",
                accountID: "acct-override-2",
                managedProxyNodeName: "Seoul"
            ),
        ]

        XCTAssertEqual(model.accountManagedProxyNodeOverrideCount, 2)
        XCTAssertTrue(model.hasAccountManagedProxyNodeOverrides)

        model.accounts = [
            Self.makeAccount(
                id: "follow-global-only",
                label: "Follow Global Only",
                accountID: "acct-follow-global-only"
            )
        ]

        XCTAssertEqual(model.accountManagedProxyNodeOverrideCount, 0)
        XCTAssertFalse(model.hasAccountManagedProxyNodeOverrides)
    }

    @MainActor
    func testSubmitAccountManagedProxyNodeUpdateCallsAdminAndReloadsSnapshot() async {
        let updatedAccount = Self.makeAccount(
            id: "account-node-update",
            label: "Node Update",
            accountID: "acct-node-update",
            managedProxyNodeName: "Seoul"
        )
        let probe = AccountManagedProxyNodeUpdateProbe()
        let refreshedSnapshot = ManagedProxySnapshot(
            mode: .manual,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true),
            ]
        )
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            getSettingsHandler: {
                var config = AppConfig()
                config.outboundProxyMode = .manual
                return config
            },
            getManagedProxySnapshotHandler: { refreshedSnapshot },
            updateAccountManagedProxyNodeHandler: { id, input in
                await probe.record(id: id, input: input)
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accountManagedProxyNodeDraft = DesktopAppModel.AccountManagedProxyNodeDraft(
            accountID: updatedAccount.id,
            accountKey: updatedAccount.accountKey,
            label: updatedAccount.label,
            managedProxyNodeName: "Seoul"
        )

        await model.submitAccountManagedProxyNodeUpdate()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.id, updatedAccount.id)
        XCTAssertEqual(snapshot.input, UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul"))
        XCTAssertNil(model.accountManagedProxyNodeDraft)
        XCTAssertEqual(model.accounts.first?.managedProxyNodeName, "Seoul")
        XCTAssertEqual(model.managedProxySnapshot, refreshedSnapshot)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.localization.successTitle(for: .updateAccountManagedProxyNode))
        XCTAssertEqual(
            model.banners.first?.detail,
            model.localization.successDetail(for: .updateAccountManagedProxyNode, rawDetail: updatedAccount.label)
        )
    }

    @MainActor
    func testClearAllAccountManagedProxyNodesCancelsWithoutConfirmation() async {
        let initialAccounts = [
            Self.makeAccount(
                id: "override-a",
                label: "Override A",
                accountID: "acct-override-a",
                managedProxyNodeName: "Tokyo"
            ),
            Self.makeAccount(
                id: "override-b",
                label: "Override B",
                accountID: "acct-override-b",
                managedProxyNodeName: "Seoul"
            ),
        ]
        let probe = AccountManagedProxyNodeClearProbe(accounts: initialAccounts)
        let admin = AdminAPIClient(
            accountsHandler: { await probe.accounts() },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            clearAccountManagedProxyNodesHandler: { await probe.clearAll() }
        )
        let model = DesktopAppModel(
            admin: admin,
            confirmClearAccountManagedProxyNodesHandler: { false }
        )
        model.accounts = initialAccounts

        await model.clearAllAccountManagedProxyNodes()

        let clearCallCount = await probe.callCount()
        XCTAssertEqual(clearCallCount, 0)
        XCTAssertEqual(model.accountManagedProxyNodeOverrideCount, 2)
        XCTAssertTrue(model.hasAccountManagedProxyNodeOverrides)
        XCTAssertTrue(model.banners.isEmpty)
    }

    @MainActor
    func testClearAllAccountManagedProxyNodesCallsAdminReloadsAccountsAndShowsSuccess() async {
        let initialAccounts = [
            Self.makeAccount(
                id: "override-a",
                label: "Override A",
                accountID: "acct-override-a",
                managedProxyNodeName: "Tokyo"
            ),
            Self.makeAccount(
                id: "follow-global",
                label: "Follow Global",
                accountID: "acct-follow-global"
            ),
            Self.makeAccount(
                id: "override-b",
                label: "Override B",
                accountID: "acct-override-b",
                managedProxyNodeName: "Seoul"
            ),
        ]
        let probe = AccountManagedProxyNodeClearProbe(accounts: initialAccounts)
        let admin = AdminAPIClient(
            accountsHandler: { await probe.accounts() },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            clearAccountManagedProxyNodesHandler: { await probe.clearAll() }
        )
        let model = DesktopAppModel(
            admin: admin,
            confirmClearAccountManagedProxyNodesHandler: { true }
        )
        model.accounts = initialAccounts

        await model.clearAllAccountManagedProxyNodes()

        let clearCallCount = await probe.callCount()
        XCTAssertEqual(clearCallCount, 1)
        XCTAssertEqual(model.accountManagedProxyNodeOverrideCount, 0)
        XCTAssertFalse(model.hasAccountManagedProxyNodeOverrides)
        XCTAssertTrue(model.accounts.allSatisfy { $0.managedProxyNodeName == nil })
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.localization.successTitle(for: .clearAccountManagedProxyNodes))
        XCTAssertEqual(
            model.banners.first?.detail,
            model.localization.successDetail(for: .clearAccountManagedProxyNodes, rawDetail: "2")
        )
    }

    @MainActor
    func testAccountCardNodeActionTitleUsesOutboundNodeLabel() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        XCTAssertEqual(model.accountCardNodeActionTitle, "Outbound Node")
    }

    @MainActor
    func testOpenAccountModelRoutingSheetSupportsOAuthAndManualAccounts() {
        let model = DesktopAppModel()
        let oauthAccount = Self.makeAccount(
            id: "oauth-model-routing",
            label: "OAuth Routing",
            accountID: "acct-oauth-routing",
            modelRouting: AccountModelRoutingConfig(
                defaultTargetModel: "claude-final",
                mappings: [.init(sourceModel: "claude-sonnet-4-5", targetModel: "claude-upstream")]
            )
        )
        let apiKeyAccount = Self.makeAccount(
            id: "manual-model-routing",
            label: "Manual Routing",
            accountID: "acct-manual-routing",
            authMode: .openAIAPIKey,
            modelRouting: AccountModelRoutingConfig(
                mappings: [.init(sourceModel: "gpt-5.4", targetModel: "account-final-model")]
            )
        )

        model.openAccountModelRoutingSheet(oauthAccount)
        XCTAssertEqual(model.accountModelRoutingDraft?.accountID, oauthAccount.id)
        XCTAssertEqual(model.accountModelRoutingDraft?.defaultTargetModel, "claude-final")
        XCTAssertEqual(
            model.accountModelRoutingDraft?.mappings,
            [.init(sourceModel: "claude-sonnet-4-5", targetModel: "claude-upstream")]
        )

        model.openAccountModelRoutingSheet(apiKeyAccount)
        XCTAssertEqual(model.accountModelRoutingDraft?.accountID, apiKeyAccount.id)
        XCTAssertEqual(model.accountModelRoutingDraft?.defaultTargetModel, "")
        XCTAssertEqual(
            model.accountModelRoutingDraft?.mappings,
            [.init(sourceModel: "gpt-5.4", targetModel: "account-final-model")]
        )
    }

    @MainActor
    func testAccountModelRoutingStatusTextCoversEmptyDefaultMappingsAndCombinedStates() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english

        let empty = Self.makeAccount(
            id: "routing-empty",
            label: "Empty",
            accountID: "acct-routing-empty"
        )
        let defaultOnly = Self.makeAccount(
            id: "routing-default",
            label: "Default",
            accountID: "acct-routing-default",
            modelRouting: AccountModelRoutingConfig(defaultTargetModel: "account-default")
        )
        let mappingsOnly = Self.makeAccount(
            id: "routing-mappings",
            label: "Mappings",
            accountID: "acct-routing-mappings",
            modelRouting: AccountModelRoutingConfig(
                mappings: [
                    .init(sourceModel: "gpt-5.4", targetModel: "mapped-a"),
                    .init(sourceModel: "gpt-4.1", targetModel: "mapped-b"),
                ]
            )
        )
        let combined = Self.makeAccount(
            id: "routing-combined",
            label: "Combined",
            accountID: "acct-routing-combined",
            modelRouting: AccountModelRoutingConfig(
                defaultTargetModel: "account-default",
                mappings: [.init(sourceModel: "gpt-5.4", targetModel: "mapped-a")]
            )
        )

        XCTAssertEqual(model.accountModelRoutingStatusText(empty), "Not Configured")
        XCTAssertEqual(model.accountModelRoutingStatusText(defaultOnly), "Default -> account-default")
        XCTAssertEqual(model.accountModelRoutingStatusText(mappingsOnly), "2 mappings")
        XCTAssertEqual(model.accountModelRoutingStatusText(combined), "Default -> account-default · 1 mappings")
    }

    @MainActor
    func testSubmitAccountModelRoutingUpdateCallsAdminAndReloadsAccounts() async {
        let updatedRouting = AccountModelRoutingConfig(
            defaultTargetModel: "custom-default",
            mappings: [.init(sourceModel: "gpt-5.4", targetModel: "account-target")]
        )
        let updatedAccount = Self.makeAccount(
            id: "account-model-update",
            label: "Model Update",
            accountID: "acct-model-update",
            modelRouting: updatedRouting
        )
        let probe = AccountModelRoutingUpdateProbe()
        let admin = AdminAPIClient(
            accountsHandler: { [updatedAccount] in [updatedAccount] },
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            getStatsHandler: { Self.makeStatsSummary(totalRequests: 0) },
            getSettingsHandler: { AppConfig() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            updateAccountModelRoutingHandler: { id, input in
                await probe.record(id: id, input: input)
                return updatedAccount
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accountModelRoutingDraft = DesktopAppModel.AccountModelRoutingDraft(
            accountID: updatedAccount.id,
            accountKey: updatedAccount.accountKey,
            label: updatedAccount.label,
            defaultTargetModel: "  custom-default  ",
            mappings: [
                .init(sourceModel: " gpt-5.4 ", targetModel: " first-target "),
                .init(sourceModel: "gpt-5.4", targetModel: "account-target"),
                .init(sourceModel: "", targetModel: "ignored"),
            ]
        )

        await model.submitAccountModelRoutingUpdate()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.id, updatedAccount.id)
        XCTAssertEqual(
            snapshot.input,
            UpdateAccountModelRoutingRequest(
                defaultTargetModel: "custom-default",
                mappings: [.init(sourceModel: "gpt-5.4", targetModel: "account-target")]
            )
        )
        XCTAssertNil(model.accountModelRoutingDraft)
        XCTAssertEqual(model.accounts.first?.modelRouting, updatedRouting)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.localization.successTitle(for: .updateAccountModelRouting))
        XCTAssertEqual(
            model.banners.first?.detail,
            model.localization.successDetail(for: .updateAccountModelRouting, rawDetail: updatedAccount.label)
        )
    }

    @MainActor
    func testAccountUsageTilesShowTodayTokensForAPIKeyAccounts() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let account = Self.makeAccount(
            id: "api-account",
            label: "API Account",
            accountID: "acct-api",
            authMode: .openAIAPIKey,
            todayTokenUsage: AccountTodayTokenUsage(inputTokens: 1_200, outputTokens: 3_400)
        )

        let tiles = model.accountUsageTiles(for: account)

        XCTAssertEqual(tiles.map(\.title), [model.text(.labelInputTokens), model.text(.labelOutputTokens)])
        XCTAssertEqual(model.accountTokenText(1_200), "1.2k")
        XCTAssertEqual(model.accountTokenText(3_400), "3.4k")
        XCTAssertEqual(model.accountTokenHelp(1_200), "1,200")
        XCTAssertEqual(model.accountTokenHelp(3_400), "3,400")
        XCTAssertEqual(tiles[0].value, "1.2k")
        XCTAssertEqual(tiles[0].helpText, "1,200")
        XCTAssertEqual(tiles[1].value, "3.4k")
        XCTAssertEqual(tiles[1].helpText, "3,400")
    }

    @MainActor
    func testAccountUsageTilesShowTodayTokensForAnthropicOAuthAccounts() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let account = Self.makeAccount(
            id: "anthropic-oauth-account",
            label: "Anthropic OAuth",
            accountID: "acct-anthropic-oauth",
            authMode: .anthropicSubscriptionOAuth,
            todayTokenUsage: AccountTodayTokenUsage(inputTokens: 5_600, outputTokens: 7_800)
        )

        let tiles = model.accountUsageTiles(for: account)

        XCTAssertEqual(tiles.map(\.title), [model.text(.labelInputTokens), model.text(.labelOutputTokens)])
        XCTAssertEqual(tiles[0].value, "5.6k")
        XCTAssertEqual(tiles[0].helpText, "5,600")
        XCTAssertEqual(tiles[1].value, "7.8k")
        XCTAssertEqual(tiles[1].helpText, "7,800")
    }

    @MainActor
    func testAccountUsageTilesKeepQuotaWindowsForChatGPTAccounts() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let resetAt = Helpers.now() + 3_600
        let usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "plus",
            fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: resetAt),
            oneWeek: UsageWindow(usedPercent: 60, windowSeconds: 604_800, resetAt: resetAt + 86_400),
            credits: nil
        )
        let account = Self.makeAccount(
            id: "chatgpt-account",
            label: "ChatGPT Account",
            accountID: "acct-chatgpt",
            usage: usage
        )

        let tiles = model.accountUsageTiles(for: account)

        XCTAssertEqual(tiles.map(\.title), ["5H", "1W", model.text(.labelCredits)])
        XCTAssertEqual(tiles[0].value, model.usagePercentText(usage.fiveHour))
        XCTAssertEqual(tiles[0].subtitle, "Resets\n\(DesktopDateTimeFormat.compactString(fromUnixSeconds: resetAt))")
        XCTAssertEqual(tiles[1].value, model.usagePercentText(usage.oneWeek))
        XCTAssertEqual(tiles[1].subtitle, "Resets\n\(DesktopDateTimeFormat.compactString(fromUnixSeconds: resetAt + 86_400))")
        XCTAssertNil(tiles[2].subtitle)
    }

    @MainActor
    func testAccountUsageTilesHideQuotaWindowsUntilOpenAIOAuthRefresh() {
        let model = DesktopAppModel()
        let resetAt = Helpers.now() + 3_600
        let usage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "plus",
            fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: resetAt),
            oneWeek: UsageWindow(usedPercent: 60, windowSeconds: 604_800, resetAt: nil),
            credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "18.88")
        )
        let account = Self.makeAccount(
            id: "hidden-chatgpt-account",
            label: "Hidden ChatGPT Account",
            accountID: "acct-hidden-chatgpt",
            usage: usage,
            usageWindowsVisible: false
        )

        let tiles = model.accountUsageTiles(for: account)

        XCTAssertEqual(tiles.map(\.title), ["5H", "1W", model.text(.labelCredits)])
        XCTAssertEqual(tiles[0].value, "-")
        XCTAssertNil(tiles[0].subtitle)
        XCTAssertEqual(tiles[1].value, "-")
        XCTAssertEqual(tiles[2].value, model.creditsText(usage.credits))
    }

    @MainActor
    func testAccountRuntimeIssueTextShowsQuotaResetTimeWhileBlocked() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let resetAt = Helpers.now() + 3600
        let account = Self.makeAccount(
            id: "quota-account",
            label: "Quota Account",
            accountID: "acct-quota",
            usage: UsageSnapshot(
                fetchedAt: Helpers.now(),
                planType: "free",
                fiveHour: nil,
                oneWeek: UsageWindow(usedPercent: 100, windowSeconds: 604_800, resetAt: resetAt),
                credits: nil
            )
        )

        XCTAssertEqual(model.accountRuntimeStatusText(account), "Quota Blocked")
        XCTAssertEqual(
            model.accountRuntimeIssueText(account),
            "Over quota until \(DesktopDateTimeFormat.string(fromUnixSeconds: resetAt))"
        )
    }

    @MainActor
    func testAccountRuntimeIssueTextSuppressesExpiredUsageLimitErrorAndUsageRecovers() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let expiredUsage = UsageSnapshot(
            fetchedAt: Helpers.now(),
            planType: "free",
            fiveHour: UsageWindow(usedPercent: 100, windowSeconds: 18_000, resetAt: Helpers.now() - 30),
            oneWeek: nil,
            credits: nil
        )
        let account = Self.makeAccount(
            id: "expired-account",
            label: "Expired Account",
            accountID: "acct-expired",
            usage: expiredUsage,
            usageError: "usage_limit_reached, plan=free, resets_at=2026-04-14 08:00:00"
        )

        XCTAssertEqual(model.accountRuntimeStatusText(account), "Running")
        XCTAssertNil(model.accountRuntimeIssueText(account))
        XCTAssertEqual(model.usagePercentText(expiredUsage.fiveHour), "100%")
    }

    @MainActor
    func testAccountRuntimeIssueTextLocalizesGoogleGeminiMultipleCredentialsError() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        let account = Self.makeAccount(
            id: "gemini-account",
            label: "Gemini",
            accountID: "acct-gemini",
            authMode: .openAIAPIKey,
            providerPreset: .googleGeminiCompatible,
            upstreamBaseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            usageError: """
            [{
              "error": {
                "code": 400,
                "message": "Multiple authentication credentials received. Please pass only one.",
                "status": "INVALID_ARGUMENT"
              }
            }]
            """
        )

        XCTAssertEqual(
            model.accountRuntimeIssueText(account),
            model.text(.errorManualAccountGoogleGeminiAPIKeyOnly)
        )
    }

    func testLocalServiceStateIsCheckingWhenStatusUnavailable() {
        let state = ServiceControlResolver.localState(
            localStatus: nil,
            proxyStatus: nil,
            operation: .idle
        )

        XCTAssertEqual(state, .checking)
    }

    func testLocalServiceStatePrefersOperationTransitions() {
        let local = LocalServiceStatus(
            installed: true,
            running: true,
            launchctlState: "running",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )

        XCTAssertEqual(
            ServiceControlResolver.localState(localStatus: local, proxyStatus: nil, operation: .starting),
            .starting
        )
        XCTAssertEqual(
            ServiceControlResolver.localState(localStatus: local, proxyStatus: nil, operation: .stopping),
            .stopping
        )
    }

    func testLocalServiceStateIsHealthyWhenDaemonAndAdminAreRunning() {
        let local = LocalServiceStatus(
            installed: true,
            running: true,
            launchctlState: "running",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )
        let proxy = ProxyStatus(
            running: true,
            publicBaseURL: "http://127.0.0.1:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://127.0.0.1:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "key",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )

        let state = ServiceControlResolver.localState(
            localStatus: local,
            proxyStatus: proxy,
            operation: .idle
        )

        XCTAssertEqual(state, .runningHealthy)
    }

    func testLocalServiceStateIsDegradedWhenProcessExistsButAdminFails() {
        let local = LocalServiceStatus(
            installed: true,
            running: true,
            launchctlState: "running",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )

        let state = ServiceControlResolver.localState(
            localStatus: local,
            proxyStatus: nil,
            operation: .idle
        )

        XCTAssertEqual(state, .runningDegraded)
    }

    func testLocalServiceStateDistinguishesStoppedAndNotInstalled() {
        let stopped = LocalServiceStatus(
            installed: true,
            running: false,
            launchctlState: "registered",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )
        let notInstalled = LocalServiceStatus(
            installed: false,
            running: false,
            launchctlState: "not_installed",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )

        XCTAssertEqual(
            ServiceControlResolver.localState(localStatus: stopped, proxyStatus: nil, operation: .idle),
            .stopped
        )
        XCTAssertEqual(
            ServiceControlResolver.localState(localStatus: notInstalled, proxyStatus: nil, operation: .idle),
            .notInstalled
        )
    }

    func testRemoteServiceStateHandlesUnloadedAndUnreachable() {
        XCTAssertEqual(
            ServiceControlResolver.remoteState(status: nil, loadError: nil, operation: .idle, hostID: "host-1"),
            .unloaded
        )
        XCTAssertEqual(
            ServiceControlResolver.remoteState(status: nil, loadError: "ssh timeout", operation: .idle, hostID: "host-1"),
            .unreachable
        )
    }

    func testRemoteServiceStateHandlesRunningStoppedAndTransitions() {
        let running = RemoteDeployStatus(
            hostID: "host-1",
            installed: true,
            serviceInstalled: true,
            running: true,
            enabled: true,
            architecture: "arm64",
            baseURL: "http://host:8787/v1",
            apiKey: nil,
            lastError: nil
        )
        let stopped = RemoteDeployStatus(
            hostID: "host-1",
            installed: true,
            serviceInstalled: true,
            running: false,
            enabled: true,
            architecture: "arm64",
            baseURL: "http://host:8787/v1",
            apiKey: nil,
            lastError: nil
        )

        XCTAssertEqual(
            ServiceControlResolver.remoteState(status: running, loadError: nil, operation: .idle, hostID: "host-1"),
            .running
        )
        XCTAssertEqual(
            ServiceControlResolver.remoteState(status: stopped, loadError: nil, operation: .idle, hostID: "host-1"),
            .stopped
        )
        XCTAssertEqual(
            ServiceControlResolver.remoteState(status: stopped, loadError: nil, operation: .starting(hostID: "host-1"), hostID: "host-1"),
            .starting
        )
        XCTAssertEqual(
            ServiceControlResolver.remoteState(status: running, loadError: nil, operation: .stopping(hostID: "host-1"), hostID: "host-1"),
            .stopping
        )
    }

    func testRequestLogFilterStateBuildsCustomQuery() {
        let fromDate = Date(timeIntervalSince1970: 1_710_000_000)
        let toDate = Date(timeIntervalSince1970: 1_710_003_600)
        let state = RequestLogFilterState(
            timePreset: .custom,
            fromDate: fromDate,
            toDate: toDate,
            selectedAPIKey: "sk-local-history",
            selectedAccountKey: "principal-1|account-1",
            selectedClientSource: .gemini,
            selectedModel: "gpt-5.4",
            sortBy: .latency,
            sortDirection: .ascending,
            page: 3,
            pageSize: 25
        )

        let query = state.query

        XCTAssertEqual(query.timePreset, .custom)
        XCTAssertEqual(query.from, 1_710_000_000)
        XCTAssertEqual(query.to, 1_710_003_600)
        XCTAssertEqual(query.apiKey, "sk-local-history")
        XCTAssertEqual(query.accountKey, "principal-1|account-1")
        XCTAssertEqual(query.clientSource, .gemini)
        XCTAssertEqual(query.model, "gpt-5.4")
        XCTAssertEqual(query.sortBy, .latency)
        XCTAssertEqual(query.sortDirection, .ascending)
        XCTAssertEqual(query.page, 3)
        XCTAssertEqual(query.pageSize, 25)
    }

    func testRequestLogFilterStateOmitsManualDatesForPresetRange() {
        let state = RequestLogFilterState(
            timePreset: .lastHour,
            fromDate: Date(timeIntervalSince1970: 100),
            toDate: Date(timeIntervalSince1970: 200),
            selectedAPIKey: "",
            selectedModel: ""
        )

        let query = state.query

        XCTAssertEqual(query.timePreset, .lastHour)
        XCTAssertNil(query.from)
        XCTAssertNil(query.to)
        XCTAssertNil(query.apiKey)
        XCTAssertNil(query.accountKey)
        XCTAssertNil(query.clientSource)
        XCTAssertNil(query.model)
    }

    func testRequestLogFilterStateDefaultStateUsesProvidedNow() {
        let now = Date(timeIntervalSince1970: 1_776_200_000)
        let state = RequestLogFilterState.defaultState(now: now)

        XCTAssertEqual(state.timePreset, .last24Hours)
        XCTAssertEqual(state.fromDate, now.addingTimeInterval(-86_400))
        XCTAssertEqual(state.toDate, now)
        XCTAssertEqual(state.selectedAPIKey, "")
        XCTAssertEqual(state.selectedAccountKey, "")
        XCTAssertNil(state.selectedClientSource)
        XCTAssertEqual(state.selectedModel, "")
        XCTAssertEqual(state.sortBy, .time)
        XCTAssertEqual(state.sortDirection, .descending)
        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.pageSize, 50)
    }

    @MainActor
    func testRequestLogsAccountOptionsUseAccountPoolOrderAndDisambiguateDuplicateLabels() {
        let model = DesktopAppModel()
        model.accounts = [
            Self.makeAccount(
                id: "account-2",
                label: "Shared Label",
                email: "",
                accountID: "account-2",
                updatedAt: 120,
                selectionOrder: 1
            ),
            Self.makeAccount(
                id: "account-1",
                label: "Shared Label",
                email: "shared-one@example.com",
                accountID: "account-1",
                updatedAt: 240,
                selectionOrder: 0
            ),
            Self.makeAccount(
                id: "account-3",
                label: "Unique Label",
                email: "unique@example.com",
                accountID: "account-3",
                updatedAt: 60,
                selectionOrder: 2
            ),
        ]

        let options = model.requestLogsAccountOptions

        XCTAssertEqual(options.map(\.accountKey), ["key-account-1", "key-account-2", "key-account-3"])
        XCTAssertEqual(options.map(\.title), [
            "Shared Label · shared-one@example.com",
            "Shared Label · account-2",
            "Unique Label",
        ])
    }

    @MainActor
    func testRequestLogsAccountOptionsKeepMissingSelectedAccountVisible() {
        let model = DesktopAppModel()
        model.requestLogsDraftFilterState.selectedAccountKey = "missing|account"
        model.requestLogPage = RequestLogPage(
            entries: [
                Self.makeRequestLogEntry(
                    id: 1,
                    model: "gpt-5.4",
                    apiKey: "sk-history",
                    accountKey: "missing|account",
                    accountLabel: "Removed Account"
                )
            ],
            totalCount: 1,
            page: 1,
            pageSize: 50
        )

        let options = model.requestLogsAccountOptions

        XCTAssertEqual(options.first?.accountKey, "missing|account")
        XCTAssertEqual(options.first?.title, "Removed Account · missing|account")
    }

    @MainActor
    func testProxyTestAccountOptionsIncludeAutoSelectAndDisambiguateDuplicateLabels() {
        let model = DesktopAppModel()
        model.accounts = [
            Self.makeAccount(
                id: "account-2",
                label: "Shared Label",
                email: "",
                accountID: "account-2",
                selectionOrder: 1
            ),
            Self.makeAccount(
                id: "account-1",
                label: "Shared Label",
                email: "shared-one@example.com",
                accountID: "account-1",
                selectionOrder: 0
            ),
            Self.makeAccount(
                id: "account-3",
                label: "Unique Label",
                email: "unique@example.com",
                accountID: "account-3",
                selectionOrder: 2
            ),
        ]

        let options = model.proxyTestAccountOptions

        XCTAssertEqual(options.map(\.accountKey), ["", "key-account-1", "key-account-2", "key-account-3"])
        XCTAssertEqual(options.map(\.title), [
            model.text(.optionAutoSelectByOrder),
            "Shared Label · shared-one@example.com",
            "Shared Label · account-2",
            "Unique Label",
        ])
    }

    @MainActor
    func testPresentAccountOrderSheetUsesAllAccountsInSelectionOrder() {
        let model = DesktopAppModel()
        model.accounts = [
            Self.makeAccount(id: "account-2", label: "Second", accountID: "account-2", selectionOrder: 1),
            Self.makeAccount(id: "account-1", label: "First", accountID: "account-1", selectionOrder: 0),
            Self.makeAccount(id: "account-3", label: "Third", accountID: "account-3", selectionOrder: 2),
        ]
        model.accountPoolFilters = AccountPoolFilterState(searchQuery: "First")

        model.presentAccountOrderSheet()

        XCTAssertEqual(model.accountOrderDraft?.accounts.map(\.id), ["account-1", "account-2", "account-3"])
    }

    @MainActor
    func testAccountRuntimeStatusShowsCoolingDownForAPIKeyAccount() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "account-1",
            label: "API Key",
            accountID: "account-1",
            authMode: .openAIAPIKey,
            cooldownUntil: Helpers.now() + 3_600
        )

        XCTAssertEqual(model.accountRuntimeStatusText(account), model.text(.statusCoolingDown))
        XCTAssertTrue(model.accountRuntimeIssueText(account)?.contains("API") == true || model.accountRuntimeIssueText(account)?.contains("冷却") == true)
    }

    @MainActor
    func testSubmitAccountOrderUpdateRefreshesAccountsAndPublishesSuccess() async {
        let reorderProbe = AccountOrderUpdateProbe()
        let reorderedAccounts = [
            Self.makeAccount(id: "account-2", label: "Second", accountID: "account-2", selectionOrder: 0),
            Self.makeAccount(id: "account-1", label: "First", accountID: "account-1", selectionOrder: 1),
        ]
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                updateAccountOrderHandler: { payload in
                    await reorderProbe.record(payload: payload)
                    return reorderedAccounts
                }
            )
        )
        model.accountOrderDraft = DesktopAppModel.AccountOrderDraft(accounts: [
            Self.makeAccount(id: "account-2", label: "Second", accountID: "account-2", selectionOrder: 1),
            Self.makeAccount(id: "account-1", label: "First", accountID: "account-1", selectionOrder: 0),
        ])

        await model.submitAccountOrderUpdate()

        let payload = await reorderProbe.payload()
        XCTAssertEqual(payload?.orderedAccountIDs, ["account-2", "account-1"])
        XCTAssertEqual(model.accounts.map(\.id), ["account-2", "account-1"])
        XCTAssertNil(model.accountOrderDraft)
        XCTAssertEqual(model.banners.first?.title, model.text(.successAccountOrderUpdated))
    }

    @MainActor
    func testDesktopDateTimeFormatUsesFixedPatternForDateAndTimestamp() throws {
        let date = try XCTUnwrap(DesktopDateTimeFormat.date(from: "2026-04-13 11:22:33"))

        XCTAssertEqual(DesktopDateTimeFormat.string(from: date), "2026-04-13 11:22:33")
        XCTAssertEqual(
            DesktopDateTimeFormat.string(fromUnixSeconds: Int64(date.timeIntervalSince1970)),
            "2026-04-13 11:22:33"
        )
    }

    @MainActor
    func testRequestLogsTimeTextUsesFixedDateTimeFormat() throws {
        let model = DesktopAppModel()
        let date = try XCTUnwrap(DesktopDateTimeFormat.date(from: "2026-04-13 09:08:07"))
        model.requestLogsLastRefreshedAt = date

        XCTAssertEqual(model.requestLogsLastRefreshedText, "2026-04-13 09:08:07")
        XCTAssertEqual(
            model.requestLogTimeText(Int64(date.timeIntervalSince1970)),
            "2026-04-13 09:08:07"
        )
    }

    @MainActor
    func testRequestLogTokenSummaryUsesReadableLocalizedLabels() {
        let entry = RequestLogEntry(
            id: 1,
            timestamp: 1_776_052_953,
            endpoint: "/v1/responses",
            model: "gpt-5",
            apiKey: "sk-local",
            accountKey: "acct",
            accountLabel: "OAuth",
            success: true,
            latencyMS: 320,
            inputTokens: 16,
            outputTokens: 42,
            totalTokens: 58,
            cacheHitTokens: 8,
            failureCategory: "none",
            errorSummary: nil
        )

        let zhModel = DesktopAppModel()
        zhModel.preferences.languageMode = .zhHans
        let zhSummary = zhModel.requestLogTokenSummary(entry)

        XCTAssertEqual(zhSummary.primaryLine, "输入 16 / 输出 42")
        XCTAssertEqual(zhSummary.secondaryLine, "总计 58 / 缓存 8")

        let enModel = DesktopAppModel()
        enModel.preferences.languageMode = .english
        let enSummary = enModel.requestLogTokenSummary(entry)

        XCTAssertEqual(enSummary.primaryLine, "Input 16 / Output 42")
        XCTAssertEqual(enSummary.secondaryLine, "Total 58 / Cache 8")
    }

    @MainActor
    func testRequestLogCacheHitTextDistinguishesZeroFromMissing() {
        let model = DesktopAppModel()

        XCTAssertEqual(model.requestLogCacheHitText(0), "0")
        XCTAssertEqual(model.requestLogCacheHitText(nil), model.text(.statusNotApplicable))
    }

    @MainActor
    func testRequestLogClientSourceTextUsesReadableLocalizedLabels() {
        let zhModel = DesktopAppModel()
        zhModel.preferences.languageMode = .zhHans

        XCTAssertEqual(zhModel.requestLogClientSourceText(.codex), "Codex")
        XCTAssertEqual(zhModel.requestLogClientSourceText(.claudeCode), "Claude Code")
        XCTAssertEqual(zhModel.requestLogClientSourceText(.gemini), "Gemini")
        XCTAssertEqual(zhModel.requestLogClientSourceText(.other), "其它")

        let enModel = DesktopAppModel()
        enModel.preferences.languageMode = .english

        XCTAssertEqual(enModel.requestLogClientSourceText(.other), "Other")
    }

    func testRequestLogErrorSummaryCopySupportPreservesFullRawValue() {
        let rawValue = "Gateway timeout while refreshing token.\nrequest_id=req_123   "

        XCTAssertEqual(
            RequestLogErrorSummaryCopySupport.copyValue(from: rawValue),
            rawValue
        )
    }

    func testRequestLogErrorSummaryCopySupportRejectsBlankValue() {
        XCTAssertNil(RequestLogErrorSummaryCopySupport.copyValue(from: nil))
        XCTAssertNil(RequestLogErrorSummaryCopySupport.copyValue(from: "   \n\t  "))
    }

    func testRequestLogErrorSummaryCopyUsesDedicatedLocalizedMessages() {
        let zh = LocalizationStore(mode: .zhHans, preferredLanguages: ["zh-Hans"])
        XCTAssertEqual(zh.text(.actionCopyErrorSummary), "复制错误摘要")
        XCTAssertEqual(zh.text(.successCopiedErrorSummary), "错误摘要已复制")

        let en = LocalizationStore(mode: .english, preferredLanguages: ["en-US"])
        XCTAssertEqual(en.text(.actionCopyErrorSummary), "Copy Error Summary")
        XCTAssertEqual(en.text(.successCopiedErrorSummary), "Error summary copied")
    }

    @MainActor
    func testMainBannerQueueStacksNewestFirstAndSupportsDismissAndClear() {
        let model = DesktopAppModel()

        model.publishBanner(.success, title: "First", detail: nil)
        let firstID = try? XCTUnwrap(model.banners.first?.id)

        model.publishBanner(.warning, title: "Second", detail: "detail")

        XCTAssertEqual(model.banners.map(\.title), ["Second", "First"])
        if let firstID {
            model.dismissBanner(id: firstID)
        }
        XCTAssertEqual(model.banners.map(\.title), ["Second"])

        model.clearBanner()
        XCTAssertTrue(model.banners.isEmpty)
    }

    @MainActor
    func testRequestLogsBannerQueueSupportsStackingAndTargetedDismiss() {
        let model = DesktopAppModel()

        model.publishRequestLogsBanner(.success, title: "Exported", detail: nil)
        let exportedID = try? XCTUnwrap(model.requestLogsBanners.first?.id)

        model.publishRequestLogsBanner(.warning, title: "Missing Data", detail: "N/A")

        XCTAssertEqual(model.requestLogsBanners.map(\.title), ["Missing Data", "Exported"])
        if let exportedID {
            model.dismissRequestLogsBanner(id: exportedID)
        }
        XCTAssertEqual(model.requestLogsBanners.map(\.title), ["Missing Data"])

        model.clearRequestLogsBanner()
        XCTAssertTrue(model.requestLogsBanners.isEmpty)
    }

    @MainActor
    func testProxyTestBannersAutoDismissNonErrorsButKeepErrors() async {
        let model = DesktopAppModel()
        model.toastAutoDismissDuration = .milliseconds(20)

        model.publishProxyTestBanner(.warning, title: "Heads Up", detail: nil)
        await Self.waitForCondition { model.proxyTestBanners.isEmpty }
        XCTAssertTrue(model.proxyTestBanners.isEmpty)

        model.publishProxyTestBanner(.error, title: "Failure", detail: "detail")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.proxyTestBanners.map(\.title), ["Failure"])
    }

    @MainActor
    func testStopDaemonCancelsWithoutConfirmation() async {
        let probe = DaemonOperationProbe(running: true)
        let admin = AdminAPIClient(
            getStatusHandler: { await probe.proxyStatus() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() }
        )
        let daemon = LocalDaemonController(
            stopHandler: { await probe.recordStop() },
            statusHandler: { await probe.localStatus() }
        )
        let model = DesktopAppModel(
            admin: admin,
            daemon: daemon,
            confirmStopDaemonHandler: { false }
        )
        model.localServiceStatus = await probe.localStatus()
        model.status = await probe.proxyStatus()

        await model.stopDaemon()

        let stopCallCount = await probe.stopCallCount()
        XCTAssertEqual(stopCallCount, 0)
        XCTAssertEqual(model.localServiceOperation, .idle)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.banners.isEmpty)
    }

    @MainActor
    func testStopDaemonConfirmationContentIncludesAutoStartWarningWhenEnabled() {
        let model = DesktopAppModel()
        model.settings.autoStart = true

        let content = model.stopDaemonConfirmationContent()

        XCTAssertEqual(content.title, model.text(.confirmStopDaemonTitle))
        XCTAssertEqual(content.informativeText, model.text(.confirmStopDaemonMessage))
        XCTAssertEqual(content.warningText, model.text(.confirmStopDaemonAutoStartWarning))
    }

    @MainActor
    func testStopDaemonConfirmationContentOmitsAutoStartWarningWhenDisabled() {
        let model = DesktopAppModel()
        model.settings.autoStart = false

        let content = model.stopDaemonConfirmationContent()

        XCTAssertEqual(content.title, model.text(.confirmStopDaemonTitle))
        XCTAssertEqual(content.informativeText, model.text(.confirmStopDaemonMessage))
        XCTAssertNil(content.warningText)
    }

    @MainActor
    func testStopDaemonStopsOnlyAfterConfirmation() async {
        let probe = DaemonOperationProbe(running: true)
        let admin = AdminAPIClient(
            getStatusHandler: { await probe.proxyStatus() },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() }
        )
        let daemon = LocalDaemonController(
            stopHandler: { await probe.recordStop() },
            statusHandler: { await probe.localStatus() }
        )
        let model = DesktopAppModel(
            admin: admin,
            daemon: daemon,
            confirmStopDaemonHandler: { true }
        )
        model.localServiceStatus = await probe.localStatus()
        model.status = await probe.proxyStatus()

        await model.stopDaemon()

        let stopCallCount = await probe.stopCallCount()
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertEqual(model.localServiceOperation, .idle)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.text(.successDaemonStopped))
        XCTAssertFalse(model.localServiceStatus?.running ?? true)
    }

    @MainActor
    func testApplyLaunchConfigurationOutcomeReturnsRestartRequiredWhenRunningServiceWouldBeRestarted() {
        let outcome = LocalDaemonController.applyLaunchConfigurationOutcome(
            config: AppConfig(autoStart: true),
            didChange: true,
            status: Self.makeLocalServiceStatus(running: true, launchctlState: "running"),
            preserveRunningService: true
        )

        XCTAssertEqual(outcome, .savedButRestartRequired)
    }

    @MainActor
    func testApplyLaunchConfigurationOutcomeReturnsAppliedNowWhenServiceIsNotRunning() {
        let outcome = LocalDaemonController.applyLaunchConfigurationOutcome(
            config: AppConfig(autoStart: false),
            didChange: true,
            status: Self.makeLocalServiceStatus(running: false, launchctlState: "registered"),
            preserveRunningService: true
        )

        XCTAssertEqual(outcome, .appliedNow)
    }

    @MainActor
    func testSaveSettingsPublishesRestartRequiredWarningWithoutStoppingRunningService() async {
        let probe = DaemonOperationProbe(running: true)
        let admin = AdminAPIClient(
            getStatusHandler: { await probe.proxyStatus() },
            saveSettingsHandler: { config in config },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, preserveRunningService in
                await probe.recordApply(preserveRunningService: preserveRunningService)
                return .savedButRestartRequired
            },
            startHandler: { _ in await probe.recordStart() },
            stopHandler: { await probe.recordStop() },
            statusHandler: { await probe.localStatus() }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)

        let saved = await model.saveSettings()
        let preserveFlags = await probe.applyPreserveFlags()
        let startCallCount = await probe.startCallCount()
        let stopCallCount = await probe.stopCallCount()

        XCTAssertTrue(saved)
        XCTAssertEqual(preserveFlags, [true])
        XCTAssertEqual(startCallCount, 0)
        XCTAssertEqual(stopCallCount, 0)
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(model.banners.first?.detail, model.text(.warningLaunchConfigurationSavedRestartRequired))
        XCTAssertTrue(model.status?.running ?? false)
    }

    @MainActor
    func testSaveSettingsOutboundProxyManualConfigurationPersistsManualProxyWithoutChangingMode() async {
        let probe = ManagedProxyActionProbe()
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: true) },
            saveSettingsHandler: { config in
                await probe.recordSaveSettings(config)
                return config
            },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { config, preserveRunningService in
                await probe.recordApply(config: config, preserveRunningService: preserveRunningService)
                return .appliedNow
            },
            statusHandler: {
                LocalServiceStatus(
                    installed: true,
                    running: true,
                    launchctlState: "running",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.settings.outboundProxyMode = OutboundProxyMode.disabled
        model.settings.outboundProxy = OutboundProxySettings()
        model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)

        model.setSettingsOutboundProxyDraftMode(OutboundProxyMode.manual)
        model.settingsOutboundProxyDraft.outboundProxy.host = "127.0.0.1"
        model.settingsOutboundProxyDraft.outboundProxy.port = 7890

        let saved = await model.saveSettingsOutboundProxyManualConfiguration()
        let snapshot = await probe.snapshot()

        XCTAssertTrue(saved)
        XCTAssertEqual(snapshot.savedSettingsCount, 1)
        XCTAssertEqual(snapshot.applyLaunchConfigurationCount, 1)
        XCTAssertEqual(model.settings.outboundProxyMode, OutboundProxyMode.disabled)
        XCTAssertEqual(model.settings.outboundProxy.host, "127.0.0.1")
        XCTAssertEqual(model.settings.outboundProxy.port, 7890)
        XCTAssertEqual(model.settingsOutboundProxyDraft.mode, OutboundProxyMode.manual)
        XCTAssertFalse(model.settingsOutboundProxyManualNeedsSave)
        XCTAssertTrue(model.settingsOutboundProxyModeNeedsConfirmation)
    }

    @MainActor
    func testConfirmSettingsOutboundProxyModeChangePersistsModeAndResyncsDraft() async {
        let probe = ManagedProxyActionProbe()
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: true) },
            saveSettingsHandler: { config in
                await probe.recordSaveSettings(config)
                return config
            },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { config, preserveRunningService in
                await probe.recordApply(config: config, preserveRunningService: preserveRunningService)
                return .appliedNow
            },
            statusHandler: {
                LocalServiceStatus(
                    installed: true,
                    running: true,
                    launchctlState: "running",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.settings.outboundProxyMode = OutboundProxyMode.disabled
        model.settings.outboundProxy = OutboundProxySettings(
            scheme: .http,
            host: "127.0.0.1",
            port: 7890,
            username: "",
            password: ""
        )
        model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)
        model.setSettingsOutboundProxyDraftMode(OutboundProxyMode.manual)

        let saved = await model.confirmSettingsOutboundProxyModeChange()
        let snapshot = await probe.snapshot()

        XCTAssertTrue(saved)
        XCTAssertEqual(snapshot.savedSettingsCount, 1)
        XCTAssertEqual(snapshot.applyLaunchConfigurationCount, 1)
        XCTAssertEqual(model.settings.outboundProxyMode, OutboundProxyMode.manual)
        XCTAssertEqual(model.settingsOutboundProxyDraft.mode, OutboundProxyMode.manual)
        XCTAssertFalse(model.settingsOutboundProxyModeNeedsConfirmation)
        XCTAssertFalse(model.settingsOutboundProxyManualNeedsSave)
    }

    @MainActor
    func testConfirmSettingsOutboundProxyModeChangeRejectsSubscriptionWithoutConfiguration() async {
        let probe = ManagedProxyActionProbe()
        let admin = AdminAPIClient(
            saveSettingsHandler: { config in
                await probe.recordSaveSettings(config)
                return config
            }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { config, preserveRunningService in
                await probe.recordApply(config: config, preserveRunningService: preserveRunningService)
                return .appliedNow
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.settings.outboundProxyMode = OutboundProxyMode.disabled
        model.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)
        model.setSettingsOutboundProxyDraftMode(OutboundProxyMode.subscription)
        model.managedProxySnapshot = ManagedProxySnapshot(mode: .disabled, subscriptionConfigured: false)

        let saved = await model.confirmSettingsOutboundProxyModeChange()
        let snapshot = await probe.snapshot()

        XCTAssertFalse(saved)
        XCTAssertEqual(snapshot.savedSettingsCount, 0)
        XCTAssertEqual(snapshot.applyLaunchConfigurationCount, 0)
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(
            model.banners.first?.detail,
            model.text(.helperConfirmProxyModeChangeNeedsSubscription)
        )
    }

    @MainActor
    func testSaveProxySettingsPublishesRestartRequiredWarningWithoutStoppingRunningService() async {
        let probe = DaemonOperationProbe(running: true)
        let expectedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true
        )
        let admin = AdminAPIClient(
            getStatusHandler: { await probe.proxyStatus() },
            saveSettingsHandler: { config in config },
            getSettingsHandler: { AppConfig(outboundProxyMode: .subscription) },
            getManagedProxySnapshotHandler: { expectedSnapshot },
            saveManagedProxyConfigHandler: { payload in
                ManagedProxySnapshot(
                    mode: .subscription,
                    subscriptionConfigured: payload.subscriptionURL?.isEmpty == false,
                    subscriptionURL: payload.subscriptionURL,
                    runtimeState: .running,
                    controllerReachable: true
                )
            }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, preserveRunningService in
                await probe.recordApply(preserveRunningService: preserveRunningService)
                return .savedButRestartRequired
            },
            startHandler: { _ in await probe.recordStart() },
            stopHandler: { await probe.recordStop() },
            statusHandler: { await probe.localStatus() }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySubscriptionURLDraft = expectedSnapshot.subscriptionURL ?? ""

        await model.saveProxySettings()
        let preserveFlags = await probe.applyPreserveFlags()
        let startCallCount = await probe.startCallCount()
        let stopCallCount = await probe.stopCallCount()

        XCTAssertEqual(preserveFlags, [true])
        XCTAssertEqual(startCallCount, 0)
        XCTAssertEqual(stopCallCount, 0)
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(model.banners.first?.detail, model.text(.warningLaunchConfigurationSavedRestartRequired))
        XCTAssertEqual(model.managedProxySnapshot.subscriptionURL, expectedSnapshot.subscriptionURL)
    }

    @MainActor
    func testSaveProxySettingsRejectsInvalidSubscriptionURLBeforePersistingChanges() async {
        let probe = ManagedProxyActionProbe()
        let admin = AdminAPIClient(
            saveSettingsHandler: { config in
                await probe.recordSaveSettings(config)
                return config
            },
            saveManagedProxyConfigHandler: { payload in
                await probe.recordSavedManagedProxyConfig(payload)
                return ManagedProxySnapshot(subscriptionConfigured: payload.subscriptionURL?.isEmpty == false)
            }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { config, preserveRunningService in
                await probe.recordApply(config: config, preserveRunningService: preserveRunningService)
                return .appliedNow
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.settings.outboundProxyMode = .subscription
        model.managedProxySubscriptionURLDraft = "ftp://invalid.example.com/subscription"

        await model.saveProxySettings()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.savedSettingsCount, 0)
        XCTAssertEqual(snapshot.savedManagedProxyConfigCount, 0)
        XCTAssertEqual(snapshot.applyLaunchConfigurationCount, 0)
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertTrue(model.banners.first?.detail?.contains("HTTP") == true)
    }

    @MainActor
    func testSaveManagedProxyHealthcheckURLUsesIndependentSaveChainAndNormalizesBlankDraft() async {
        let probe = ManagedProxyActionProbe()
        let updatedSnapshot = ManagedProxySnapshot(
            mode: .manual,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            healthcheckURL: ManagedProxyConfigSummary.defaultHealthcheckURL,
            runtimeState: .running,
            controllerReachable: true,
            currentNodeName: "Tokyo"
        )
        let admin = AdminAPIClient(
            saveSettingsHandler: { config in
                await probe.recordSaveSettings(config)
                return config
            },
            saveManagedProxyConfigHandler: { payload in
                await probe.recordSavedManagedProxyConfig(payload)
                return ManagedProxySnapshot(subscriptionConfigured: payload.subscriptionURL?.isEmpty == false)
            },
            saveManagedProxyHealthcheckConfigHandler: { payload in
                await probe.recordSavedManagedProxyHealthcheckConfig(payload)
                return updatedSnapshot
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.status = Self.makeProxyStatus(running: true)
        model.settings.outboundProxyMode = .manual
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        model.managedProxyHealthcheckURLDraft = "   "
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .manual,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            healthcheckURL: "https://old.example.com/generate_204",
            runtimeState: .running
        )

        await model.saveManagedProxyHealthcheckURL()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.savedSettingsCount, 0)
        XCTAssertEqual(snapshot.savedManagedProxyConfigCount, 0)
        XCTAssertEqual(snapshot.savedManagedProxyHealthcheckConfigCount, 1)
        XCTAssertEqual(model.managedProxySubscriptionURLDraft, "https://example.com/subscription")
        XCTAssertEqual(model.managedProxyHealthcheckURLDraft, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertEqual(model.managedProxySnapshot.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertEqual(model.settings.outboundProxyMode, .manual)
        XCTAssertEqual(model.banners.first?.tone, .success)
    }

    @MainActor
    func testSaveManagedProxyHealthcheckURLRejectsInvalidURLBeforePersistingChanges() async {
        let probe = ManagedProxyActionProbe()
        let admin = AdminAPIClient(
            saveManagedProxyHealthcheckConfigHandler: { payload in
                await probe.recordSavedManagedProxyHealthcheckConfig(payload)
                return ManagedProxySnapshot(healthcheckURL: payload.healthcheckURL ?? "")
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.managedProxyHealthcheckURLDraft = "ftp://invalid.example.com/generate_204"

        await model.saveManagedProxyHealthcheckURL()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.savedManagedProxyHealthcheckConfigCount, 0)
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertTrue(model.banners.first?.detail?.contains("HTTP") == true)
    }

    @MainActor
    func testSaveProxySettingsLocalizesManagedProxyKeychainErrors() async {
        let admin = AdminAPIClient(
            saveSettingsHandler: { config in config },
            saveManagedProxyConfigHandler: { _ in
                throw ProxyError.message("Keychain read failed (-25293) for mihomo-controller-secret")
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.preferences.languageMode = .zhHans
        model.settings.outboundProxyMode = .subscription
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"

        await model.saveProxySettings()

        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertEqual(
            model.banners.first?.detail,
            "无法访问 macOS 钥匙串，请允许 AI Coding Proxy 访问钥匙串后再试。"
        )
    }

    @MainActor
    func testManagedProxyRuntimeActionsWriteBackLatestSnapshots() async {
        let probe = ManagedProxyActionProbe()
        let updatedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68, lastHealthcheckAt: 1_710_000_100),
                ManagedProxyNode(name: "Seoul", type: "vmess", isCurrent: false, isPinned: false, alive: true, lastDelayMS: 96, lastHealthcheckAt: 1_710_000_090),
            ]
        )
        let selectedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Seoul",
            pinnedNodeName: "Seoul",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Seoul", type: "vmess", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 84, lastHealthcheckAt: 1_710_000_200),
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: false, isPinned: false, alive: true, lastDelayMS: 68, lastHealthcheckAt: 1_710_000_100),
            ]
        )
        let healthcheckedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Seoul",
            pinnedNodeName: "Seoul",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Seoul", type: "vmess", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 71, lastHealthcheckAt: 1_710_000_300),
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: false, isPinned: false, alive: true, lastDelayMS: 68, lastHealthcheckAt: 1_710_000_100),
            ]
        )
        let admin = AdminAPIClient(
            updateManagedProxySubscriptionHandler: {
                await probe.recordUpdateManagedProxySubscription()
                return updatedSnapshot
            },
            selectManagedProxyNodeHandler: { request in
                await probe.recordSelectedManagedProxyNode(request.name)
                return selectedSnapshot
            },
            healthcheckManagedProxyHandler: { request in
                await probe.recordManagedProxyHealthcheck(request.nodeName)
                return healthcheckedSnapshot
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running
        )

        await model.updateManagedProxySubscription()
        XCTAssertEqual(model.managedProxySnapshot, updatedSnapshot)

        await model.selectManagedProxyNode("Seoul")
        XCTAssertEqual(model.managedProxySnapshot, selectedSnapshot)

        await model.healthcheckManagedProxy(nodeName: "Seoul")
        XCTAssertEqual(model.managedProxySnapshot, healthcheckedSnapshot)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.updateManagedProxySubscriptionCount, 1)
        XCTAssertEqual(snapshot.selectedManagedProxyNodeNames, ["Seoul"])
        XCTAssertEqual(snapshot.healthcheckedManagedProxyNodeNames, ["Seoul"])
    }

    @MainActor
    func testSwitchManagedProxyCurrentNodeChangesOnlyCurrentNode() async {
        let probe = ManagedProxyActionProbe()
        let switchedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Seoul",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Seoul", type: "vmess", isCurrent: true, alive: true, lastDelayMS: 71),
                ManagedProxyNode(name: "Tokyo", type: "ss", isPinned: true, alive: true, lastDelayMS: 68),
            ]
        )
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                switchManagedProxyCurrentNodeHandler: { request in
                    await probe.recordSwitchedManagedProxyCurrentNode(request.name)
                    return switchedSnapshot
                }
            )
        )
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 71),
            ]
        )

        await model.switchManagedProxyCurrentNode("Seoul")

        XCTAssertEqual(model.managedProxySnapshot.currentNodeName, "Seoul")
        XCTAssertEqual(model.managedProxySnapshot.pinnedNodeName, "Tokyo")
        XCTAssertEqual(model.managedProxyFocusedNodeName, "Seoul")
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.switchedManagedProxyCurrentNodeNames, ["Seoul"])
    }

    @MainActor
    func testUpdateManagedProxyPinnedNodeChangesOnlyPinnedDefault() async {
        let probe = ManagedProxyActionProbe()
        let pinnedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Seoul",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", isPinned: true, alive: true, lastDelayMS: 84),
            ]
        )
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                updateManagedProxyPinnedNodeHandler: { request in
                    await probe.recordUpdatedManagedProxyPinnedNode(request.name)
                    return pinnedSnapshot
                }
            )
        )
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84),
            ]
        )

        await model.updateManagedProxyPinnedNode("Seoul")

        XCTAssertEqual(model.managedProxySnapshot.currentNodeName, "Tokyo")
        XCTAssertEqual(model.managedProxySnapshot.pinnedNodeName, "Seoul")
        XCTAssertEqual(model.managedProxyFocusedNodeName, "Seoul")
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.updatedManagedProxyPinnedNodeNames, ["Seoul"])
    }

    @MainActor
    func testClearManagedProxyPinnedNodeKeepsCurrentNode() async {
        let probe = ManagedProxyActionProbe()
        let clearedSnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: nil,
            pinnedNodeAvailable: false,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", alive: true, lastDelayMS: 84),
            ]
        )
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                updateManagedProxyPinnedNodeHandler: { request in
                    await probe.recordUpdatedManagedProxyPinnedNode(request.name)
                    return clearedSnapshot
                }
            )
        )
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .subscription,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Tokyo",
            pinnedNodeAvailable: true,
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, isPinned: true, alive: true, lastDelayMS: 68),
            ]
        )

        await model.updateManagedProxyPinnedNode(nil)

        XCTAssertEqual(model.managedProxySnapshot.currentNodeName, "Tokyo")
        XCTAssertNil(model.managedProxySnapshot.pinnedNodeName)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.updatedManagedProxyPinnedNodeNames, [nil])
    }

    @MainActor
    func testManagedProxyListenerTerminalCommandUsesListenerPort() {
        let model = DesktopAppModel()
        let listener = ManagedProxyListener(kind: .nodeListener, listenHost: "10.0.0.8", port: 7897, nodeName: "Tokyo")

        XCTAssertEqual(
            model.managedProxyListenerTerminalCommand(listener),
            "export https_proxy=http://10.0.0.8:7897 http_proxy=http://10.0.0.8:7897 all_proxy=socks5://10.0.0.8:7897"
        )
    }

    @MainActor
    func testCopyManagedProxyListenerTerminalCommandCopiesCommandAndShowsToast() {
        let model = DesktopAppModel()
        let listener = ManagedProxyListener(kind: .mixedPort, listenHost: "192.168.0.10", port: 7897, nodeName: "Tokyo")
        NSPasteboard.general.clearContents()

        model.copyManagedProxyListenerTerminalCommand(listener)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "export https_proxy=http://192.168.0.10:7897 http_proxy=http://192.168.0.10:7897 all_proxy=socks5://192.168.0.10:7897"
        )
        XCTAssertEqual(model.banners.first?.title, model.text(.successCopiedManagedProxyTerminalCommand))
    }

    @MainActor
    func testManagedProxyManagerViewDoesNotRenderServiceControls() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.status = Self.makeProxyStatus(running: true)
        model.managedProxySubscriptionURLDraft = "https://example.com/subscription"
        model.managedProxySnapshot = ManagedProxySnapshot(
            mode: .manual,
            subscriptionConfigured: true,
            subscriptionURL: "https://example.com/subscription",
            runtimeState: .running,
            controllerReachable: true,
            mixedPort: 7_890,
            currentNodeName: "Tokyo",
            pinnedNodeName: "Seoul",
            pinnedNodeAvailable: true,
            listeners: [
                ManagedProxyListener(kind: .mixedPort, listenHost: "127.0.0.1", port: 7_890, nodeName: "Tokyo"),
                ManagedProxyListener(kind: .nodeListener, listenHost: "127.0.0.1", port: 18_900, nodeName: "Seoul"),
            ],
            nodes: [
                ManagedProxyNode(name: "Tokyo", type: "ss", isCurrent: true, alive: true, lastDelayMS: 68),
                ManagedProxyNode(name: "Seoul", type: "vmess", isPinned: true, alive: true, lastDelayMS: 84),
            ]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let hostingView = NSHostingView(
            rootView: ManagedProxyManagerView(model: model)
                .frame(width: 1060, height: 680)
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView

        Self.renderHostedView(hostingView)

        let renderedText = Self.hostedTextValues(in: hostingView).joined(separator: "\n")
        XCTAssertFalse(renderedText.contains("Service Controls"))
        XCTAssertGreaterThanOrEqual(Self.hostedSubviewCount(in: hostingView, named: "NSScrollView"), 1)
    }

    @MainActor
    func testOpenAddProxyAPIKeySheetDefaultsDataSourceToAll() {
        let model = DesktopAppModel()

        model.openAddProxyAPIKeySheet()

        XCTAssertEqual(model.proxyAPIKeyDraft?.dataSource, .all)
        XCTAssertEqual(model.proxyAPIKeyDraft?.allowedAccountKeys, [])
    }

    @MainActor
    func testOpenEditProxyAPIKeySheetCopiesStoredAllowedAccountKeys() {
        let model = DesktopAppModel()
        let record = ProxyAPIKeyRecord(
            id: "restricted-key",
            label: "Restricted",
            key: "sk-restricted",
            dataSource: .all,
            allowedAccountKeys: ["acct-openai", "acct-anthropic"],
            enabled: true,
            createdAt: 1
        )

        model.openEditProxyAPIKeySheet(record)

        XCTAssertEqual(model.proxyAPIKeyDraft?.editingID, record.id)
        XCTAssertEqual(model.proxyAPIKeyDraft?.allowedAccountKeys, ["acct-openai", "acct-anthropic"])
    }

    @MainActor
    func testProxyAPIKeyAccountEditorContextShowsOnlyEnabledCompatibleAccountsInSelectionOrder() {
        let model = DesktopAppModel()
        let openAIFirst = Self.makeAccount(
            id: "openai-first",
            label: "OpenAI First",
            accountID: "acct-openai-first",
            selectionOrder: 1
        )
        let anthropic = Self.makeAccount(
            id: "anthropic",
            label: "Anthropic",
            accountID: "acct-anthropic",
            selectionOrder: 2,
            authMode: .anthropicSubscriptionOAuth
        )
        let openAISecond = Self.makeAccount(
            id: "openai-second",
            label: "OpenAI Second",
            accountID: "acct-openai-second",
            selectionOrder: 3
        )
        let disabledOpenAI = Self.makeAccount(
            id: "openai-disabled",
            label: "Disabled OpenAI",
            accountID: "acct-openai-disabled",
            enabled: false,
            selectionOrder: 4
        )
        model.accounts = [disabledOpenAI, openAISecond, anthropic, openAIFirst]

        let context = model.proxyAPIKeyAccountEditorContext(
            draft: ProxyAPIKeyDraft(
                dataSource: .openAI,
                allowedAccountKeys: []
            )
        )

        XCTAssertEqual(context.selectableOptions.map(\.accountKey), [openAIFirst.accountKey, openAISecond.accountKey])
        XCTAssertTrue(context.staleSelections.isEmpty)
    }

    @MainActor
    func testProxyAPIKeyAccountEditorContextPreservesStaleSelections() {
        let model = DesktopAppModel()
        let current = Self.makeAccount(
            id: "openai-current",
            label: "Current",
            accountID: "acct-openai-current",
            selectionOrder: 1
        )
        let incompatible = Self.makeAccount(
            id: "anthropic-stale",
            label: "Anthropic Stale",
            accountID: "acct-anthropic-stale",
            selectionOrder: 2,
            authMode: .anthropicSubscriptionOAuth
        )
        let disabled = Self.makeAccount(
            id: "openai-disabled",
            label: "Disabled",
            accountID: "acct-openai-disabled",
            enabled: false,
            selectionOrder: 3
        )
        model.accounts = [current, incompatible, disabled]

        let context = model.proxyAPIKeyAccountEditorContext(
            draft: ProxyAPIKeyDraft(
                dataSource: .openAI,
                allowedAccountKeys: [current.accountKey, incompatible.accountKey, disabled.accountKey, "missing-account"]
            )
        )

        XCTAssertEqual(context.selectableOptions.map(\.accountKey), [current.accountKey])
        XCTAssertEqual(context.staleSelections.map(\.accountKey), [incompatible.accountKey, disabled.accountKey, "missing-account"])
    }

    @MainActor
    func testSaveProxyAPIKeyDraftDismissesSheetOnSuccessfulPersist() async {
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            saveSettingsHandler: { config in config },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            statusHandler: {
                LocalServiceStatus(
                    installed: true,
                    running: false,
                    launchctlState: "not_registered",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.proxyAPIKeyDraft = ProxyAPIKeyDraft(
            label: "Team Key",
            key: "sk-team",
            enabled: true,
            isPrimary: true
        )

        await model.saveProxyAPIKeyDraft()

        XCTAssertNil(model.proxyAPIKeyDraft)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.settings.proxyAPIKeys.count, 1)
        XCTAssertEqual(model.settings.primaryProxyAPIKeyID, model.settings.proxyAPIKeys.first?.id)
    }

    @MainActor
    func testSaveProxyAPIKeyDraftDismissesSheetWhenPersistRequiresManualRestart() async {
        let probe = DaemonOperationProbe(running: true)
        let admin = AdminAPIClient(
            getStatusHandler: { await probe.proxyStatus() },
            saveSettingsHandler: { config in config },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, preserveRunningService in
                await probe.recordApply(preserveRunningService: preserveRunningService)
                return .savedButRestartRequired
            },
            statusHandler: { await probe.localStatus() }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.proxyAPIKeyDraft = ProxyAPIKeyDraft(
            label: "Restart Key",
            key: "sk-restart",
            enabled: true,
            isPrimary: true
        )

        await model.saveProxyAPIKeyDraft()
        let preserveFlags = await probe.applyPreserveFlags()

        XCTAssertNil(model.proxyAPIKeyDraft)
        XCTAssertEqual(preserveFlags, [true])
        XCTAssertEqual(model.banners.first?.tone, .warning)
        XCTAssertEqual(model.banners.first?.detail, model.text(.warningLaunchConfigurationSavedRestartRequired))
        XCTAssertEqual(model.settings.proxyAPIKeys.count, 1)
    }

    @MainActor
    func testSaveProxyAPIKeyDraftPersistsSelectedAnthropicDataSource() async {
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            saveSettingsHandler: { config in config },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            statusHandler: {
                LocalServiceStatus(
                    installed: true,
                    running: false,
                    launchctlState: "not_registered",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.proxyAPIKeyDraft = ProxyAPIKeyDraft(
            label: "Claude Team",
            key: "sk-claude-team",
            dataSource: .anthropic,
            enabled: true,
            isPrimary: true
        )

        await model.saveProxyAPIKeyDraft()

        XCTAssertEqual(model.settings.proxyAPIKeys.first?.dataSource, .anthropic)
        XCTAssertEqual(model.settings.primaryProxyAPIKeyRecord?.dataSource, .anthropic)
    }

    @MainActor
    func testSaveProxyAPIKeyDraftPersistsSelectedAllDataSource() async {
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            saveSettingsHandler: { config in config },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            statusHandler: {
                LocalServiceStatus(
                    installed: true,
                    running: false,
                    launchctlState: "not_registered",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.proxyAPIKeyDraft = ProxyAPIKeyDraft(
            label: "Shared Team",
            key: "sk-shared-team",
            dataSource: .all,
            enabled: true,
            isPrimary: true
        )

        await model.saveProxyAPIKeyDraft()

        XCTAssertEqual(model.settings.proxyAPIKeys.first?.dataSource, .all)
        XCTAssertEqual(model.settings.primaryProxyAPIKeyRecord?.dataSource, .all)
    }

    @MainActor
    func testSaveProxyAPIKeyDraftPersistsAllowedAccountKeys() async {
        let admin = AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            saveSettingsHandler: { config in config },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            statusHandler: {
                LocalServiceStatus(
                    installed: true,
                    running: false,
                    launchctlState: "not_registered",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        let model = DesktopAppModel(admin: admin, daemon: daemon)
        model.proxyAPIKeyDraft = ProxyAPIKeyDraft(
            label: "Restricted Team",
            key: "sk-restricted-team",
            dataSource: .all,
            allowedAccountKeys: [" key-openai ", "key-anthropic", "key-openai"],
            enabled: true,
            isPrimary: true
        )

        await model.saveProxyAPIKeyDraft()

        XCTAssertEqual(model.settings.proxyAPIKeys.first?.allowedAccountKeys, ["key-openai", "key-anthropic"])
    }

    @MainActor
    func testCompleteOAuthUsesDraftProviderFamily() async {
        let importedAccount = Self.makeAccount(
            id: "anthropic-account",
            label: "Claude OAuth",
            accountID: "acct-anthropic",
            authMode: .anthropicSubscriptionOAuth
        )
        let status = ProxyStatus(
            running: true,
            publicBaseURL: "http://127.0.0.1:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://127.0.0.1:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-local",
            activeAccountKey: importedAccount.accountKey,
            activeAccountID: importedAccount.accountID,
            activeAccountLabel: importedAccount.label,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )
        let probe = OAuthCallbackCompletionProbe()
        let admin = AdminAPIClient(
            accountsHandler: { [importedAccount] in [importedAccount] },
            completeOAuthCallbackHandler: { providerFamily, callbackURL in
                await probe.record(providerFamily: providerFamily, callbackURL: callbackURL)
                return importedAccount
            },
            getStatusHandler: { status }
        )
        let model = DesktopAppModel(admin: admin)
        model.oauthDraft = DesktopAppModel.OAuthDraft(
            providerFamily: .anthropic,
            prepared: PreparedOAuthLogin(
                providerFamily: .anthropic,
                authURL: AnthropicAuthService.defaultClaudeAIAuthorizeURL,
                redirectURI: "http://localhost:1455/callback"
            ),
            callbackURL: "http://localhost:1455/callback?code=test-code&state=test-state",
            expectedAuthMode: model.oauthExpectedAuthMode(for: .anthropic),
            baselineUpdatedAtByAccountKey: [:]
        )

        await model.completeOAuth()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.providerFamily, .anthropic)
        XCTAssertEqual(snapshot.callbackURL, "http://localhost:1455/callback?code=test-code&state=test-state")
        XCTAssertNil(model.oauthDraft)
        XCTAssertEqual(model.accounts, [importedAccount])
        XCTAssertEqual(model.status?.activeAccountLabel, importedAccount.label)
    }

    @MainActor
    func testCompleteOAuthFailureKeepsDraftForManualRetry() async {
        let importedAccount = Self.makeAccount(
            id: "anthropic-account",
            label: "Claude OAuth",
            accountID: "acct-anthropic",
            authMode: .anthropicSubscriptionOAuth
        )
        let sequence = OAuthCallbackCompletionSequence(
            results: [
                .failure(ProxyError.message("Anthropic OAuth token 交换失败: 400 Bad authorization code")),
                .success(importedAccount),
            ]
        )
        let admin = AdminAPIClient(
            accountsHandler: { [importedAccount] in [importedAccount] },
            completeOAuthCallbackHandler: { _, _ in
                try await sequence.next()
            },
            getStatusHandler: {
                ProxyStatus(
                    running: true,
                    publicBaseURL: "http://127.0.0.1:8787/v1",
                    anthropicBaseURL: "http://127.0.0.1:8787",
                    geminiBaseURL: "http://127.0.0.1:8787",
                    adminBaseURL: "http://127.0.0.1:8788/admin",
                    apiKey: "sk-local",
                    activeAccountKey: importedAccount.accountKey,
                    activeAccountID: importedAccount.accountID,
                    activeAccountLabel: importedAccount.label,
                    lastError: nil,
                    daemonVersion: "1.0.0 Beta版"
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.oauthDraft = DesktopAppModel.OAuthDraft(
            providerFamily: .anthropic,
            prepared: PreparedOAuthLogin(
                providerFamily: .anthropic,
                authURL: AnthropicAuthService.defaultClaudeAIAuthorizeURL,
                redirectURI: "http://localhost:1455/callback"
            ),
            callbackURL: "http://localhost:1455/callback?code=retry-success&state=test-state",
            expectedAuthMode: model.oauthExpectedAuthMode(for: .anthropic),
            baselineUpdatedAtByAccountKey: [:]
        )

        await model.completeOAuth()
        XCTAssertNotNil(model.oauthDraft)

        await model.completeOAuth()
        XCTAssertNil(model.oauthDraft)
        XCTAssertEqual(model.accounts, [importedAccount])
        XCTAssertEqual(model.status?.activeAccountLabel, importedAccount.label)
    }

    @MainActor
    func testObservedImportedOAuthAccountIgnoresSameProviderAPIKeyAccounts() {
        let model = DesktopAppModel()
        let existingAPIKeyAccount = Self.makeAccount(
            id: "openai-api-existing",
            label: "OpenAI API",
            accountID: "acct-openai-api",
            accountKey: "acct-openai-api",
            updatedAt: 100,
            authMode: .openAIAPIKey
        )
        let refreshedAPIKeyAccount = Self.makeAccount(
            id: "openai-api-existing",
            label: "OpenAI API",
            accountID: "acct-openai-api",
            accountKey: "acct-openai-api",
            updatedAt: 220,
            authMode: .openAIAPIKey
        )

        let observed = model.observedImportedOAuthAccount(
            in: [refreshedAPIKeyAccount],
            expectedAuthMode: model.oauthExpectedAuthMode(for: .openAI),
            baselineUpdatedAtByAccountKey: model.oauthBaselineUpdatedAtByAccountKey(from: [existingAPIKeyAccount])
        )

        XCTAssertNil(observed)
    }

    @MainActor
    func testObservedImportedOAuthAccountReturnsNewOAuthAccount() {
        let model = DesktopAppModel()
        let existingAPIKeyAccount = Self.makeAccount(
            id: "openai-api-existing",
            label: "OpenAI API",
            accountID: "acct-openai-api",
            accountKey: "acct-openai-api",
            updatedAt: 100,
            authMode: .openAIAPIKey
        )
        let importedOAuthAccount = Self.makeAccount(
            id: "openai-oauth-new",
            label: "OpenAI OAuth",
            accountID: "acct-openai-oauth",
            accountKey: "acct-openai-oauth",
            updatedAt: 210,
            authMode: .chatGPT
        )

        let observed = model.observedImportedOAuthAccount(
            in: [existingAPIKeyAccount, importedOAuthAccount],
            expectedAuthMode: model.oauthExpectedAuthMode(for: .openAI),
            baselineUpdatedAtByAccountKey: model.oauthBaselineUpdatedAtByAccountKey(from: [existingAPIKeyAccount])
        )

        XCTAssertEqual(observed, importedOAuthAccount)
    }

    @MainActor
    func testObservedImportedOAuthAccountReturnsUpdatedExistingOAuthAccount() {
        let model = DesktopAppModel()
        let existingOAuthAccount = Self.makeAccount(
            id: "openai-oauth-existing",
            label: "OpenAI OAuth",
            accountID: "acct-openai-oauth",
            accountKey: "acct-openai-oauth",
            updatedAt: 100,
            authMode: .chatGPT
        )
        let unrelatedAPIKeyAccount = Self.makeAccount(
            id: "openai-api-existing",
            label: "OpenAI API",
            accountID: "acct-openai-api",
            accountKey: "acct-openai-api",
            updatedAt: 240,
            authMode: .openAIAPIKey
        )
        let reloggedOAuthAccount = Self.makeAccount(
            id: "openai-oauth-existing",
            label: "OpenAI OAuth",
            accountID: "acct-openai-oauth",
            accountKey: "acct-openai-oauth",
            updatedAt: 220,
            authMode: .chatGPT
        )

        let observed = model.observedImportedOAuthAccount(
            in: [unrelatedAPIKeyAccount, reloggedOAuthAccount],
            expectedAuthMode: model.oauthExpectedAuthMode(for: .openAI),
            baselineUpdatedAtByAccountKey: model.oauthBaselineUpdatedAtByAccountKey(from: [existingOAuthAccount])
        )

        XCTAssertEqual(observed, reloggedOAuthAccount)
    }

    @MainActor
    func testRequestLogsRefreshUsesSinglePageRequestAndPageFilters() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: "gpt-5.4", apiKey: "sk-history-1")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-history-1"],
                    availableModels: ["gpt-5.4"]
                )
            },
            requestLogFiltersHandler: { query in
                await probe.recordFilterRequest(query)
                return RequestLogFilterOptions(availableAPIKeys: ["unexpected"], availableModels: ["unexpected"])
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.scheduleRequestLogsRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4")

        XCTAssertEqual(model.requestLogPage.totalCount, 1)
        XCTAssertEqual(model.requestLogPage.entries.first?.apiKey, "sk-history-1")
        XCTAssertEqual(model.requestLogFilterOptions.availableAPIKeys, ["sk-history-1"])
        XCTAssertEqual(model.requestLogFilterOptions.availableModels, ["gpt-5.4"])

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.count, 1)
        XCTAssertEqual(snapshot.requestQueries.first?.page, 1)
        XCTAssertEqual(snapshot.requestQueries.first?.pageSize, 50)
        XCTAssertEqual(snapshot.requestQueries.first?.sortBy, .time)
        XCTAssertEqual(snapshot.requestQueries.first?.sortDirection, .descending)
        XCTAssertNil(snapshot.requestQueries.first?.clientSource)
        XCTAssertTrue(snapshot.filterQueries.isEmpty)
    }

    @MainActor
    func testOpenRequestLogsWindowWhenClosedResetsToFreshDefaultsAndQueriesOnce() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: "gpt-5.4", apiKey: "sk-default")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-default"],
                    availableModels: ["gpt-5.4"]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let openDate = Date(timeIntervalSince1970: 1_776_200_000)
        let staleState = RequestLogFilterState(
            timePreset: .custom,
            fromDate: oldDate.addingTimeInterval(-1_800),
            toDate: oldDate,
            selectedAPIKey: "sk-stale",
            selectedAccountKey: "stale|account",
            selectedModel: "stale-model",
            sortBy: .latency,
            sortDirection: .ascending,
            page: 7,
            pageSize: 25
        )

        model.requestLogsNowProvider = { openDate }
        model.requestLogsDraftFilterState = staleState
        model.requestLogsAppliedFilterState = staleState
        model.requestLogPage = RequestLogPage(
            entries: [Self.makeRequestLogEntry(id: 77, model: "stale-model", apiKey: "sk-stale")],
            totalCount: 9,
            page: 7,
            pageSize: 25,
            availableAPIKeys: ["sk-stale"],
            availableModels: ["stale-model"]
        )
        model.requestLogFilterOptions = RequestLogFilterOptions(
            availableAPIKeys: ["sk-stale"],
            availableModels: ["stale-model"]
        )
        model.requestLogsLastRefreshedAt = oldDate

        model.openRequestLogsWindow()
        defer {
            model.dismissRequestLogsWindow()
            model.requestLogsWindowController = nil
        }
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        let expectedDefault = RequestLogFilterState.defaultState(now: openDate)
        XCTAssertEqual(model.requestLogsDraftFilterState, expectedDefault)
        XCTAssertEqual(model.requestLogsAppliedFilterState, expectedDefault)
        XCTAssertEqual(model.requestLogFilterOptions.availableAPIKeys, ["sk-default"])
        XCTAssertEqual(model.requestLogFilterOptions.availableModels, ["gpt-5.4"])
        XCTAssertNotNil(model.requestLogsLastRefreshedAt)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.count, 1)
        XCTAssertEqual(snapshot.requestQueries.first, expectedDefault.query)
    }

    @MainActor
    func testOpenRequestLogsWindowWhenAlreadyPresentedKeepsDraftAndDoesNotRequery() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: "gpt-5.4", apiKey: "sk-default")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-default"],
                    availableModels: ["gpt-5.4"]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        let firstOpenDate = Date(timeIntervalSince1970: 1_776_200_000)
        let secondOpenDate = Date(timeIntervalSince1970: 1_776_207_200)

        model.requestLogsNowProvider = { firstOpenDate }
        model.openRequestLogsWindow()
        defer {
            model.dismissRequestLogsWindow()
            model.requestLogsWindowController = nil
        }
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        let editedState = RequestLogFilterState(
            timePreset: .custom,
            fromDate: secondOpenDate.addingTimeInterval(-3_600),
            toDate: secondOpenDate,
            selectedAPIKey: "sk-edited",
            selectedAccountKey: "edited|account",
            selectedModel: "edited-model",
            sortBy: .latency,
            sortDirection: .ascending,
            page: 3,
            pageSize: 25
        )
        model.requestLogsNowProvider = { secondOpenDate }
        model.requestLogsDraftFilterState = editedState

        model.openRequestLogsWindow()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.requestLogsDraftFilterState, editedState)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.count, 1)
    }

    @MainActor
    func testOpenRequestLogsFromMenuOpensRequestLogsWindowWithoutChangingInterfaceMode() async {
        let (preferencesStore, directory) = try! Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: "gpt-5.4", apiKey: "sk-default")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-default"],
                    availableModels: ["gpt-5.4"]
                )
            }
        )
        let model = DesktopAppModel(admin: admin, preferencesStore: preferencesStore)

        XCTAssertEqual(model.preferences.interfaceMode, .minimal)

        model.openRequestLogsFromMenu()
        defer {
            model.dismissRequestLogsWindow()
            model.requestLogsWindowController = nil
        }
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        XCTAssertEqual(model.preferences.interfaceMode, .minimal)
        XCTAssertTrue(model.isRequestLogsPresented)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.count, 1)
    }

    @MainActor
    func testDismissRequestLogsWindowCleanupAllowsNextOpenToResetDefaults() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                let resolvedModel = query.model ?? "gpt-5.4"
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: Int64(query.page), model: resolvedModel, apiKey: "sk-\(resolvedModel)")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-\(resolvedModel)"],
                    availableModels: [resolvedModel]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        let firstOpenDate = Date(timeIntervalSince1970: 1_776_200_000)
        let secondOpenDate = Date(timeIntervalSince1970: 1_776_214_400)

        model.requestLogsNowProvider = { firstOpenDate }
        model.openRequestLogsWindow()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        model.setRequestLogsModel("fast-model")
        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRecordedRequestCount(on: probe, count: 2)
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "fast-model", expectedPage: 1)

        model.dismissRequestLogsWindow()
        await Self.waitForCondition {
            model.isRequestLogsPresented == false
                && model.requestLogsIsRefreshing == false
                && model.requestLogsRefreshTask == nil
        }

        model.requestLogsNowProvider = { secondOpenDate }
        model.openRequestLogsWindow()
        defer {
            model.dismissRequestLogsWindow()
            model.requestLogsWindowController = nil
        }
        await Self.waitForRecordedRequestCount(on: probe, count: 3)
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        let expectedDefault = RequestLogFilterState.defaultState(now: secondOpenDate)
        XCTAssertEqual(model.requestLogsDraftFilterState, expectedDefault)
        XCTAssertEqual(model.requestLogsAppliedFilterState, expectedDefault)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.last, expectedDefault.query)
    }

    @MainActor
    func testTitlebarCloseCleanupAllowsNextOpenToResetDefaults() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: "gpt-5.4", apiKey: "sk-default")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-default"],
                    availableModels: ["gpt-5.4"]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        let reopenDate = Date(timeIntervalSince1970: 1_776_221_600)
        let controller = RequestLogsWindowController(model: model)

        model.requestLogsWindowController = controller
        model.isRequestLogsPresented = true
        model.requestLogsRefreshTask = Task {
            try? await Task.sleep(for: .seconds(30))
        }
        model.requestLogsIsRefreshing = true
        model.requestLogsDraftFilterState = RequestLogFilterState(
            timePreset: .custom,
            fromDate: Date(timeIntervalSince1970: 1_700_000_000),
            toDate: Date(timeIntervalSince1970: 1_700_003_600),
            selectedAPIKey: "sk-stale",
            selectedAccountKey: "stale|account",
            selectedModel: "stale-model",
            sortBy: .latency,
            sortDirection: .ascending,
            page: 9,
            pageSize: 25
        )

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertFalse(model.isRequestLogsPresented)
        XCTAssertFalse(model.requestLogsIsRefreshing)
        XCTAssertNil(model.requestLogsRefreshTask)

        model.requestLogsNowProvider = { reopenDate }
        model.openRequestLogsWindow()
        defer {
            model.dismissRequestLogsWindow()
            model.requestLogsWindowController = nil
        }
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        let expectedDefault = RequestLogFilterState.defaultState(now: reopenDate)
        XCTAssertEqual(model.requestLogsDraftFilterState, expectedDefault)
        XCTAssertEqual(model.requestLogsAppliedFilterState, expectedDefault)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.last, expectedDefault.query)
    }

    @MainActor
    func testRequestLogsSortChangesApplyImmediatelyAndResetToFirstPage() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: "gpt-5.4", apiKey: "sk-history")],
                    totalCount: 120,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-history"],
                    availableModels: ["gpt-5.4"]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)
        model.nextRequestLogsPage()
        await Self.waitForRecordedRequestCount(on: probe, count: 2)
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 2)
        XCTAssertEqual(model.requestLogsAppliedFilterState.page, 2)

        model.setRequestLogsSortField(.latency)
        await Self.waitForRecordedRequestCount(on: probe, count: 3)
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        XCTAssertFalse(model.requestLogsHasPendingFilterChanges)
        XCTAssertEqual(model.requestLogsDraftFilterState.sortBy, .latency)
        XCTAssertEqual(model.requestLogsDraftFilterState.sortDirection, .descending)
        XCTAssertEqual(model.requestLogsDraftFilterState.page, 1)
        XCTAssertEqual(model.requestLogsAppliedFilterState.sortBy, .latency)
        XCTAssertEqual(model.requestLogsAppliedFilterState.sortDirection, .descending)
        XCTAssertEqual(model.requestLogsAppliedFilterState.page, 1)

        model.setRequestLogsSortDirection(.ascending)
        await Self.waitForRecordedRequestCount(on: probe, count: 4)
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        XCTAssertFalse(model.requestLogsHasPendingFilterChanges)
        XCTAssertEqual(model.requestLogsDraftFilterState.sortBy, .latency)
        XCTAssertEqual(model.requestLogsDraftFilterState.sortDirection, .ascending)
        XCTAssertEqual(model.requestLogsAppliedFilterState.sortBy, .latency)
        XCTAssertEqual(model.requestLogsAppliedFilterState.sortDirection, .ascending)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.map(\.page), [1, 2, 1, 1])
        XCTAssertEqual(snapshot.requestQueries.map(\.sortBy), [.time, .time, .latency, .latency])
        XCTAssertEqual(snapshot.requestQueries.map(\.sortDirection), [.descending, .descending, .descending, .ascending])
    }

    @MainActor
    func testRequestLogsSortAppliesWithoutApplyingPendingFilters() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                let resolvedModel = query.model ?? "all-models"
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: resolvedModel, apiKey: "sk-\(resolvedModel)")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-\(resolvedModel)"],
                    availableModels: [resolvedModel]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.setRequestLogsModel("slow-model")
        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "slow-model", expectedPage: 1)

        model.setRequestLogsModel("fast-model")
        XCTAssertTrue(model.requestLogsHasPendingFilterChanges)

        model.setRequestLogsSortField(.latency)
        await Self.waitForRecordedRequestCount(on: probe, count: 2)
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "slow-model", expectedPage: 1)

        XCTAssertTrue(model.requestLogsHasPendingFilterChanges)
        XCTAssertEqual(model.requestLogsAppliedFilterState.selectedModel, "slow-model")
        XCTAssertEqual(model.requestLogsDraftFilterState.selectedModel, "fast-model")
        XCTAssertEqual(model.requestLogsAppliedFilterState.sortBy, .latency)
        XCTAssertEqual(model.requestLogsDraftFilterState.sortBy, .latency)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.map { $0.model ?? "" }, ["slow-model", "slow-model"])
        XCTAssertEqual(snapshot.requestQueries.map(\.sortBy), [.time, .latency])
    }

    @MainActor
    func testRequestLogsSortSameValueDoesNotRefresh() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: "gpt-5.4", apiKey: "sk-history")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-history"],
                    availableModels: ["gpt-5.4"]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "gpt-5.4", expectedPage: 1)

        model.setRequestLogsSortField(.time)
        model.setRequestLogsSortDirection(.descending)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.count, 1)
    }

    func testRequestLogsViewKeepsSingleFilterQueryButton() throws {
        let source = try Self.repoFileText("Sources/CodexProxyDesktop/Views/RequestLogsView.swift")
        let queryButtonCount = source.components(separatedBy: "actionQueryRequestLogs").count - 1
        XCTAssertEqual(queryButtonCount, 1)

        let toolbarStart = try XCTUnwrap(source.range(of: "private var tableToolbarActions: some View {"))
        let toolbarEnd = try XCTUnwrap(source[toolbarStart.upperBound...].range(of: "\n    }\n\n    @ViewBuilder\n    private func tableFooter"))
        let toolbarBody = String(source[toolbarStart.upperBound..<toolbarEnd.lowerBound])
        XCTAssertFalse(toolbarBody.contains("actionQueryRequestLogs"))
        XCTAssertTrue(toolbarBody.contains("actionExportRequestLogs"))
    }

    @MainActor
    func testRequestLogsDraftChangesDoNotAutoRefreshAndExposePendingState() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                let resolvedModel = query.model ?? "all-models"
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: resolvedModel, apiKey: "sk-\(resolvedModel)")],
                    totalCount: 1,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-\(resolvedModel)"],
                    availableModels: [resolvedModel]
                )
            },
            requestLogFiltersHandler: { query in
                await probe.recordFilterRequest(query)
                return RequestLogFilterOptions()
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "all-models")
        XCTAssertFalse(model.requestLogsHasPendingFilterChanges)

        model.setRequestLogsModel("fast-model")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(model.requestLogsHasPendingFilterChanges)
        XCTAssertEqual(model.requestLogsDraftFilterState.selectedModel, "fast-model")
        XCTAssertEqual(model.requestLogsAppliedFilterState.selectedModel, "")

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.map { $0.model ?? "" }, [""])
        XCTAssertTrue(snapshot.filterQueries.isEmpty)
    }

    @MainActor
    func testRequestLogsQueryAppliesDraftFiltersAndResetsToFirstPage() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                let resolvedModel = query.model ?? "all-models"
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: 1, model: resolvedModel, apiKey: "sk-\(resolvedModel)")],
                    totalCount: 96,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-\(resolvedModel)"],
                    availableModels: [resolvedModel]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.requestLogsDraftFilterState.page = 7
        model.setRequestLogsModel("fast-model")
        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "fast-model", expectedPage: 1)

        XCTAssertFalse(model.requestLogsHasPendingFilterChanges)
        XCTAssertEqual(model.requestLogsAppliedFilterState.selectedModel, "fast-model")
        XCTAssertEqual(model.requestLogsAppliedFilterState.page, 1)
        XCTAssertEqual(model.requestLogPage.entries.first?.model, "fast-model")

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.count, 1)
        XCTAssertEqual(snapshot.requestQueries.first?.model, "fast-model")
        XCTAssertEqual(snapshot.requestQueries.first?.page, 1)
    }

    @MainActor
    func testRequestLogsAccountFilterStaysAppliedAcrossRefreshAndPaginationWhileDraftChangesArePending() async throws {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                let resolvedAccountKey = query.accountKey ?? "all-accounts"
                let resolvedLabel = resolvedAccountKey == "key-account-1" ? "Shared Label" : "Other Label"
                return RequestLogPage(
                    entries: [
                        Self.makeRequestLogEntry(
                            id: Int64(query.page),
                            model: "gpt-5.4",
                            apiKey: "sk-history",
                            accountKey: resolvedAccountKey,
                            accountLabel: resolvedLabel
                        )
                    ],
                    totalCount: 120,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-history"],
                    availableModels: ["gpt-5.4"]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)
        model.accounts = [
            Self.makeAccount(id: "account-1", label: "Shared Label", accountID: "account-1", updatedAt: 200),
            Self.makeAccount(id: "account-2", label: "Other Label", accountID: "account-2", updatedAt: 100),
        ]
        let firstAccountKey = try XCTUnwrap(model.accounts.first(where: { $0.id == "account-1" })?.accountKey)
        let secondAccountKey = try XCTUnwrap(model.accounts.first(where: { $0.id == "account-2" })?.accountKey)

        model.setRequestLogsAccountKey(firstAccountKey)
        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForCondition {
            model.requestLogsIsRefreshing == false
                && model.requestLogPage.page == 1
                && model.requestLogPage.entries.first?.accountKey == firstAccountKey
        }
        XCTAssertFalse(model.requestLogsHasPendingFilterChanges)

        model.setRequestLogsAccountKey(secondAccountKey)
        XCTAssertTrue(model.requestLogsHasPendingFilterChanges)

        model.scheduleRequestLogsRefresh()
        await Self.waitForRecordedRequestCount(on: probe, count: 2)
        await Self.waitForCondition {
            model.requestLogsIsRefreshing == false
                && model.requestLogPage.page == 1
                && model.requestLogPage.entries.first?.accountKey == firstAccountKey
        }

        model.nextRequestLogsPage()
        await Self.waitForRecordedRequestCount(on: probe, count: 3)
        await Self.waitForCondition {
            model.requestLogsIsRefreshing == false
                && model.requestLogPage.page == 2
                && model.requestLogPage.entries.first?.accountKey == firstAccountKey
        }

        XCTAssertEqual(model.requestLogsAppliedFilterState.selectedAccountKey, firstAccountKey)
        XCTAssertEqual(model.requestLogsDraftFilterState.selectedAccountKey, secondAccountKey)
        XCTAssertTrue(model.requestLogsHasPendingFilterChanges)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.map { $0.accountKey ?? "" }, [firstAccountKey, firstAccountKey, firstAccountKey])
        XCTAssertEqual(snapshot.requestQueries.map(\.page), [1, 1, 2])
    }

    @MainActor
    func testRequestLogsRefreshUsesAppliedFiltersWhenDraftChangesRemainPending() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                let resolvedModel = query.model ?? "all-models"
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: query.page == 1 ? 1 : 2, model: resolvedModel, apiKey: "sk-\(resolvedModel)")],
                    totalCount: 96,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-\(resolvedModel)"],
                    availableModels: [resolvedModel]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.setRequestLogsModel("slow-model")
        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "slow-model", expectedPage: 1)

        model.setRequestLogsModel("fast-model")
        XCTAssertTrue(model.requestLogsHasPendingFilterChanges)

        model.scheduleRequestLogsRefresh()
        await Self.waitForRecordedRequestCount(on: probe, count: 2)
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "slow-model", expectedPage: 1)

        XCTAssertEqual(model.requestLogPage.entries.first?.model, "slow-model")
        XCTAssertEqual(model.requestLogsAppliedFilterState.selectedModel, "slow-model")
        XCTAssertEqual(model.requestLogsDraftFilterState.selectedModel, "fast-model")

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.map { $0.model ?? "" }, ["slow-model", "slow-model"])
    }

    @MainActor
    func testRequestLogsPaginationKeepsAppliedFiltersWhileDraftChangesArePending() async {
        let probe = RequestLogsProbe()
        let admin = AdminAPIClient(
            requestLogsHandler: { query in
                await probe.recordRequest(query)
                let resolvedModel = query.model ?? "all-models"
                return RequestLogPage(
                    entries: [Self.makeRequestLogEntry(id: Int64(query.page), model: resolvedModel, apiKey: "sk-\(resolvedModel)")],
                    totalCount: 120,
                    page: query.page,
                    pageSize: query.pageSize,
                    availableAPIKeys: ["sk-\(resolvedModel)"],
                    availableModels: [resolvedModel]
                )
            }
        )
        let model = DesktopAppModel(admin: admin)

        model.setRequestLogsModel("slow-model")
        model.applyRequestLogsFiltersAndRefresh()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "slow-model", expectedPage: 1)
        XCTAssertFalse(model.requestLogsHasPendingFilterChanges)

        model.setRequestLogsModel("fast-model")
        model.nextRequestLogsPage()
        await Self.waitForRequestLogsRefresh(on: model, expectedModel: "slow-model", expectedPage: 2)

        XCTAssertEqual(model.requestLogsAppliedFilterState.page, 2)
        XCTAssertEqual(model.requestLogsAppliedFilterState.selectedModel, "slow-model")
        XCTAssertTrue(model.requestLogsHasPendingFilterChanges)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requestQueries.count, 2)
        XCTAssertEqual(snapshot.requestQueries.first?.model, "slow-model")
        XCTAssertEqual(snapshot.requestQueries.first?.page, 1)
        XCTAssertEqual(snapshot.requestQueries.last?.model, "slow-model")
        XCTAssertEqual(snapshot.requestQueries.last?.page, 2)
    }

    @MainActor
    func testFixedDateTimeFieldLogicAcceptsValidInput() throws {
        let currentValue = try XCTUnwrap(DesktopDateTimeFormat.date(from: "2026-04-13 11:22:33"))

        let result = FixedDateTimeFieldLogic.commit(
            draft: "2026-04-13 12:34:56",
            currentValue: currentValue
        )

        XCTAssertEqual(result.text, "2026-04-13 12:34:56")
        XCTAssertEqual(result.acceptedDate, DesktopDateTimeFormat.date(from: "2026-04-13 12:34:56"))
    }

    @MainActor
    func testFixedDateTimeFieldLogicRejectsInvalidInputAndReverts() throws {
        let currentValue = try XCTUnwrap(DesktopDateTimeFormat.date(from: "2026-04-13 11:22:33"))

        let result = FixedDateTimeFieldLogic.commit(
            draft: "2026/04/13 12:34",
            currentValue: currentValue
        )

        XCTAssertEqual(result.text, "2026-04-13 11:22:33")
        XCTAssertNil(result.acceptedDate)
    }

    @MainActor
    func testFixedDateTimeFieldLogicDoesNotCommitWhenDisplayedTextIsUnchanged() throws {
        let currentValue = Date(timeIntervalSince1970: 1_776_052_953.75)

        let result = FixedDateTimeFieldLogic.commit(
            draft: FixedDateTimeFieldLogic.displayText(for: currentValue),
            currentValue: currentValue
        )

        XCTAssertEqual(result.text, FixedDateTimeFieldLogic.displayText(for: currentValue))
        XCTAssertNil(result.acceptedDate)
    }

    func testAnthropicProxyTestDraftBuildsMessagesPayloadWithTools() throws {
        let draft = ProxyTestDraft(
            endpoint: .anthropicMessages,
            model: "claude-sonnet-4-5",
            systemPrompt: "You are helpful",
            userPrompt: "Say hello",
            toolsJSON: #"[{"name":"run_command","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}}]"#,
            stream: true,
            endpointURL: "http://127.0.0.1:8787",
            apiKey: "proxy-key"
        )

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.requestData()) as? [String: Any])

        XCTAssertEqual(payload["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(payload["system"] as? String, "You are helpful")
        XCTAssertEqual(payload["stream"] as? Bool, true)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "Say hello")
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "run_command")
    }

    func testGeminiProxyTestDraftBuildsGenerateContentPayloadWithTools() throws {
        let draft = ProxyTestDraft(
            endpoint: .geminiGenerateContent,
            model: "gemini-2.5-pro",
            systemPrompt: "You are helpful",
            userPrompt: "Say hello",
            toolsJSON: #"[{"functionDeclarations":[{"name":"run_command","description":"Execute a command","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}]}]"#,
            stream: true,
            endpointURL: "http://127.0.0.1:8787",
            apiKey: "proxy-key"
        )

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.requestData()) as? [String: Any])

        XCTAssertNil(payload["model"])
        let contents = try XCTUnwrap(payload["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "Say hello")
        let systemInstruction = try XCTUnwrap(payload["systemInstruction"] as? [String: Any])
        let systemParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
        XCTAssertEqual(systemParts.first?["text"] as? String, "You are helpful")
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.first?["name"] as? String, "run_command")
    }

    func testProxyTestModelCatalogSeparatesFamilies() {
        let catalog = ProxyTestModelCatalog.defaultCatalog
        let gptModels = ProxyTestEndpoint.chatCompletions.availableModels(in: catalog)
        let anthropicModels = ProxyTestEndpoint.anthropicMessages.availableModels(in: catalog)
        let geminiModels = ProxyTestEndpoint.geminiGenerateContent.availableModels(in: catalog)

        XCTAssertEqual(gptModels, ProxyTranscoder.supportedModels)
        XCTAssertTrue(anthropicModels.contains("claude-sonnet-4-6"))
        XCTAssertTrue(anthropicModels.contains("claude-opus-4-6"))
        XCTAssertTrue(anthropicModels.contains("claude-3-5-haiku-latest"))
        XCTAssertFalse(anthropicModels.contains("gpt-5.4"))
        XCTAssertTrue(geminiModels.contains("gemini-2.5-flash"))
        XCTAssertTrue(geminiModels.contains("gemini-2.5-pro"))
        XCTAssertFalse(geminiModels.contains("claude-sonnet-4-6"))
        XCTAssertTrue(ProxyTestEndpoint.chatCompletions.supportsCustomModelEntry)
        XCTAssertTrue(ProxyTestEndpoint.responses.supportsCustomModelEntry)
        XCTAssertTrue(ProxyTestEndpoint.anthropicMessages.supportsCustomModelEntry)
        XCTAssertTrue(ProxyTestEndpoint.geminiGenerateContent.supportsCustomModelEntry)
        XCTAssertTrue(ProxyTestEndpoint.anthropicMessages.prefersAnthropicRootBaseURL)
        XCTAssertTrue(ProxyTestEndpoint.geminiGenerateContent.prefersGeminiRootBaseURL)
    }

    func testAnthropicProxyTestDraftPreservesCustomModelEntry() throws {
        let draft = ProxyTestDraft(
            endpoint: .anthropicMessages,
            model: "claude-opus-4-6",
            systemPrompt: "",
            userPrompt: "Say hello",
            toolsJSON: "",
            stream: false,
            endpointURL: "http://127.0.0.1:8787",
            apiKey: "proxy-key"
        )

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.requestData()) as? [String: Any])

        XCTAssertEqual(payload["model"] as? String, "claude-opus-4-6")
    }

    func testProxyTestRequestPayloadOmitsSelectedAccountKey() throws {
        let draft = ProxyTestDraft(
            endpoint: .responses,
            model: "gpt-5.4",
            systemPrompt: "You are helpful",
            userPrompt: "Say hello",
            toolsJSON: "",
            stream: false,
            endpointURL: "http://127.0.0.1:8787",
            apiKey: "proxy-key",
            selectedAccountKey: "key-account-1"
        )

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.requestData()) as? [String: Any])

        XCTAssertEqual(payload["model"] as? String, "gpt-5.4")
        XCTAssertEqual(payload["input"] as? String, "Say hello")
        XCTAssertNil(payload["selectedAccountKey"])
        XCTAssertNil(payload["x-codex-test-account-key"])
        XCTAssertFalse(draft.requestPreview().contains("key-account-1"))
    }

    func testProxyPublicAPIClientExecuteNonStreamAddsProxyTestConsoleHeader() async throws {
        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }

        let capture = CapturedURLRequest()
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.record(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"id":"resp_test","object":"response","status":"completed","output":[]}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let client = ProxyPublicAPIClient(session: URLSession(configuration: configuration))
        let draft = ProxyTestDraft(
            endpoint: .responses,
            model: "qwen3.6-plus",
            systemPrompt: "You are helpful",
            userPrompt: "Say hello",
            toolsJSON: "",
            stream: false,
            endpointURL: "http://127.0.0.1:8787",
            apiKey: "proxy-key",
            selectedAccountKey: "key-account-1"
        )

        _ = try await client.executeNonStream(draft: draft)

        let request = try XCTUnwrap(capture.request())
        XCTAssertEqual(request.value(forHTTPHeaderField: ProxyHeaderName.proxyTestConsole), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: ProxyHeaderName.testAccountKey), "key-account-1")
        XCTAssertFalse(draft.requestPreview().contains(ProxyHeaderName.proxyTestConsole))
    }

    func testProxyPublicAPIClientHealthUsesProxyRootWhenOpenAIBaseURLIncludesV1() async throws {
        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }

        let capture = CapturedURLRequest()
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.record(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"status":"ok","service":"codex-proxyd"}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let client = ProxyPublicAPIClient(session: URLSession(configuration: configuration))

        try await client.health(baseURL: "http://127.0.0.1:8787/v1")

        let request = try XCTUnwrap(capture.request())
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testProxyPublicAPIClientOpenAIRequestsUseBaseURLAsAPIPrefix() async throws {
        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }

        let capture = CapturedURLRequest()
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.record(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"id":"resp_test","object":"response","status":"completed","output":[]}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let client = ProxyPublicAPIClient(session: URLSession(configuration: configuration))
        let draft = ProxyTestDraft(
            endpoint: .responses,
            model: "gpt-5.4",
            userPrompt: "Say hello",
            endpointURL: "http://127.0.0.1:8787/v1",
            apiKey: "proxy-key"
        )

        _ = try await client.executeNonStream(draft: draft)

        let request = try XCTUnwrap(capture.request())
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer proxy-key")
    }

    func testProxyPublicAPIClientModelsUsesBaseURLAsAPIPrefix() async throws {
        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }

        let capture = CapturedURLRequest()
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            capture.record(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"object":"list","data":[{"id":"gpt-5.4"}]}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let client = ProxyPublicAPIClient(session: URLSession(configuration: configuration))

        let models = try await client.models(baseURL: "http://127.0.0.1:8787/v1", apiKey: "proxy-key")

        let request = try XCTUnwrap(capture.request())
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer proxy-key")
        XCTAssertEqual(models, ["gpt-5.4"])
    }

    @MainActor
    func testProxyTestEndpointSwitchResetsCrossFamilyModel() {
        let model = DesktopAppModel()
        model.proxyTestModelCatalog = .defaultCatalog
        model.proxyTestDraft.endpoint = .chatCompletions
        model.proxyTestDraft.model = "claude-sonnet-4-6"

        model.updateProxyTestEndpoint(.responses)
        XCTAssertEqual(model.proxyTestDraft.model, ProxyTestModelCatalog.defaultCatalog.responses.defaultModel)

        model.proxyTestDraft.model = "gpt-5.4"
        model.updateProxyTestEndpoint(.anthropicMessages)
        XCTAssertEqual(model.proxyTestDraft.model, ProxyTestModelCatalog.defaultCatalog.anthropicMessages.defaultModel)

        model.proxyTestDraft.model = "claude-sonnet-4-6"
        model.updateProxyTestEndpoint(.geminiGenerateContent)
        XCTAssertEqual(model.proxyTestDraft.model, ProxyTestModelCatalog.defaultCatalog.geminiGenerateContent.defaultModel)
    }

    @MainActor
    func testProxyTestCrossFamilyModelShowsWarningButKeepsPromptSendable() {
        let model = DesktopAppModel()
        let draft = ProxyTestDraft(
            endpoint: .anthropicMessages,
            model: "gpt-5.4",
            systemPrompt: "",
            userPrompt: "Say hello",
            toolsJSON: "",
            stream: false,
            endpointURL: "http://127.0.0.1:8787",
            apiKey: "proxy-key"
        )

        let warning = model.proxyTestModelFamilyWarning(for: draft)

        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.detail.contains("gpt-5.4") == true)
        XCTAssertTrue(draft.hasPrompt)
    }

    @MainActor
    func testProxyTestSelectedAnthropicAccountUsesMatchingAnthropicProxyKey() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "anthropic-secondary", label: "Anthropic Secondary", key: "sk-anthropic-secondary", dataSource: .anthropic, enabled: true, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestSelectedDataSource, .anthropic)
        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-secondary")
    }

    @MainActor
    func testProxyTestSelectedOpenAIAccountSwitchesAwayFromAnthropicPrimaryAndClearingRestoresPrimary() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "anthropic-primary", label: "Anthropic Primary", key: "sk-anthropic-primary", dataSource: .anthropic, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "openai-secondary", label: "OpenAI Secondary", key: "sk-openai-secondary", dataSource: .openAI, enabled: true, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "anthropic-primary"
        model.accounts = [
            Self.makeAccount(
                id: "openai-account",
                label: "OpenAI API Key",
                accountID: "openai-account",
                authMode: .openAIAPIKey
            )
        ]

        model.setProxyTestSelectedAccountKey("key-openai-account")
        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-openai-secondary")

        model.setProxyTestSelectedAccountKey("")
        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-primary")
    }

    @MainActor
    func testProxyTestPinnedAnthropicOAuthAccountFallsBackToOpenAIProxyKeyWhenNoAnthropicKeyExists() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "openai-primary",
                label: "OpenAI Primary",
                key: "sk-openai-primary",
                dataSource: .openAI,
                allowedAccountKeys: ["key-anthropic-account"],
                enabled: true,
                createdAt: 1
            )
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-openai-primary")
        XCTAssertTrue(model.proxyTestCanSend)
        XCTAssertNil(model.proxyTestSelectedAccountIssueText())
    }

    @MainActor
    func testProxyTestPinnedAnthropicAPIKeyAccountSkipsRestrictedAnthropicKeyForLaterCompatibleOne() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "anthropic-restricted",
                label: "Anthropic Restricted",
                key: "sk-anthropic-restricted",
                dataSource: .anthropic,
                allowedAccountKeys: ["key-other-account"],
                enabled: true,
                createdAt: 1
            ),
            ProxyAPIKeyRecord(
                id: "anthropic-access",
                label: "Anthropic Access",
                key: "sk-anthropic-access",
                dataSource: .anthropic,
                enabled: true,
                createdAt: 2
            ),
        ]
        model.settings.primaryProxyAPIKeyID = "anthropic-restricted"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic API Key",
                accountID: "anthropic-account",
                authMode: .anthropicAPIKey
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-access")
    }

    @MainActor
    func testProxyTestPrefersExactDataSourceKeyOverAllKey() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "all-primary", label: "All Primary", key: "sk-all-primary", dataSource: .all, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "anthropic-secondary", label: "Anthropic Secondary", key: "sk-anthropic-secondary", dataSource: .anthropic, enabled: true, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "all-primary"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-secondary")
    }

    @MainActor
    func testProxyTestPrefersAllKeyBeforeOpenAIFallbackForAnthropicOAuth() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "all-primary", label: "All Primary", key: "sk-all-primary", dataSource: .all, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "openai-secondary", label: "OpenAI Secondary", key: "sk-openai-secondary", dataSource: .openAI, enabled: true, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "all-primary"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-all-primary")
        XCTAssertTrue(model.proxyTestCanSend)
    }

    @MainActor
    func testProxyTestPinnedAnthropicOAuthAccountSkipsRestrictedExactAndAllKeysBeforeCompatibleOpenAIFallback() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "anthropic-restricted",
                label: "Anthropic Restricted",
                key: "sk-anthropic-restricted",
                dataSource: .anthropic,
                allowedAccountKeys: ["key-other-account"],
                enabled: true,
                createdAt: 1
            ),
            ProxyAPIKeyRecord(
                id: "all-restricted",
                label: "All Restricted",
                key: "sk-all-restricted",
                dataSource: .all,
                allowedAccountKeys: ["key-other-account"],
                enabled: true,
                createdAt: 2
            ),
            ProxyAPIKeyRecord(
                id: "openai-compatible",
                label: "OpenAI Compatible",
                key: "sk-openai-compatible",
                dataSource: .openAI,
                allowedAccountKeys: ["key-anthropic-account"],
                enabled: true,
                createdAt: 3
            ),
        ]
        model.settings.primaryProxyAPIKeyID = "anthropic-restricted"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-openai-compatible")
        XCTAssertTrue(model.proxyTestCanSend)
        XCTAssertNil(model.proxyTestSelectedAccountIssueText())
    }

    @MainActor
    func testProxyTestPinnedAnthropicOAuthAccountWithoutCompatibleLocalKeyDisablesSendingAndShowsIssue() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: false, createdAt: 1),
            ProxyAPIKeyRecord(id: "anthropic-secondary", label: "Anthropic Secondary", key: "sk-anthropic-secondary", dataSource: .anthropic, enabled: false, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "")
        XCTAssertFalse(model.proxyTestCanSend)
        XCTAssertEqual(
            model.proxyTestSelectedAccountIssueText(),
            model.text(.proxyTestMissingAnthropicOAuthCompatibleAPIKey)
        )
        XCTAssertEqual(model.proxyTestSelectedAccountStatusText(), model.text(.statusUnavailable))
        XCTAssertEqual(model.proxyTestSelectedAccountStatusTone(), .warning)
    }

    @MainActor
    func testProxyTestPinnedAnthropicAPIKeyAccountWithOnlyRestrictedMatchingKeysDisablesSendingAndShowsAllowlistIssue() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "anthropic-restricted",
                label: "Anthropic Restricted",
                key: "sk-anthropic-restricted",
                dataSource: .anthropic,
                allowedAccountKeys: ["key-other-account"],
                enabled: true,
                createdAt: 1
            )
        ]
        model.settings.primaryProxyAPIKeyID = "anthropic-restricted"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic API Key",
                accountID: "anthropic-account",
                authMode: .anthropicAPIKey
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "")
        XCTAssertFalse(model.proxyTestCanSend)
        XCTAssertEqual(
            model.proxyTestSelectedAccountIssueText(),
            model.text(.proxyTestSelectedAccountOutsideAPIKeyAllowlist)
        )
        XCTAssertEqual(model.proxyTestSelectedAccountStatusText(), model.text(.statusUnavailable))
        XCTAssertEqual(model.proxyTestSelectedAccountStatusTone(), .warning)
    }

    @MainActor
    func testProxyTestPinnedAnthropicAPIKeyAccountWithoutMatchingDataSourceKeyDisablesSendingAndShowsIssue() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1)
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic API Key",
                accountID: "anthropic-account",
                authMode: .anthropicAPIKey
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "")
        XCTAssertFalse(model.proxyTestCanSend)
        XCTAssertEqual(
            model.proxyTestSelectedAccountIssueText(),
            model.text(.proxyTestMissingAnthropicDataSourceAPIKey)
        )
        XCTAssertEqual(model.proxyTestSelectedAccountStatusText(), model.text(.statusUnavailable))
        XCTAssertEqual(model.proxyTestSelectedAccountStatusTone(), .warning)
    }

    @MainActor
    func testProxyTestPinnedOpenAIAccountSkipsRestrictedOpenAIKeyForLaterCompatibleOne() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "openai-restricted",
                label: "OpenAI Restricted",
                key: "sk-openai-restricted",
                dataSource: .openAI,
                allowedAccountKeys: ["key-other-account"],
                enabled: true,
                createdAt: 1
            ),
            ProxyAPIKeyRecord(
                id: "openai-compatible",
                label: "OpenAI Compatible",
                key: "sk-openai-compatible",
                dataSource: .openAI,
                enabled: true,
                createdAt: 2
            ),
        ]
        model.settings.primaryProxyAPIKeyID = "openai-restricted"
        model.accounts = [
            Self.makeAccount(
                id: "openai-account",
                label: "OpenAI API Key",
                accountID: "openai-account",
                authMode: .openAIAPIKey
            )
        ]

        model.setProxyTestSelectedAccountKey("key-openai-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-openai-compatible")
    }

    @MainActor
    func testProxyTestPinnedGeminiOAuthAccountAllowsGeminiEndpointWithoutMatchingDataSourceKey() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1)
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.endpoint = .geminiGenerateContent
        model.accounts = [
            Self.makeAccount(
                id: "gemini-account",
                label: "Gemini OAuth",
                accountID: "gemini-account",
                authMode: .geminiOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-gemini-account")

        XCTAssertEqual(model.proxyTestDraft.apiKey, "")
        XCTAssertTrue(model.proxyTestCanSend)
        XCTAssertNil(model.proxyTestSelectedAccountIssueText())
        XCTAssertEqual(model.proxyTestSelectedAccountStatusText(), model.text(.statusRunning))
        XCTAssertEqual(model.proxyTestSelectedAccountStatusTone(), .success)
        XCTAssertTrue(model.proxyTestSelectedAccountDetailText().contains("admin-only"))
        XCTAssertTrue(model.proxyTestSelectedAccountDetailText().contains("Google / Gemini Login"))
    }

    @MainActor
    func testProxyTestPinnedGeminiOAuthAccountDisablesNonGeminiEndpoint() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1)
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.endpoint = .responses
        model.accounts = [
            Self.makeAccount(
                id: "gemini-account",
                label: "Gemini OAuth",
                accountID: "gemini-account",
                authMode: .geminiOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-gemini-account")

        XCTAssertFalse(model.proxyTestCanSend)
        XCTAssertNotNil(model.proxyTestSelectedAccountIssueText())
        XCTAssertTrue(model.proxyTestSelectedAccountIssueText()?.contains("Gemini CLI only") == true)
        XCTAssertTrue(model.proxyTestSelectedAccountIssueText()?.contains("Gemini endpoint") == true)
        XCTAssertEqual(model.proxyTestSelectedAccountStatusText(), model.text(.statusUnavailable))
        XCTAssertEqual(model.proxyTestSelectedAccountStatusTone(), .warning)
    }

    @MainActor
    func testProxyTestPinnedGeminiOAuthAccountUsesAdminOnlyExecutionForGeminiEndpoint() async {
        let probe = ProxyTestRouteProbe()
        let admin = AdminAPIClient(
            proxyTestRunNonStreamHandler: { payload in
                await probe.recordAdminRun(payload)
                XCTAssertEqual(payload.endpoint, .geminiGenerateContent)
                XCTAssertEqual(payload.model, "gemini-2.5-flash")
                XCTAssertEqual(payload.selectedAccountKey, "key-gemini-account")
                return SimpleHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data(#"{"candidates":[{"content":{"parts":[{"text":"Gemini admin route"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":2,"candidatesTokenCount":3,"totalTokenCount":5}}"#.utf8)
                )
            }
        )
        let publicClient = ProxyPublicAPIClient(
            healthHandler: { _ in },
            executeNonStreamHandler: { _ in
                await probe.recordPublicRun()
                throw ProxyError.message("public route should not be used")
            }
        )
        let model = DesktopAppModel(admin: admin, publicProxyClient: publicClient)
        model.preferences.languageMode = .english
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.endpoint = .geminiGenerateContent
        model.proxyTestDraft.model = "gemini-2.5-flash"
        model.accounts = [
            Self.makeAccount(
                id: "gemini-account",
                label: "Gemini OAuth",
                accountID: "gemini-account",
                authMode: .geminiOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-gemini-account")
        model.startProxyTest()

        await Self.waitForCondition {
            model.proxyTestRunState == .completed || model.proxyTestRunState == .failed
        }

        XCTAssertEqual(model.proxyTestRunState, .completed)
        XCTAssertEqual(model.proxyTestResult?.assistantText, "Gemini admin route")
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.adminRuns, 1)
        XCTAssertEqual(snapshot.publicRuns, 0)
    }

    @MainActor
    func testRemoteProxyTestConsoleRefreshUsesAdminStatusInsteadOfPublicHealth() async throws {
        let probe = ProxyTestRouteProbe()
        let expectedCatalog = ProxyTestModelCatalog.defaultCatalog

        defer { ProxyPublicAPIClientMockURLProtocol.resetHandler() }
        ProxyPublicAPIClientMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9911/admin/proxy-test/models")
            let data = try JSONEncoder().encode(expectedCatalog)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyPublicAPIClientMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            session: session,
            getStatusHandler: {
                ProxyStatus(
                    running: true,
                    publicBaseURL: "http://0.0.0.0:8787/v1",
                    anthropicBaseURL: "http://0.0.0.0:8787",
                    geminiBaseURL: "http://0.0.0.0:8787",
                    adminBaseURL: "http://127.0.0.1:8788/admin",
                    apiKey: "sk-remote",
                    activeAccountKey: nil,
                    activeAccountID: nil,
                    activeAccountLabel: nil,
                    lastError: nil,
                    daemonVersion: "1.0.0 Beta版",
                    proxyTestAdminTransportMode: .full
                )
            }
        )
        let publicClient = ProxyPublicAPIClient(
            healthHandler: { baseURL in
                await probe.recordHealthCall(baseURL)
                throw ProxyError.message("public health should not be used")
            }
        )
        let model = DesktopAppModel(admin: admin, publicProxyClient: publicClient)
        model.remoteAccessibleHostOverride = "tokyo.example.com"
        model.settings.proxyAPIKey = "sk-remote"

        await model.refreshProxyTestConsole()

        XCTAssertTrue(model.proxyTestConnectionHealthy)
        XCTAssertEqual(model.proxyTestRunState, .idle)
        XCTAssertEqual(model.proxyTestModelCatalog, expectedCatalog)
        XCTAssertEqual(model.status?.proxyTestAdminTransportMode, .full)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.healthCalls, [])
    }

    @MainActor
    func testProxyStatusDecodesMissingRemoteProxyTestTransportModeAsNil() throws {
        let data = Data(
            #"{"running":true,"public_base_url":"http://0.0.0.0:8787/v1","anthropic_base_url":"http://0.0.0.0:8787","gemini_base_url":"http://0.0.0.0:8787","admin_base_url":"http://127.0.0.1:8788/admin","api_key":"sk-remote","daemon_version":"1.0.0 Beta版"}"#.utf8
        )

        let status = try Helpers.readJSON(ProxyStatus.self, from: data)

        XCTAssertNil(status.proxyTestAdminTransportMode)
    }

    @MainActor
    func testProxyStatusDecodesFullRemoteProxyTestTransportMode() throws {
        let data = Data(
            #"{"running":true,"public_base_url":"http://0.0.0.0:8787/v1","anthropic_base_url":"http://0.0.0.0:8787","gemini_base_url":"http://0.0.0.0:8787","admin_base_url":"http://127.0.0.1:8788/admin","api_key":"sk-remote","daemon_version":"1.0.0 Beta版","proxy_test_admin_transport_mode":"full"}"#.utf8
        )

        let status = try Helpers.readJSON(ProxyStatus.self, from: data)

        XCTAssertEqual(status.proxyTestAdminTransportMode, .full)
    }

    @MainActor
    func testRemoteProxyTestResponsesUseAdminRouteInsteadOfPublicTransport() async {
        let probe = ProxyTestRouteProbe()
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            proxyTestRunNonStreamHandler: { payload in
                await probe.recordAdminRun(payload)
                return SimpleHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data(#"{"id":"resp_test","object":"response","created_at":1710000000,"status":"completed","model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Remote responses route"}]}],"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}"#.utf8)
                )
            }
        )
        let publicClient = ProxyPublicAPIClient(
            healthHandler: { _ in },
            executeNonStreamHandler: { draft in
                await probe.recordPublicRun(draft.endpoint.rawValue)
                throw ProxyError.message("public route should not be used")
            }
        )
        let model = DesktopAppModel(admin: admin, publicProxyClient: publicClient)
        model.remoteAccessibleHostOverride = "tokyo.example.com"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.endpoint = .responses
        model.proxyTestDraft.model = "gpt-5.4"
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.apiKey = "sk-remote"
        model.startProxyTest()

        await Self.waitForCondition {
            model.proxyTestRunState == .completed || model.proxyTestRunState == .failed
        }

        XCTAssertEqual(model.proxyTestRunState, .completed)
        XCTAssertEqual(model.proxyTestResult?.assistantText, "Remote responses route")
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.adminRuns, 1)
        XCTAssertEqual(snapshot.publicRuns, 0)
        XCTAssertEqual(snapshot.lastAdminPayload?.endpoint, .responses)
        XCTAssertEqual(snapshot.lastAdminPayload?.proxyAPIKey, "sk-remote")
    }

    @MainActor
    func testRemoteProxyTestAnthropicMessagesUseAdminRouteInsteadOfPublicTransport() async {
        let probe = ProxyTestRouteProbe()
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            proxyTestRunNonStreamHandler: { payload in
                await probe.recordAdminRun(payload)
                return SimpleHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "content-type": "application/json",
                        "anthropic-version": payload.anthropicVersion ?? ""
                    ],
                    body: Data(#"{"id":"msg_test","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"Remote anthropic route"}],"usage":{"input_tokens":2,"output_tokens":3}}"#.utf8)
                )
            }
        )
        let publicClient = ProxyPublicAPIClient(
            healthHandler: { _ in },
            executeNonStreamHandler: { draft in
                await probe.recordPublicRun(draft.endpoint.rawValue)
                throw ProxyError.message("public route should not be used")
            }
        )
        let model = DesktopAppModel(admin: admin, publicProxyClient: publicClient)
        model.remoteAccessibleHostOverride = "tokyo.example.com"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.endpoint = .anthropicMessages
        model.proxyTestDraft.model = "claude-sonnet-4-6"
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.apiKey = "sk-remote"
        model.startProxyTest()

        await Self.waitForCondition {
            model.proxyTestRunState == .completed || model.proxyTestRunState == .failed
        }

        XCTAssertEqual(model.proxyTestRunState, .completed)
        XCTAssertEqual(model.proxyTestResult?.assistantText, "Remote anthropic route")
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.adminRuns, 1)
        XCTAssertEqual(snapshot.publicRuns, 0)
        XCTAssertEqual(snapshot.lastAdminPayload?.endpoint, .anthropicMessages)
        XCTAssertEqual(snapshot.lastAdminPayload?.proxyAPIKey, "sk-remote")
        XCTAssertEqual(snapshot.lastAdminPayload?.anthropicVersion, AnthropicTranscoder.defaultAnthropicVersion)
    }

    @MainActor
    func testRemoteLegacyProxyTestCompatibilityDisablesDefaultSendAndShowsUpgradeHint() {
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                target: .remote(
                    .init(
                        adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                        tokenProvider: { "remote-admin-token" },
                        capabilities: AdminAPIClient.Capabilities.remoteTunnel
                    )
                )
            )
        )
        model.preferences.languageMode = .english
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.apiKey = "sk-remote"
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://0.0.0.0:8787/v1",
            anthropicBaseURL: "http://0.0.0.0:8787",
            geminiBaseURL: "http://0.0.0.0:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-remote",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )

        XCTAssertFalse(model.proxyTestCanSend)
        XCTAssertTrue(model.proxyTestSubtitleText.contains("remote admin tunnel"))
        XCTAssertTrue(model.proxyTestHealthHintText.contains("remote admin tunnel"))
        XCTAssertTrue(model.proxyTestResultHintText.contains("remote admin path"))
        XCTAssertTrue(model.proxyTestCompatibilityIssueText?.contains("Redeploy or upgrade the remote daemon") == true)
    }

    @MainActor
    func testRemoteLegacyProxyTestStartReturnsEarlyWithoutTriggeringAdminRun() async {
        let probe = ProxyTestRouteProbe()
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            proxyTestRunNonStreamHandler: { payload in
                await probe.recordAdminRun(payload)
                throw ProxyError.message("admin route should not be used")
            }
        )
        let publicClient = ProxyPublicAPIClient(
            executeNonStreamHandler: { draft in
                await probe.recordPublicRun(draft.endpoint.rawValue)
                throw ProxyError.message("public route should not be used")
            }
        )
        let model = DesktopAppModel(admin: admin, publicProxyClient: publicClient)
        model.preferences.languageMode = .english
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.apiKey = "sk-remote"
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://0.0.0.0:8787/v1",
            anthropicBaseURL: "http://0.0.0.0:8787",
            geminiBaseURL: "http://0.0.0.0:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-remote",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )

        model.startProxyTest()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(model.proxyTestRunState, .idle)
        XCTAssertEqual(snapshot.adminRuns, 0)
        XCTAssertEqual(snapshot.publicRuns, 0)
    }

    @MainActor
    func testRemoteLegacyGeminiPinnedOAuthAccountStillUsesAdminOnlyExecution() async {
        let probe = ProxyTestRouteProbe()
        let admin = AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                    tokenProvider: { "remote-admin-token" },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            proxyTestRunNonStreamHandler: { payload in
                await probe.recordAdminRun(payload)
                return SimpleHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data(#"{"candidates":[{"content":{"parts":[{"text":"Remote legacy Gemini route"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":2,"candidatesTokenCount":3,"totalTokenCount":5}}"#.utf8)
                )
            }
        )
        let publicClient = ProxyPublicAPIClient(
            executeNonStreamHandler: { draft in
                await probe.recordPublicRun(draft.endpoint.rawValue)
                throw ProxyError.message("public route should not be used")
            }
        )
        let model = DesktopAppModel(admin: admin, publicProxyClient: publicClient)
        model.preferences.languageMode = .english
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.endpoint = .geminiGenerateContent
        model.proxyTestDraft.model = "gemini-2.5-flash"
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://0.0.0.0:8787/v1",
            anthropicBaseURL: "http://0.0.0.0:8787",
            geminiBaseURL: "http://0.0.0.0:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-remote",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )
        model.accounts = [
            Self.makeAccount(
                id: "gemini-account",
                label: "Gemini OAuth",
                accountID: "gemini-account",
                authMode: .geminiOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-gemini-account")
        model.startProxyTest()

        await Self.waitForCondition {
            model.proxyTestRunState == .completed || model.proxyTestRunState == .failed
        }

        XCTAssertEqual(model.proxyTestRunState, .completed)
        XCTAssertEqual(model.proxyTestResult?.assistantText, "Remote legacy Gemini route")
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.adminRuns, 1)
        XCTAssertEqual(snapshot.publicRuns, 0)
    }

    @MainActor
    func testRemoteLegacyProxyTestConsoleRendersUpgradeHint() {
        let model = DesktopAppModel(
            admin: AdminAPIClient(
                target: .remote(
                    .init(
                        adminBaseURLProvider: { URL(string: "http://127.0.0.1:9911/admin")! },
                        tokenProvider: { "remote-admin-token" },
                        capabilities: AdminAPIClient.Capabilities.remoteTunnel
                    )
                )
            )
        )
        model.preferences.languageMode = .english
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"
        model.proxyTestDraft.apiKey = "sk-remote"
        model.status = ProxyStatus(
            running: true,
            publicBaseURL: "http://0.0.0.0:8787/v1",
            anthropicBaseURL: "http://0.0.0.0:8787",
            geminiBaseURL: "http://0.0.0.0:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-remote",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )

        let source = try? Self.repoFileText("Sources/CodexProxyDesktop/Views/ProxyTestConsoleView.swift")

        XCTAssertTrue(source?.contains("ProxyTestCompatibilityHint(text: compatibilityIssue)") == true)
        XCTAssertTrue(source?.contains("self.model.proxyTestCompatibilityIssueText") == true)
        XCTAssertFalse(model.proxyTestCanSend)
        XCTAssertTrue(model.proxyTestCompatibilityIssueText?.contains("Redeploy or upgrade the remote daemon") == true)
    }

    @MainActor
    func testProxyTestEndpointSwitchKeepsResolvedMatchingDataSourceKey() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "anthropic-secondary", label: "Anthropic Secondary", key: "sk-anthropic-secondary", dataSource: .anthropic, enabled: true, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]

        model.setProxyTestSelectedAccountKey("key-anthropic-account")
        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-secondary")

        model.updateProxyTestEndpoint(.responses)
        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-secondary")

        model.updateProxyTestEndpoint(.anthropicMessages)
        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-secondary")
    }

    @MainActor
    func testProxyTestAnthropicEndpointWithoutPinnedAccountPrefersAnthropicAccessKey() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "anthropic-secondary", label: "Anthropic Secondary", key: "sk-anthropic-secondary", dataSource: .anthropic, enabled: true, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"

        model.updateProxyTestEndpoint(.anthropicMessages)

        XCTAssertEqual(model.proxyTestDraft.apiKey, "sk-anthropic-secondary")
    }

    @MainActor
    func testProxyTestAnthropicEndpointWithoutPinnedAccountDoesNotFallBackToPrimaryOpenAIKey() {
        let model = DesktopAppModel()
        model.preferences.languageMode = .english
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1)
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.proxyTestConnectionHealthy = true
        model.proxyTestDraft.userPrompt = "Hello"

        model.updateProxyTestEndpoint(.anthropicMessages)

        XCTAssertEqual(model.proxyTestDraft.apiKey, "")
        XCTAssertFalse(model.proxyTestCanSend)
    }

    @MainActor
    func testCopyCurrentProxyTestAPIKeyCopiesResolvedPinnedKeyInsteadOfGlobalPrimary() {
        let model = DesktopAppModel()
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "openai-primary", label: "OpenAI Primary", key: "sk-openai-primary", dataSource: .openAI, enabled: true, createdAt: 1),
            ProxyAPIKeyRecord(id: "anthropic-secondary", label: "Anthropic Secondary", key: "sk-anthropic-secondary", dataSource: .anthropic, enabled: true, createdAt: 2),
        ]
        model.settings.primaryProxyAPIKeyID = "openai-primary"
        model.accounts = [
            Self.makeAccount(
                id: "anthropic-account",
                label: "Anthropic OAuth",
                accountID: "anthropic-account",
                authMode: .anthropicSubscriptionOAuth
            )
        ]
        NSPasteboard.general.clearContents()

        model.setProxyTestSelectedAccountKey("key-anthropic-account")
        model.copyCurrentProxyTestAPIKey()

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "sk-anthropic-secondary")
        XCTAssertNotEqual(NSPasteboard.general.string(forType: .string), model.localProxyAPIKeyValue)
    }

    @MainActor
    func testProxyTestSelectedAccountDetailShowsDisabledState() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "account-1",
            label: "Disabled API Key",
            accountID: "account-1",
            enabled: false,
            authMode: .openAIAPIKey
        )
        model.accounts = [account]
        model.proxyTestDraft.selectedAccountKey = account.accountKey

        XCTAssertEqual(model.proxyTestSelectedAccountStatusText(), model.text(.statusDisabled))
        XCTAssertEqual(model.proxyTestSelectedAccountStatusTone(), .danger)
        XCTAssertTrue(model.proxyTestSelectedAccountDetailText().contains("停用") || model.proxyTestSelectedAccountDetailText().contains("disabled"))
    }

    @MainActor
    func testProxyTestSelectedAccountDetailShowsCoolingIssue() {
        let model = DesktopAppModel()
        let account = Self.makeAccount(
            id: "account-1",
            label: "Cooling API Key",
            accountID: "account-1",
            authMode: .openAIAPIKey,
            cooldownUntil: Helpers.now() + 3_600
        )
        model.accounts = [account]
        model.proxyTestDraft.selectedAccountKey = account.accountKey

        XCTAssertEqual(model.proxyTestSelectedAccountStatusText(), model.text(.statusCoolingDown))
        XCTAssertEqual(model.proxyTestSelectedAccountStatusTone(), .warning)
        XCTAssertTrue(model.proxyTestSelectedAccountDetailText().contains("API") || model.proxyTestSelectedAccountDetailText().contains("冷却"))
    }
}

private extension CodexProxyDesktopTests {
    func bitmapData(for image: NSImage) -> Data {
        guard
            let representation = image.representations.first as? NSBitmapImageRep,
            let bitmapData = representation.bitmapData
        else {
            XCTFail("Expected bitmap-backed image")
            return Data()
        }

        return Data(bytes: bitmapData, count: representation.bytesPerRow * representation.pixelsHigh)
    }

    @MainActor
    static func unlockRemoteManagement(
        on model: DesktopAppModel,
        startingAt start: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) {
        model.registerRemoteManagementRevealTap(now: start)
        model.registerRemoteManagementRevealTap(now: start.addingTimeInterval(0.3))
        model.registerRemoteManagementRevealTap(now: start.addingTimeInterval(0.6))
    }

    static func makePreferencesStore() throws -> (DesktopPreferencesStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (DesktopPreferencesStore(dataDirectory: directory), directory)
    }

    @MainActor
    static func waitForRequestLogsRefresh(
        on model: DesktopAppModel,
        expectedModel: String? = nil,
        expectedPage: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            let matchesModel = expectedModel.map { model.requestLogPage.entries.first?.model == $0 } ?? true
            let matchesPage = expectedPage.map { model.requestLogPage.page == $0 } ?? true
            if model.requestLogsIsRefreshing == false, matchesModel, matchesPage {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for request logs refresh", file: file, line: line)
    }

    static func waitForRecordedRequestCount(
        on probe: RequestLogsProbe,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            let snapshot = await probe.snapshot()
            if snapshot.requestQueries.count >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for recorded request count \(count)", file: file, line: line)
    }

    @MainActor
    static func waitForCondition(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while start.duration(to: ContinuousClock.now) < timeout {
            if condition() {
                return
            }
            try? await Task.sleep(for: pollInterval)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    @MainActor
    static func makeRemoteModel(
        settings: AppConfig = AppConfig(),
        admin: AdminAPIClient? = nil,
        remoteDeploy: any RemoteDeploying = RemoteDeployStub(),
        confirmDeleteRemoteHostHandler: DesktopAppModel.ConfirmDeleteRemoteHostHandler? = nil,
        remoteAdminWindowFactory: DesktopAppModel.RemoteAdminWindowFactory? = nil
    ) -> DesktopAppModel {
        let admin = admin ?? AdminAPIClient(
            getStatusHandler: { Self.makeProxyStatus(running: false) },
            saveSettingsHandler: { config in config },
            getManagedProxySnapshotHandler: { ManagedProxySnapshot() },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            statusHandler: { Self.makeLocalServiceStatus(running: false) }
        )
        let resolvedRemoteAdminWindowFactory = remoteAdminWindowFactory ?? { host, _, _, onClose, _ in
            RemoteAdminWindowControllerSpy(hostID: host.id, onClose: onClose)
        }
        let model = DesktopAppModel(
            admin: admin,
            daemon: daemon,
            remoteDeploy: remoteDeploy,
            remoteAdminWindowFactory: resolvedRemoteAdminWindowFactory,
            confirmDeleteRemoteHostHandler: confirmDeleteRemoteHostHandler
        )
        model.settings = settings
        model.syncSelectedRemoteHost()
        return model
    }

    @MainActor
    static func makeRemoteAdminWindowModel(
        host: RemoteHostConfig,
        preferences: DesktopPreferences = DesktopPreferences(),
        remoteDeploy: any RemoteDeploying = RemoteDeployStub(),
        admin: AdminAPIClient? = nil,
        tunnelController: (any RemoteAdminTunneling)? = nil,
        localAccountsExportHandler: RemoteAdminWindowModel.LocalAccountsExportHandler? = nil,
        confirmImportLocalAccountsHandler: RemoteAdminWindowModel.ConfirmImportLocalAccountsHandler? = nil
    ) -> RemoteAdminWindowModel {
        RemoteAdminWindowModel(
            host: host,
            preferences: preferences,
            remoteDeploy: remoteDeploy,
            admin: admin,
            tunnelController: tunnelController ?? RemoteAdminTunnelController(host: host, ssh: RemoteAdminSSHStub()),
            localAccountsExportHandler: localAccountsExportHandler,
            confirmImportLocalAccountsHandler: confirmImportLocalAccountsHandler
        )
    }

    @MainActor
    static func prepareRemoteAdminWindowModelForVisibleLayout(
        _ model: RemoteAdminWindowModel,
        host: RemoteHostConfig
    ) {
        model.appModel.preferences.languageMode = .english
        model.appModel.status = Self.makeProxyStatus(running: true)
        model.sessionState = RemoteAdminSessionState(
            hostID: host.id,
            adminBaseURL: URL(string: "http://127.0.0.1:9911/admin"),
            remoteEndpoint: "\(host.host):\(host.adminPort)",
            configuredAdminPort: host.adminPort,
            effectiveAdminPort: host.adminPort,
            localPort: 9911,
            tunnelStatus: .connected(localPort: 9911),
            reachabilityStatus: .reachable
        )
    }

    @MainActor
    static func makeRemoteAdminHostingView(
        model: RemoteAdminWindowModel,
        width: CGFloat = 1320,
        height: CGFloat = 860
    ) -> (window: NSWindow, hostingView: NSHostingView<AnyView>) {
        Self.makeHostedView(
            width: width,
            height: height,
            rootView: AnyView(
                RemoteAdminWindowView(model: model)
                    .frame(width: width, height: height)
            )
        )
    }

    @MainActor
    static func makeHostedView(
        width: CGFloat,
        height: CGFloat,
        rootView: AnyView
    ) -> (window: NSWindow, hostingView: NSHostingView<AnyView>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView
        return (window, hostingView)
    }

    static func makeRemoteHost(
        id: String,
        label: String,
        host: String,
        sshUser: String = "root",
        sshPort: Int = 22,
        authMode: RemoteHostConfig.AuthMode = .sshKeyPath,
        remoteDirectory: String = "/opt/codex-proxy",
        publicPort: Int = 8787,
        adminPort: Int = 8788
    ) -> RemoteHostConfig {
        RemoteHostConfig(
            id: id,
            label: label,
            host: host,
            sshPort: sshPort,
            sshUser: sshUser,
            authMode: authMode,
            identityFile: "",
            privateKey: authMode == .sshKeyContent ? "PRIVATE KEY" : "",
            password: authMode == .password ? "secret" : "",
            remoteDirectory: remoteDirectory,
            publicPort: publicPort,
            adminPort: adminPort
        )
    }

    static func makeRemoteConnectionCheck(
        hostID: String,
        architecture: String = "arm64",
        remoteUser: String = "root",
        remoteDirectoryWritable: Bool = true,
        systemctlAvailable: Bool = true,
        sudoAvailable: Bool = true,
        localArtifactAvailable: Bool = true
    ) -> RemoteConnectionCheck {
        RemoteConnectionCheck(
            hostID: hostID,
            architecture: architecture,
            remoteUser: remoteUser,
            remoteDirectoryWritable: remoteDirectoryWritable,
            systemctlAvailable: systemctlAvailable,
            sudoAvailable: sudoAvailable,
            localArtifactAvailable: localArtifactAvailable
        )
    }

    static func makeRemoteDeployStatus(
        hostID: String,
        host: String,
        publicPort: Int,
        running: Bool = false,
        installed: Bool = true,
        enabled: Bool = true,
        architecture: String = "arm64"
    ) -> RemoteDeployStatus {
        RemoteDeployStatus(
            hostID: hostID,
            installed: installed,
            serviceInstalled: true,
            running: running,
            enabled: enabled,
            architecture: architecture,
            baseURL: "http://\(host):\(publicPort)/v1",
            apiKey: nil,
            lastError: nil
        )
    }

    static func makeRequestLogEntry(
        id: Int64,
        model: String,
        apiKey: String,
        clientSource: RequestLogClientSource = .other,
        reasoningEffort: String? = nil,
        accountKey: String = "principal|account",
        accountLabel: String = "Primary"
    ) -> RequestLogEntry {
        RequestLogEntry(
            id: id,
            timestamp: 1_776_052_953,
            endpoint: "/v1/responses",
            clientSource: clientSource,
            model: model,
            reasoningEffort: reasoningEffort,
            apiKey: apiKey,
            accountKey: accountKey,
            accountLabel: accountLabel,
            success: true,
            latencyMS: 120,
            inputTokens: 10,
            outputTokens: 6,
            totalTokens: 16,
            cacheHitTokens: 2,
            failureCategory: ProxyRequestTrace.FailureCategory.none.rawValue,
            errorSummary: nil
        )
    }

    static func makeLocalServiceStatus(
        running: Bool,
        installed: Bool = true,
        launchctlState: String? = nil
    ) -> LocalServiceStatus {
        LocalServiceStatus(
            installed: installed,
            running: running,
            launchctlState: launchctlState ?? (running ? "running" : (installed ? "not_registered" : "not_installed")),
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )
    }

    static func makeProxyStatus(
        running: Bool,
        proxyTestAdminTransportMode: ProxyStatus.ProxyTestAdminTransportMode? = .full
    ) -> ProxyStatus {
        ProxyStatus(
            running: running,
            publicBaseURL: "http://127.0.0.1:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://127.0.0.1:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-local",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版",
            proxyTestAdminTransportMode: proxyTestAdminTransportMode
        )
    }

    static func makeStatsSummary(totalRequests: Int64) -> AdminStatsSummary {
        AdminStatsSummary(
            totalRequests: totalRequests,
            totalFailures: 0,
            totalAuthFailures: 0,
            totalRateLimits: 0,
            totalQuotaFailures: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalTokens: 0,
            latestBuckets: []
        )
    }

    static func makeAccount(
        id: String,
        label: String,
        email: String? = nil,
        accountID: String,
        accountKey: String? = nil,
        enabled: Bool = true,
        isCurrent: Bool = false,
        updatedAt: Int64 = 1_710_000_000,
        selectionOrder: Int64 = 0,
        authMode: AccountAuthMode = .chatGPT,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        upstreamBaseURL: String? = nil,
        managedProxyNodeName: String? = nil,
        modelRouting: AccountModelRoutingConfig? = nil,
        usage: UsageSnapshot? = nil,
        usageWindowsVisible: Bool = true,
        todayTokenUsage: AccountTodayTokenUsage? = nil,
        consecutiveFailureCount: Int64 = 0,
        cooldownUntil: Int64? = nil,
        automaticCooldownDisabled: Bool = false,
        usageError: String? = nil,
        authRefreshBlocked: Bool = false,
        authRefreshError: String? = nil
    ) -> AccountSummary {
        AccountSummary(
            id: id,
            label: label,
            email: email ?? "\(id)@example.com",
            accountKey: accountKey ?? "key-\(id)",
            accountID: accountID,
            planType: authMode.isManualAPIKey ? "api_key" : "free",
            authMode: authMode,
            providerPreset: providerPreset,
            upstreamBaseURL: upstreamBaseURL,
            managedProxyNodeName: managedProxyNodeName,
            modelRouting: modelRouting,
            addedAt: updatedAt - 60,
            updatedAt: updatedAt,
            enabled: enabled,
            selectionOrder: selectionOrder,
            consecutiveFailureCount: consecutiveFailureCount,
            cooldownUntil: cooldownUntil,
            automaticCooldownDisabled: automaticCooldownDisabled,
            usage: usage,
            usageWindowsVisible: usageWindowsVisible,
            todayTokenUsage: todayTokenUsage,
            usageError: usageError,
            authRefreshBlocked: authRefreshBlocked,
            authRefreshError: authRefreshError,
            isCurrent: isCurrent
        )
    }

    static func makeProxyTestGPTCatalog(models: [String]) -> ProxyTestModelCatalog {
        let defaultModel = models.first ?? ProxyTranscoder.defaultModel
        let gptGroup = ProxyTestModelGroup(
            family: .gpt,
            models: models,
            defaultModel: defaultModel
        )
        return ProxyTestModelCatalog(
            chatCompletions: gptGroup,
            responses: gptGroup,
            anthropicMessages: ProxyTestModelCatalog.defaultCatalog.anthropicMessages,
            geminiGenerateContent: ProxyTestModelCatalog.defaultCatalog.geminiGenerateContent
        )
    }

    @MainActor
    static func renderHostedView(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    @MainActor
    static func hostedProgressIndicatorCount(in view: NSView) -> Int {
        self.hostedSubviewCount(in: view, named: "NSProgressIndicator")
    }

    @MainActor
    static func hostedScrollViews(in view: NSView) -> [NSScrollView] {
        CompactOverlayScrollbarStyleController.scrollViews(in: view)
    }

    @MainActor
    static func hostedSubviewCount(in view: NSView, named typeName: String) -> Int {
        let description = self.hostedSubviewDescription(for: view)
        return max(description.components(separatedBy: typeName).count - 1, 0)
    }

    @MainActor
    static func hostedTextValues(in view: NSView) -> [String] {
        var values: [String] = []
        var visited = Set<ObjectIdentifier>()

        func append(_ rawValue: String?) {
            guard let rawValue else { return }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty == false {
                values.append(value)
            }
        }

        func collect(from object: NSObject) {
            let objectID = ObjectIdentifier(object)
            guard visited.insert(objectID).inserted else { return }

            if let button = object as? NSButton {
                append(button.title)
            }
            if let textField = object as? NSTextField {
                append(textField.stringValue)
            }

            append(Self.hostedAccessibilityString(for: object, selectorName: "accessibilityLabel"))
            append(Self.hostedAccessibilityString(for: object, selectorName: "accessibilityValue"))

            if let currentView = object as? NSView {
                currentView.subviews.forEach(collect)
            }

            Self.hostedAccessibilityChildren(for: object).forEach(collect)
        }

        collect(from: view)
        return values
    }

    @MainActor
    static func hostedTextFrame(in view: NSView, value: String) -> CGRect? {
        var result: CGRect?

        func collect(from currentView: NSView) {
            guard result == nil else { return }
            if let button = currentView as? NSButton {
                let text = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if text == value {
                    result = button.convert(button.bounds, to: view)
                    return
                }
            }
            if let textField = currentView as? NSTextField {
                let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if text == value {
                    result = textField.convert(textField.bounds, to: view)
                    return
                }
            }
            currentView.subviews.forEach(collect)
        }

        collect(from: view)
        return result
    }

    @MainActor
    static func hostedView(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        self.hostedAccessibilityObject(withAccessibilityIdentifier: identifier, in: view) as? NSView
    }

    @MainActor
    static func hostedViewFrame(withAccessibilityIdentifier identifier: String, in view: NSView) -> CGRect? {
        if let hostedView = self.hostedView(withAccessibilityIdentifier: identifier, in: view) {
            return hostedView.convert(hostedView.bounds, to: view)
        }
        guard let object = self.hostedAccessibilityObject(withAccessibilityIdentifier: identifier, in: view) else {
            return nil
        }
        return self.hostedAccessibilityFrame(for: object)
    }

    @MainActor
    static func hostedAccessibilityObject(withAccessibilityIdentifier identifier: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        var result: NSObject?

        func collect(from object: NSObject) {
            let objectID = ObjectIdentifier(object)
            guard result == nil, visited.insert(objectID).inserted else { return }
            if Self.hostedAccessibilityIdentifier(for: object) == identifier {
                result = object
                return
            }
            if let view = object as? NSView {
                view.subviews.forEach(collect)
            }
            Self.hostedAccessibilityChildren(for: object).forEach(collect)
        }

        collect(from: root)
        return result
    }

    @MainActor
    static func hostedAccessibilityIdentifier(for object: NSObject) -> String? {
        if let view = object as? NSView,
           let identifier = view.identifier?.rawValue,
           !identifier.isEmpty {
            return identifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    @MainActor
    static func hostedAccessibilityChildren(for object: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector),
              let value = object.perform(selector)?.takeUnretainedValue()
        else {
            return []
        }

        if let objects = value as? [NSObject] {
            return objects
        }
        if let objects = value as? [AnyObject] {
            return objects.compactMap { $0 as? NSObject }
        }
        return []
    }

    @MainActor
    static func hostedAccessibilityFrame(for object: NSObject) -> CGRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector),
              let value = object.perform(selector)?.takeUnretainedValue()
        else {
            return nil
        }
        if let rectValue = value as? NSValue {
            return rectValue.rectValue
        }
        return value as? CGRect
    }

    @MainActor
    static func hostedAccessibilityString(for object: NSObject, selectorName: String) -> String? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let value = object.perform(selector)?.takeUnretainedValue()
        else {
            return nil
        }

        if let stringValue = value as? String {
            return stringValue
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    @MainActor
    static func assertCompactOverlayScrollbars(
        in view: NSView,
        minimumCount: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scrollViews = self.hostedScrollViews(in: view)
        XCTAssertGreaterThanOrEqual(scrollViews.count, minimumCount, "scrollViews=\(scrollViews.count)", file: file, line: line)
        XCTAssertTrue(
            scrollViews.allSatisfy { $0.scrollerStyle == .overlay },
            "scrollViewStyles=\(scrollViews.map { $0.scrollerStyle.rawValue })",
            file: file,
            line: line
        )
        XCTAssertTrue(
            scrollViews.allSatisfy(\.autohidesScrollers),
            "autohides=\(scrollViews.map { $0.autohidesScrollers })",
            file: file,
            line: line
        )

        let scrollers = scrollViews.compactMap(\.verticalScroller) + scrollViews.compactMap(\.horizontalScroller)
        XCTAssertFalse(scrollers.isEmpty, file: file, line: line)
        XCTAssertTrue(
            scrollers.allSatisfy { $0.controlSize == .small },
            "scrollerControlSizes=\(scrollers.map { $0.controlSize.rawValue })",
            file: file,
            line: line
        )
        XCTAssertTrue(
            scrollers.allSatisfy { $0.scrollerStyle == .overlay },
            "scrollerStyles=\(scrollers.map { $0.scrollerStyle.rawValue })",
            file: file,
            line: line
        )
    }

    @MainActor
    static func hasCompactOverlayScrollbars(in view: NSView, minimumCount: Int = 1) -> Bool {
        let scrollViews = self.hostedScrollViews(in: view)
        guard scrollViews.count >= minimumCount else {
            return false
        }
        guard scrollViews.allSatisfy({ $0.scrollerStyle == .overlay }) else {
            return false
        }
        guard scrollViews.allSatisfy(\.autohidesScrollers) else {
            return false
        }

        let scrollers = scrollViews.compactMap(\.verticalScroller) + scrollViews.compactMap(\.horizontalScroller)
        guard scrollers.isEmpty == false else {
            return false
        }
        guard scrollers.allSatisfy({ $0.controlSize == .small }) else {
            return false
        }
        return scrollers.allSatisfy { $0.scrollerStyle == .overlay }
    }

    @MainActor
    static func remoteAdminTopBarItemFrames(in view: NSView) -> [CGRect] {
        var frames: [CGRect] = []
        for subview in view.subviews {
            let frame = subview.frame
            if frame.minY <= 40,
               frame.height >= 20,
               frame.height <= 32,
               frame.width >= 80 {
                frames.append(frame)
            }
        }
        return frames
    }

    @MainActor
    static func remoteAdminTabStripFrame(in view: NSView) -> CGRect? {
        var candidates: [CGRect] = []
        for subview in view.subviews {
            let frame = subview.frame
            if frame.width >= 1000,
               frame.height >= 40,
               frame.height <= 70,
               frame.minY >= 40,
               frame.minY <= 500 {
                candidates.append(frame)
            }
        }
        return candidates.sorted { $0.minY < $1.minY }.first
    }

    @MainActor
    static func hostedSubviewDescription(for view: NSView) -> String {
        let selector = Selector(("_subtreeDescription"))
        guard view.responds(to: selector),
              let value = view.perform(selector)?.takeUnretainedValue() as? String else {
            return view.debugDescription
        }
        return value
    }

    static func repoFileText(_ path: String) throws -> String {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = rootURL.appendingPathComponent(path)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}

private actor ManualAPIKeyUpdateProbe {
    private var id: String?
    private var input: UpdateManualAPIKeyAccountRequest?

    func record(id: String, input: UpdateManualAPIKeyAccountRequest) {
        self.id = id
        self.input = input
    }

    func snapshot() -> (id: String?, input: UpdateManualAPIKeyAccountRequest?) {
        (self.id, self.input)
    }
}

private actor ManualAPIKeyAddProbe {
    private var input: ManualAPIKeyAccountInput?

    func record(_ input: ManualAPIKeyAccountInput) {
        self.input = input
    }

    func snapshot() -> ManualAPIKeyAccountInput? {
        self.input
    }
}

private actor AccountOrderUpdateProbe {
    private var payloadValue: UpdateAccountOrderRequest?

    func record(payload: UpdateAccountOrderRequest) {
        self.payloadValue = payload
    }

    func payload() -> UpdateAccountOrderRequest? {
        self.payloadValue
    }
}

private actor OAuthCallbackCompletionProbe {
    private var providerFamilyValue: AccountProviderFamily?
    private var callbackURLValue: String?

    func record(providerFamily: AccountProviderFamily, callbackURL: String) {
        self.providerFamilyValue = providerFamily
        self.callbackURLValue = callbackURL
    }

    func snapshot() -> (providerFamily: AccountProviderFamily?, callbackURL: String?) {
        (self.providerFamilyValue, self.callbackURLValue)
    }
}

private actor OAuthCallbackCompletionSequence {
    private var results: [Result<AccountSummary, Error>]

    init(results: [Result<AccountSummary, Error>]) {
        self.results = results
    }

    func next() throws -> AccountSummary {
        guard !self.results.isEmpty else {
            throw ProxyError.message("Unexpected extra OAuth completion attempt")
        }
        return try self.results.removeFirst().get()
    }
}

private actor AccountLabelUpdateProbe {
    private var id: String?
    private var input: UpdateAccountLabelRequest?

    func record(id: String, input: UpdateAccountLabelRequest) {
        self.id = id
        self.input = input
    }

    func snapshot() -> (id: String?, input: UpdateAccountLabelRequest?) {
        (self.id, self.input)
    }
}

private actor AccountManagedProxyNodeUpdateProbe {
    private var id: String?
    private var input: UpdateAccountManagedProxyNodeRequest?

    func record(id: String, input: UpdateAccountManagedProxyNodeRequest) {
        self.id = id
        self.input = input
    }

    func snapshot() -> (id: String?, input: UpdateAccountManagedProxyNodeRequest?) {
        (self.id, self.input)
    }
}

private actor AccountManagedProxyNodeClearProbe {
    private var storedAccounts: [AccountSummary]
    private var clearCalls = 0

    init(accounts: [AccountSummary]) {
        self.storedAccounts = accounts
    }

    func accounts() -> [AccountSummary] {
        self.storedAccounts
    }

    func clearAll() -> ClearAccountManagedProxyNodesResult {
        self.clearCalls += 1
        let clearedCount = self.storedAccounts.reduce(into: 0) { count, account in
            if AccountSummary.normalizedManagedProxyNodeName(account.managedProxyNodeName) != nil {
                count += 1
            }
        }
        self.storedAccounts = self.storedAccounts.map { account in
            var updated = account
            updated.managedProxyNodeName = nil
            return updated
        }
        return .init(clearedCount: clearedCount)
    }

    func callCount() -> Int {
        self.clearCalls
    }
}

private actor AccountCooldownStopProbe {
    private var storedAccount: AccountSummary
    private var stopCalls = 0

    init(account: AccountSummary) {
        self.storedAccount = account
    }

    func accounts() -> [AccountSummary] {
        [self.storedAccount]
    }

    func stop(id: String) throws -> AccountSummary {
        guard id == self.storedAccount.id else {
            throw ProxyError.message("unexpected account id \(id)")
        }
        self.stopCalls += 1
        self.storedAccount.consecutiveFailureCount = 0
        self.storedAccount.cooldownUntil = nil
        self.storedAccount.usageError = nil
        return self.storedAccount
    }

    func callCount() -> Int {
        self.stopCalls
    }
}

private actor AccountCooldownPolicyUpdateProbe {
    private var storedAccount: AccountSummary
    private var id: String?
    private var input: UpdateAccountCooldownPolicyRequest?

    init(account: AccountSummary) {
        self.storedAccount = account
    }

    func accounts() -> [AccountSummary] {
        [self.storedAccount]
    }

    func update(id: String, input: UpdateAccountCooldownPolicyRequest) throws -> AccountSummary {
        guard id == self.storedAccount.id else {
            throw ProxyError.message("unexpected account id \(id)")
        }
        self.id = id
        self.input = input
        self.storedAccount.automaticCooldownDisabled = input.automaticCooldownDisabled
        if input.automaticCooldownDisabled {
            self.storedAccount.consecutiveFailureCount = 0
            self.storedAccount.cooldownUntil = nil
            self.storedAccount.usageError = nil
        }
        return self.storedAccount
    }

    func snapshot() -> (id: String?, input: UpdateAccountCooldownPolicyRequest?) {
        (self.id, self.input)
    }
}

private actor AccountModelRoutingUpdateProbe {
    private var id: String?
    private var input: UpdateAccountModelRoutingRequest?

    func record(id: String, input: UpdateAccountModelRoutingRequest) {
        self.id = id
        self.input = input
    }

    func snapshot() -> (id: String?, input: UpdateAccountModelRoutingRequest?) {
        (self.id, self.input)
    }
}

private actor StatsRefreshProbe {
    private var responses: [AdminStatsSummary]
    private let fallback: AdminStatsSummary
    private var callCount = 0

    init(responses: [AdminStatsSummary]) {
        self.responses = responses
        self.fallback = responses.last ?? CodexProxyDesktopTests.makeStatsSummary(totalRequests: 0)
    }

    func nextStats() -> AdminStatsSummary {
        self.callCount += 1
        guard self.responses.isEmpty == false else {
            return self.fallback
        }
        return self.responses.removeFirst()
    }

    func snapshot() -> Int {
        self.callCount
    }
}

private actor RequestLogsProbe {
    private(set) var requestQueries: [RequestLogQuery] = []
    private(set) var filterQueries: [RequestLogQuery] = []

    func recordRequest(_ query: RequestLogQuery) {
        self.requestQueries.append(query)
    }

    func recordFilterRequest(_ query: RequestLogQuery) {
        self.filterQueries.append(query)
    }

    func snapshot() -> (requestQueries: [RequestLogQuery], filterQueries: [RequestLogQuery]) {
        (self.requestQueries, self.filterQueries)
    }
}

private actor ManagedProxyActionProbe {
    private var savedSettingsCount = 0
    private var savedManagedProxyConfigCount = 0
    private var savedManagedProxyHealthcheckConfigCount = 0
    private var applyLaunchConfigurationCount = 0
    private var updateManagedProxySubscriptionCount = 0
    private var selectedManagedProxyNodeNames: [String] = []
    private var switchedManagedProxyCurrentNodeNames: [String] = []
    private var updatedManagedProxyPinnedNodeNames: [String?] = []
    private var healthcheckedManagedProxyNodeNames: [String?] = []

    func recordSaveSettings(_ config: AppConfig) {
        _ = config
        self.savedSettingsCount += 1
    }

    func recordSavedManagedProxyConfig(_ payload: ManagedProxyConfigPayload) {
        _ = payload
        self.savedManagedProxyConfigCount += 1
    }

    func recordSavedManagedProxyHealthcheckConfig(_ payload: ManagedProxyHealthcheckConfigPayload) {
        _ = payload
        self.savedManagedProxyHealthcheckConfigCount += 1
    }

    func recordApply(config: AppConfig, preserveRunningService: Bool) {
        _ = config
        _ = preserveRunningService
        self.applyLaunchConfigurationCount += 1
    }

    func recordUpdateManagedProxySubscription() {
        self.updateManagedProxySubscriptionCount += 1
    }

    func recordSelectedManagedProxyNode(_ name: String) {
        self.selectedManagedProxyNodeNames.append(name)
    }

    func recordSwitchedManagedProxyCurrentNode(_ name: String) {
        self.switchedManagedProxyCurrentNodeNames.append(name)
    }

    func recordUpdatedManagedProxyPinnedNode(_ name: String?) {
        self.updatedManagedProxyPinnedNodeNames.append(name)
    }

    func recordManagedProxyHealthcheck(_ nodeName: String?) {
        self.healthcheckedManagedProxyNodeNames.append(nodeName)
    }

    func snapshot() -> (
        savedSettingsCount: Int,
        savedManagedProxyConfigCount: Int,
        savedManagedProxyHealthcheckConfigCount: Int,
        applyLaunchConfigurationCount: Int,
        updateManagedProxySubscriptionCount: Int,
        selectedManagedProxyNodeNames: [String],
        switchedManagedProxyCurrentNodeNames: [String],
        updatedManagedProxyPinnedNodeNames: [String?],
        healthcheckedManagedProxyNodeNames: [String?]
    ) {
        (
            self.savedSettingsCount,
            self.savedManagedProxyConfigCount,
            self.savedManagedProxyHealthcheckConfigCount,
            self.applyLaunchConfigurationCount,
            self.updateManagedProxySubscriptionCount,
            self.selectedManagedProxyNodeNames,
            self.switchedManagedProxyCurrentNodeNames,
            self.updatedManagedProxyPinnedNodeNames,
            self.healthcheckedManagedProxyNodeNames
        )
    }
}

private actor ManagedProxyWebsiteProbeAttemptProbe {
    private var counts: [ManagedProxyWebsiteProbeTarget: Int] = [:]

    func record(_ target: ManagedProxyWebsiteProbeTarget) -> Int {
        let next = self.counts[target, default: 0] + 1
        self.counts[target] = next
        return next
    }

    func snapshot() -> [ManagedProxyWebsiteProbeTarget: Int] {
        self.counts
    }
}

private final class CapturedURLRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    func record(_ request: URLRequest) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storedRequest = request
    }

    func request() -> URLRequest? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storedRequest
    }
}

private final class ProxyPublicAPIClientMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping Handler) {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        self.state.handler = handler
    }

    static func resetHandler() {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        self.state.handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.lock.lock()
        let handler = Self.state.handler
        Self.state.lock.unlock()

        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if data.isEmpty == false {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor DaemonOperationProbe {
    private var running: Bool
    private var stopCalls = 0
    private var startCalls = 0
    private var applyPreserveRunningServiceFlags: [Bool] = []

    init(running: Bool) {
        self.running = running
    }

    func recordStop() {
        self.stopCalls += 1
        self.running = false
    }

    func recordStart() {
        self.startCalls += 1
        self.running = true
    }

    func recordApply(preserveRunningService: Bool) {
        self.applyPreserveRunningServiceFlags.append(preserveRunningService)
    }

    func localStatus() -> LocalServiceStatus {
        LocalServiceStatus(
            installed: true,
            running: self.running,
            launchctlState: self.running ? "running" : "not_registered",
            stdoutPath: "",
            stderrPath: "",
            lastErrorSummary: nil
        )
    }

    func proxyStatus() -> ProxyStatus {
        ProxyStatus(
            running: self.running,
            publicBaseURL: "http://127.0.0.1:8787/v1",
            anthropicBaseURL: "http://127.0.0.1:8787",
            geminiBaseURL: "http://127.0.0.1:8787",
            adminBaseURL: "http://127.0.0.1:8788/admin",
            apiKey: "sk-local",
            activeAccountKey: nil,
            activeAccountID: nil,
            activeAccountLabel: nil,
            lastError: nil,
            daemonVersion: "1.0.0 Beta版"
        )
    }

    func stopCallCount() -> Int {
        self.stopCalls
    }

    func startCallCount() -> Int {
        self.startCalls
    }

    func applyPreserveFlags() -> [Bool] {
        self.applyPreserveRunningServiceFlags
    }
}
#endif
