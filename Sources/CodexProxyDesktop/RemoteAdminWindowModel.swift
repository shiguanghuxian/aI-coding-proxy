#if os(macOS)
import AppKit
import Combine
import CodexProxyCore
import CodexProxyDeploy
import Foundation
import SwiftUI

@MainActor
final class RemoteAdminWindowModel: ObservableObject {
    typealias LocalAccountsExportHandler = @Sendable () async throws -> Data
    typealias ConfirmImportLocalAccountsHandler = @Sendable (LocalAccountsImportConfirmationContent) -> Bool

    enum Page: String, CaseIterable, Identifiable {
        case overview
        case accounts
        case proxy
        case outboundProxy

        var id: String { self.rawValue }

        var symbolName: String {
            switch self {
            case .overview:
                return "square.grid.2x2.fill"
            case .accounts:
                return "person.2.crop.square.stack.fill"
            case .proxy:
                return "bolt.horizontal.circle.fill"
            case .outboundProxy:
                return "point.topleft.down.curvedto.point.bottomright.up.fill"
            }
        }
    }

    struct OperationalNotice: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let tone: StatusPill.Tone
    }

    struct LocalAccountsImportConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    private enum AdminPortSyncFeedback: Equatable {
        case synced(configuredPort: Int, effectivePort: Int)
        case failed(configuredPort: Int, effectivePort: Int, detail: String)
    }

    private final class RemoteHostRuntimeState {
        var host: RemoteHostConfig
        var lastStatus: RemoteDeployStatus?

        init(host: RemoteHostConfig) {
            self.host = host
        }
    }

    private(set) var host: RemoteHostConfig
    let appModel: DesktopAppModel

    @Published var selectedPage: Page = .overview {
        didSet {
            self.syncAppModelPageSelection()
        }
    }
    @Published var isHeaderExpanded = false
    @Published var sessionState: RemoteAdminSessionState
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoadedInitialContent = false
    @Published private(set) var lastSuccessfulRefreshAt: Date?

    private let hostState: RemoteHostRuntimeState
    private let tunnelController: any RemoteAdminTunneling
    private let discoveredAdminPortHandler: RemoteAdminDiscoveredPortHandler?
    private let localAccountsExportHandler: LocalAccountsExportHandler
    private let confirmImportLocalAccountsHandler: ConfirmImportLocalAccountsHandler?
    private var adminPortSyncFeedback: AdminPortSyncFeedback?
    private var appModelChangeCancellable: AnyCancellable?

    init(
        host: RemoteHostConfig,
        preferences: DesktopPreferences,
        remoteDeploy: any RemoteDeploying = RemoteDeployService(),
        admin: AdminAPIClient? = nil,
        tunnelController: (any RemoteAdminTunneling)? = nil,
        discoveredAdminPortHandler: RemoteAdminDiscoveredPortHandler? = nil,
        localAccountsExportHandler: LocalAccountsExportHandler? = nil,
        confirmImportLocalAccountsHandler: ConfirmImportLocalAccountsHandler? = nil
    ) {
        self.host = host
        self.hostState = RemoteHostRuntimeState(host: host)
        self.tunnelController = tunnelController ?? RemoteAdminTunnelController(host: host)
        self.discoveredAdminPortHandler = discoveredAdminPortHandler
        self.localAccountsExportHandler = localAccountsExportHandler ?? {
            try await AdminAPIClient().exportAccounts()
        }
        self.confirmImportLocalAccountsHandler = confirmImportLocalAccountsHandler
        self.sessionState = RemoteAdminSessionState(
            hostID: host.id,
            remoteEndpoint: "\(host.host):\(host.adminPort)",
            configuredAdminPort: host.adminPort,
            effectiveAdminPort: host.adminPort
        )

        let tunnelController = self.tunnelController
        let remoteAdmin = admin ?? AdminAPIClient(
            target: .remote(
                .init(
                    adminBaseURLProvider: {
                        let state = try await tunnelController.ensureConnected()
                        guard let adminBaseURL = state.adminBaseURL else {
                            throw ProxyError.message("Remote admin tunnel is unavailable.")
                        }
                        return adminBaseURL
                    },
                    tokenProvider: {
                        try await tunnelController.currentToken()
                    },
                    reconnectHandler: {
                        _ = try await tunnelController.reconnect()
                    },
                    capabilities: AdminAPIClient.Capabilities.remoteTunnel
                )
            ),
            managedProxyLogsHandler: {
                try await tunnelController.loadManagedProxyLogs(lines: 120)
            }
        )

        let remoteDaemon = Self.makeRemoteDaemon(
            hostState: self.hostState,
            remoteDeploy: remoteDeploy
        )

        self.appModel = DesktopAppModel(
            admin: remoteAdmin,
            daemon: remoteDaemon,
            remoteDeploy: remoteDeploy
        )
        self.appModel.remoteAccessibleHostOverride = host.host
        self.appModel.selectedOverviewTab = .runtime
        self.appModel.selectedProxyWorkspaceTab = .access
        self.appModel.selectedSettingsTab = .proxy
        self.appModel.resetRequestLogsSessionState()
        self.bindAppModelChanges()
        self.applyPreferences(preferences)
        self.syncAppModelPageSelection()
    }

    var hostDisplayName: String {
        let trimmed = self.host.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? self.host.host : trimmed
    }

    var remoteEndpointText: String {
        self.sessionState.remoteEndpoint
    }

    var sshEndpointText: String {
        "\(self.host.sshUser)@\(self.host.host):\(self.host.sshPort)"
    }

    var remoteAdminBindText: String {
        "127.0.0.1:\(self.sessionState.effectiveAdminPort)/admin"
    }

    var publicBaseURLText: String {
        self.appModel.openAICompatibleBaseURL
    }

    var forwardedAdminBaseURLText: String {
        self.sessionState.adminBaseURL?.absoluteString ?? self.localized(
            zh: "尚未建立",
            en: "Not connected"
        )
    }

    var tunnelStatusText: String {
        switch self.sessionState.tunnelStatus {
        case .disconnected:
            return self.localized(zh: "未连接", en: "Disconnected")
        case .connecting:
            return self.localized(zh: "连接中", en: "Connecting")
        case .connected(let localPort):
            return self.localized(zh: "已连接 :\(localPort)", en: "Connected :\(localPort)")
        case .reconnecting:
            return self.localized(zh: "重连中", en: "Reconnecting")
        case .failed:
            return self.localized(zh: "失败", en: "Failed")
        }
    }

    var tunnelStatusTone: StatusPill.Tone {
        switch self.sessionState.tunnelStatus {
        case .connected:
            return .success
        case .connecting, .reconnecting:
            return .accent
        case .failed:
            return .danger
        case .disconnected:
            return .warning
        }
    }

    var reachabilityText: String {
        switch self.sessionState.reachabilityStatus {
        case .unknown:
            return self.localized(zh: "待探测", en: "Pending")
        case .reachable:
            return self.localized(zh: "可访问", en: "Reachable")
        case .reconnecting:
            return self.localized(zh: "重连中", en: "Reconnecting")
        case .failed:
            return self.localized(zh: "不可访问", en: "Unavailable")
        }
    }

    var reachabilityTone: StatusPill.Tone {
        switch self.sessionState.reachabilityStatus {
        case .reachable:
            return .success
        case .reconnecting:
            return .accent
        case .failed:
            return .danger
        case .unknown:
            return .neutral
        }
    }

    var daemonStatusText: String {
        if self.appModel.status?.running == true {
            return self.localized(zh: "运行中", en: "Running")
        }
        if self.hasLoadedInitialContent {
            return self.localized(zh: "未运行", en: "Stopped")
        }
        return self.localized(zh: "待确认", en: "Pending")
    }

    var daemonStatusTone: StatusPill.Tone {
        if self.appModel.status?.running == true {
            return .success
        }
        if self.hasLoadedInitialContent {
            return .warning
        }
        return .neutral
    }

    var lastRefreshText: String {
        guard let lastSuccessfulRefreshAt else {
            return self.localized(zh: "尚未同步", en: "Not synced yet")
        }
        return DesktopDateTimeFormat.string(from: lastSuccessfulRefreshAt)
    }

    var accountEmptyState: (title: String, detail: String)? {
        guard self.appModel.accounts.isEmpty else { return nil }
        return (
            self.localized(zh: "远端账号池还是空的", en: "The remote account pool is still empty"),
            self.localized(
                zh: "先手动新增 API Key、导入 JSON 备份，或一键把当前桌面端本地账号池同步到这台远端主机。这个窗口不会触发本机 OAuth。",
                en: "Add a manual API key, import a JSON backup, or sync the current desktop app's local account pool to this remote host. This window does not trigger local OAuth flows."
            )
        )
    }

    var proxyEmptyState: (title: String, detail: String)? {
        guard self.appModel.configuredProxyAPIKeys.isEmpty else { return nil }
        guard self.appModel.managedProxySnapshot.subscriptionConfigured == false else { return nil }
        guard self.appModel.managedProxySnapshot.nodes.isEmpty else { return nil }
        guard self.appModel.managedProxySnapshot.listeners.isEmpty else { return nil }
        return (
            self.localized(zh: "远端代理能力还没配置", en: "Remote proxy operations are not configured yet"),
            self.localized(
                zh: "先补至少一个 proxy API key，再保存订阅地址并刷新 provider。这里管理的始终是远程代理服务自己的代理面板，不会混入本机桌面侧设置。",
                en: "Add at least one proxy API key first, then save a subscription URL and refresh the provider. This window always manages the remote proxy service's own proxy plane, not local desktop settings."
            )
        )
    }

    var statsEmptyState: (title: String, detail: String)? {
        guard self.appModel.requestLogPage.entries.isEmpty else { return nil }
        guard self.appModel.proxyAPIKeyUsageReport.entries.isEmpty else { return nil }
        guard self.appModel.stats.totalRequests == 0 else { return nil }
        guard self.appModel.requestLogsIsRefreshing == false else { return nil }
        guard self.appModel.proxyAPIKeyUsageIsRefreshing == false else { return nil }
        return (
            self.localized(zh: "这台主机还没有运维数据", en: "This host does not have operational data yet"),
            self.localized(
                zh: "当远端开始承接请求后，这里会逐步出现 summary、proxy key usage 和 request logs。你也可以先刷新日志或导出当前筛选范围留档。",
                en: "As soon as the remote host starts serving traffic, this view will fill in with summary metrics, proxy key usage, and request logs. You can also refresh logs or export the current filter scope for record keeping."
            )
        )
    }

    var requestLogsAppliedFilterSummaryText: String {
        let state = self.appModel.requestLogsAppliedFilterState
        var parts = [self.appModel.label(for: state.timePreset)]

        if let source = state.selectedClientSource {
            parts.append(self.appModel.requestLogClientSourceText(source))
        }

        let selectedModel = state.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedModel.isEmpty == false {
            parts.append(
                self.localized(
                    zh: "模型 \(selectedModel)",
                    en: "Model \(selectedModel)"
                )
            )
        }

        let selectedAccountKey = state.selectedAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedAccountKey.isEmpty == false {
            let accountTitle = self.appModel.requestLogsAccountOptions
                .first(where: { $0.accountKey == selectedAccountKey })?
                .title ?? self.localized(zh: "已筛选账号", en: "Account filtered")
            parts.append(
                self.localized(
                    zh: "账号 \(accountTitle)",
                    en: "Account \(accountTitle)"
                )
            )
        }

        let selectedAPIKey = state.selectedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedAPIKey.isEmpty == false {
            parts.append(self.localized(zh: "API Key 已筛选", en: "API key filtered"))
        }

        return parts.joined(separator: " · ")
    }

    var requestLogsExportNotes: [String] {
        var notes = [
            self.localized(
                zh: "导出只包含 \(self.hostDisplayName) 这台主机当前远端 admin 会话里的请求日志，不会混入本机数据。",
                en: "Exports include only the request logs from the current remote admin session for \(self.hostDisplayName); local data never bleeds in."
            ),
        ]

        if self.appModel.requestLogsHasPendingFilterChanges {
            notes.append(
                self.localized(
                    zh: "当前导出仍使用最近一次已应用筛选：\(self.requestLogsAppliedFilterSummaryText)。如果你刚改了筛选草稿，请先点“查询日志”。",
                    en: "Exports still use the most recently applied filters: \(self.requestLogsAppliedFilterSummaryText). If you just changed draft filters, query the logs first."
                )
            )
        } else {
            notes.append(
                self.localized(
                    zh: "当前导出会沿用已应用筛选：\(self.requestLogsAppliedFilterSummaryText)。",
                    en: "Exports currently follow the applied filter scope: \(self.requestLogsAppliedFilterSummaryText)."
                )
            )
        }

        return notes
    }

    var summaryNotice: (title: String, detail: String, tone: StatusPill.Tone)? {
        if case .failed(let detail) = self.sessionState.reachabilityStatus {
            return (
                self.localized(zh: "控制面当前不可达", en: "Control plane is unavailable"),
                detail.isEmpty
                    ? self.localized(
                        zh: "SSH 隧道或远端 admin 暂时不可用，重连后会重新读取 token 并拉回远端页面数据。",
                        en: "The SSH tunnel or remote admin is temporarily unavailable. Reconnecting will reload the token and pull the remote workspace again."
                    )
                    : detail,
                .danger
            )
        }

        let daemonError = self.trimmed(self.appModel.status?.lastError)
        if let daemonError {
            return (
                self.localized(zh: "远程代理服务需要关注", en: "Remote proxy service needs attention"),
                daemonError,
                .warning
            )
        }

        if self.hasLoadedInitialContent {
            return (
                self.localized(zh: "当前窗口只管理这一台主机", en: "This window manages only this host"),
                self.localized(
                    zh: "Overview、账号、代理和出站代理操作都经由 SSH 隧道命中远端 admin；OAuth 会按远端能力自动隐藏，但你可以把当前桌面端本地账号池一键同步到这台远端主机，Proxy Test 也可直接打开共享测试控制台。",
                    en: "Overview, accounts, proxy, and outbound proxy actions all go through the SSH tunnel to the remote admin; OAuth stays hidden for remote targets, but you can sync the current desktop app's local account pool to this host in one step, and Proxy Test still opens the shared test console."
                ),
                .accent
            )
        }

        return nil
    }

    var adminPortResolutionNotice: OperationalNotice? {
        if let adminPortSyncFeedback {
            switch adminPortSyncFeedback {
            case .synced(let configuredPort, let effectivePort):
                return self.makeNotice(
                    id: "admin-port-synced",
                    titleZH: "已按远端真实端口接管管理台",
                    titleEN: "Remote admin now follows the live port",
                    detailZH: "远端当前实际 admin 端口是 \(effectivePort)，这次会话已经改用该端口，并且本地主机配置也已从 \(configuredPort) 同步到 \(effectivePort)。",
                    detailEN: "The remote proxy service is currently listening on admin port \(effectivePort). This session already switched over, and the saved host configuration was updated from \(configuredPort) to \(effectivePort).",
                    tone: .success
                )
            case .failed(let configuredPort, let effectivePort, let detail):
                let resolvedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return self.makeNotice(
                    id: "admin-port-sync-failed",
                    titleZH: "当前会话已改用真实端口，但本地配置未保存",
                    titleEN: "This session switched ports, but the local config was not saved",
                    detailZH: "远端当前实际 admin 端口是 \(effectivePort)，这次会话已经改用该端口；但本地主机配置仍停留在 \(configuredPort)。保存失败原因：\(resolvedDetail)",
                    detailEN: "The remote proxy service is currently listening on admin port \(effectivePort), and this session already switched over; however, the saved host configuration is still pinned to \(configuredPort). Save failure: \(resolvedDetail)",
                    tone: .warning
                )
            }
        }

        guard self.sessionState.adminPortDriftDetected else { return nil }
        guard let discoveredAdminPort = self.sessionState.discoveredAdminPort else { return nil }
        return self.makeNotice(
            id: "admin-port-drift",
            titleZH: "管理台端口与本地记录不一致",
            titleEN: "The admin port drifted from local settings",
            detailZH: "本地记录的 admin 端口是 \(self.sessionState.configuredAdminPort)，远端当前实际端口是 \(discoveredAdminPort)。这次会话已经按真实端口接管。",
            detailEN: "The saved host config points at admin port \(self.sessionState.configuredAdminPort), while the remote proxy service is currently listening on \(discoveredAdminPort). This session already switched to the live port.",
            tone: .accent
        )
    }

    var contentIsBlocked: Bool {
        switch self.sessionState.reachabilityStatus {
        case .reachable:
            return false
        case .unknown, .reconnecting, .failed:
            return true
        }
    }

    func title(for page: Page) -> String {
        switch page {
        case .overview:
            return self.appModel.pageTitle(.overview)
        case .accounts:
            return self.appModel.pageTitle(.accounts)
        case .proxy:
            return self.appModel.pageTitle(.proxy)
        case .outboundProxy:
            return self.appModel.outboundProxyPageTitle
        }
    }

    func subtitle(for page: Page) -> String {
        switch page {
        case .overview:
            return self.appModel.pageSubtitle(.overview)
        case .accounts:
            return self.appModel.pageSubtitle(.accounts)
        case .proxy:
            return self.appModel.pageSubtitle(.proxy)
        case .outboundProxy:
            return self.appModel.outboundProxyPageSubtitle
        }
    }

    func selectPage(_ page: Page) {
        guard self.selectedPage != page else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            self.selectedPage = page
        }
    }

    func activate() {
        guard self.hasLoadedInitialContent == false else { return }
        Task { await self.refresh(forceReconnect: false) }
    }

    func refresh(forceReconnect: Bool = false) async {
        guard self.isRefreshing == false else { return }

        self.isRefreshing = true
        self.sessionState.tunnelStatus = forceReconnect ? .reconnecting : .connecting
        self.sessionState.reachabilityStatus = forceReconnect ? .reconnecting : .unknown
        defer { self.isRefreshing = false }

        do {
            if forceReconnect {
                self.sessionState = try await self.tunnelController.reconnect()
            } else {
                self.sessionState = try await self.tunnelController.ensureConnected()
            }
            await self.handleAdminPortDriftIfNeeded(for: self.sessionState)

            await self.appModel.loadAll()

            await self.tunnelController.updateReachability(.reachable)
            self.sessionState = await self.tunnelController.snapshot()
            self.hasLoadedInitialContent = true
            self.lastSuccessfulRefreshAt = Date()
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            await self.tunnelController.updateReachability(.failed(detail))
            self.sessionState = await self.tunnelController.snapshot()
        }
    }

    func reconnect() async {
        await self.refresh(forceReconnect: true)
    }

    func importLocalAccountsToRemote() async {
        guard self.appModel.isBusy == false else { return }

        self.appModel.isBusy = true
        defer { self.appModel.isBusy = false }

        do {
            let exported = try await self.localAccountsExportHandler()
            let accountCount = try self.exportedLocalAccountCount(from: exported)
            guard accountCount > 0 else {
                self.appModel.publishBanner(
                    .warning,
                    title: self.localized(zh: "本地还没有可导入的账号", en: "There are no local accounts to import yet"),
                    detail: self.localized(
                        zh: "先在桌面端本地账号池里导入至少一个账号，再把它同步到远端。",
                        en: "Import at least one account into the desktop app's local account pool before syncing to the remote host."
                    )
                )
                return
            }

            let confirmation = self.localAccountsImportConfirmationContent(accountCount: accountCount)
            guard self.confirmImportLocalAccounts(confirmation) else { return }

            let result = try await self.appModel.admin.importAuthJSONItems([
                AuthJsonImportInput(
                    source: "local-desktop-accounts.json",
                    content: String(decoding: exported, as: UTF8.self)
                )
            ])
            try await self.appModel.reloadAccountState()

            if result.failures.isEmpty {
                self.appModel.publishSuccess(
                    .importLocalAccountsToRemote,
                    detail: self.importLocalAccountsResultDetail(result, includeFailure: false)
                )
            } else {
                self.appModel.publishBanner(
                    .warning,
                    title: self.localized(
                        zh: "本地账号已同步到远端，但有部分失败",
                        en: "Local accounts were synced to the remote host with some failures"
                    ),
                    detail: self.importLocalAccountsResultDetail(result, includeFailure: true)
                )
            }
        } catch {
            self.appModel.present(error: error, context: .importLocalAccountsToRemote)
        }
    }

    func applyPreferences(_ preferences: DesktopPreferences) {
        self.appModel.preferences = self.windowPreferences(from: preferences)
    }

    func close() async {
        await self.tunnelController.close()
    }

    func localized(zh: String, en: String) -> String {
        self.appModel.localized(zh: zh, en: en)
    }

    private func syncAppModelPageSelection() {
        switch self.selectedPage {
        case .overview:
            self.appModel.selectedPage = .overview
        case .accounts:
            self.appModel.selectedPage = .accounts
        case .proxy:
            self.appModel.selectedPage = .proxy
        case .outboundProxy:
            self.appModel.selectedSettingsTab = .proxy
            self.appModel.selectedPage = .settings
        }
    }

    private func bindAppModelChanges() {
        self.appModelChangeCancellable = self.appModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func localAccountsImportConfirmationContent(accountCount: Int) -> LocalAccountsImportConfirmationContent {
        let hostName = self.hostDisplayName
        return LocalAccountsImportConfirmationContent(
            title: self.appModel.text(.confirmImportLocalAccountsToRemoteTitle),
            informativeText: self.localized(
                zh: "即将把当前桌面端本地账号池里的 \(accountCount) 个账号导入到远程主机 `\(hostName)`。如果远端已存在相同账号，会仅更新授权信息，并保留远端已有的启停状态、调用顺序和账号级策略。",
                en: "This will import \(accountCount) account\(accountCount == 1 ? "" : "s") from the current desktop app's local account pool to the remote host `\(hostName)`. When the remote host already has the same account, only the authorization is refreshed while the remote enabled state, routing order, and account-level policies stay unchanged."
            ),
            actionTitle: self.appModel.text(.confirmImportLocalAccountsToRemoteAction)
        )
    }

    private func confirmImportLocalAccounts(_ content: LocalAccountsImportConfirmationContent) -> Bool {
        if let confirmImportLocalAccountsHandler {
            return confirmImportLocalAccountsHandler(content)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.appModel.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func exportedLocalAccountCount(from data: Data) throws -> Int {
        let json = try JSONSerialization.jsonObject(with: data)
        if let object = json as? [String: Any], let accounts = object["accounts"] as? [Any] {
            return accounts.count
        }
        if let array = json as? [Any] {
            return array.count
        }
        return 0
    }

    private func importLocalAccountsResultDetail(_ result: ImportAccountsResult, includeFailure: Bool) -> String {
        let base = self.localized(
            zh: "新增 \(result.importedCount) 个，更新 \(result.updatedCount) 个，失败 \(result.failures.count) 个。",
            en: "Imported \(result.importedCount), updated \(result.updatedCount), failed \(result.failures.count)."
        )
        guard includeFailure, let firstFailure = result.failures.first else {
            return base
        }
        let source = firstFailure.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty {
            return base + " " + self.localized(zh: "首个失败：\(firstFailure.error)", en: "First failure: \(firstFailure.error)")
        }
        return base + " " + self.localized(
            zh: "首个失败：\(source) - \(firstFailure.error)",
            en: "First failure: \(source) - \(firstFailure.error)"
        )
    }

    private func windowPreferences(from preferences: DesktopPreferences) -> DesktopPreferences {
        var resolved = preferences
        resolved.interfaceMode = .full
        return resolved
    }

    private func makeNotice(
        id: String,
        titleZH: String,
        titleEN: String,
        detailZH: String,
        detailEN: String,
        tone: StatusPill.Tone
    ) -> OperationalNotice {
        OperationalNotice(
            id: id,
            title: self.localized(zh: titleZH, en: titleEN),
            detail: self.localized(zh: detailZH, en: detailEN),
            tone: tone
        )
    }

    private func handleAdminPortDriftIfNeeded(for state: RemoteAdminSessionState) async {
        guard state.adminPortDriftDetected, let discoveredAdminPort = state.discoveredAdminPort else {
            self.adminPortSyncFeedback = nil
            return
        }

        self.adminPortSyncFeedback = nil
        guard let discoveredAdminPortHandler else { return }

        switch await discoveredAdminPortHandler(discoveredAdminPort) {
        case .alreadyCurrent(let syncedPort), .synced(let syncedPort):
            self.host.adminPort = syncedPort
            self.hostState.host.adminPort = syncedPort
            await self.tunnelController.updateConfiguredAdminPort(syncedPort)
            self.sessionState = await self.tunnelController.snapshot()
            self.adminPortSyncFeedback = .synced(
                configuredPort: state.configuredAdminPort,
                effectivePort: discoveredAdminPort
            )
        case .failed(let detail):
            self.adminPortSyncFeedback = .failed(
                configuredPort: state.configuredAdminPort,
                effectivePort: discoveredAdminPort,
                detail: detail
            )
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeRemoteDaemon(
        hostState: RemoteHostRuntimeState,
        remoteDeploy: any RemoteDeploying
    ) -> LocalDaemonController {
        LocalDaemonController(
            prepareForLaunchHandler: { _ in },
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            startHandler: { config in
                _ = config
                hostState.lastStatus = try await remoteDeploy.start(host: hostState.host)
            },
            stopHandler: {
                hostState.lastStatus = try await remoteDeploy.stop(host: hostState.host)
            },
            statusHandler: {
                do {
                    let status = try await remoteDeploy.status(host: hostState.host)
                    hostState.lastStatus = status
                    return Self.makeRemoteLocalServiceStatus(from: status, host: hostState.host)
                } catch {
                    if let cachedStatus = hostState.lastStatus {
                        return Self.makeRemoteLocalServiceStatus(
                            from: cachedStatus,
                            host: hostState.host,
                            error: error.localizedDescription
                        )
                    }
                    return Self.makeRemoteLocalServiceStatusForFailure(
                        host: hostState.host,
                        error: error.localizedDescription
                    )
                }
            }
        )
    }

    private static func makeRemoteLocalServiceStatus(
        from status: RemoteDeployStatus,
        host: RemoteHostConfig,
        error: String? = nil
    ) -> LocalServiceStatus {
        let unitName = "codex-proxy-\(host.id).service"
        let launchctlState: String
        if status.running {
            launchctlState = "running"
        } else if status.installed == false {
            launchctlState = "not_installed"
        } else if status.enabled {
            launchctlState = "registered"
        } else {
            launchctlState = "not_registered"
        }

        return LocalServiceStatus(
            installed: status.installed,
            running: status.running,
            launchctlState: launchctlState,
            stdoutPath: "journalctl -u \(unitName)",
            stderrPath: "journalctl -u \(unitName)",
            lastErrorSummary: error ?? status.lastError
        )
    }

    private static func makeRemoteLocalServiceStatusForFailure(
        host: RemoteHostConfig,
        error: String
    ) -> LocalServiceStatus {
        let unitName = "codex-proxy-\(host.id).service"
        return LocalServiceStatus(
            installed: true,
            running: false,
            launchctlState: "unknown",
            stdoutPath: "journalctl -u \(unitName)",
            stderrPath: "journalctl -u \(unitName)",
            lastErrorSummary: error
        )
    }
}
#endif
