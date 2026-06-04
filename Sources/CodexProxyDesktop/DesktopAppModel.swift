#if os(macOS)
import AppKit
import CodexProxyCore
import CodexProxyDeploy
import Foundation
import SwiftUI

enum RemoteAdminPortSyncResult: Sendable, Equatable {
    case alreadyCurrent(adminPort: Int)
    case synced(adminPort: Int)
    case failed(String)
}

enum RemoteDeployActionMode: Equatable {
    case deploy
    case redeploy
}

typealias RemoteAdminDiscoveredPortHandler = @Sendable (Int) async -> RemoteAdminPortSyncResult

@MainActor
final class DesktopAppModel: ObservableObject {
    struct MenuBarTokenUsagePresentation: Equatable {
        let primaryLine: String
        let secondaryLine: String
        let toolTip: String
        let accessibilityLabel: String
    }

    typealias ConfirmStopDaemonHandler = () -> Bool
    typealias ConfirmClearAccountManagedProxyNodesHandler = () -> Bool
    typealias ConfirmStopAccountCooldownHandler = (AccountCooldownStopConfirmationContent) -> Bool
    typealias ConfirmBatchRemoveAccountsHandler = (BatchRemoveAccountsConfirmationContent) -> Bool
    typealias ConfirmClearReasoningCacheHandler = (ReasoningCacheClearConfirmationContent) -> Bool
    typealias ConfirmClearOCRCacheHandler = (OCRCacheClearConfirmationContent) -> Bool
    typealias ConfirmClearDiagnosticRequestBodiesHandler = (DiagnosticRequestBodyClearConfirmationContent) -> Bool
    typealias ConfirmInterfaceModeSwitchHandler = (DesktopInterfaceMode) -> Bool
    typealias ConfirmDeleteRemoteHostHandler = (RemoteHostConfig) -> Bool
    typealias ConfirmInstallUpdateHandler = (AppUpdatePackage) -> AppUpdatePromptDecision
    typealias ImportAuthFileSelectionHandler = () -> [URL]?
    typealias ImportAuthFileReader = (URL) throws -> String
    typealias ProxyTestImageEditFileSelectionHandler = () -> [URL]?
    typealias ProxyTestImageSavePanelHandler = @MainActor (ProxyTestImageSavePanelRequest) -> URL?
    typealias ProxyTestImageDownloadHandler = @Sendable (URL) async throws -> ProxyTestDownloadedImage
    typealias ProxyTestImageFileWriter = (Data, URL) throws -> Void
    typealias ProxyTestImageFilenameTokenProvider = () -> String
    typealias ClientConfigManagerWindowFactory = (DesktopAppModel) -> ClientConfigManagerWindowControlling
    typealias CodexProjectRoutesWindowFactory = (DesktopAppModel) -> CodexProjectRoutesWindowControlling
    typealias OCRCacheLogsWindowFactory = (DesktopAppModel) -> OCRCacheLogsWindowControlling
    typealias OCRModelManagerWindowFactory = (DesktopAppModel) -> OCRModelManagerWindowControlling
    typealias OCRModelTestImageSelectionHandler = @MainActor () throws -> OCRModelTestImageSelection?
    typealias RemoteAdminWindowFactory = (
        RemoteHostConfig,
        DesktopPreferences,
        any RemoteDeploying,
        @escaping @Sendable () -> Void,
        @escaping RemoteAdminDiscoveredPortHandler
    ) -> RemoteAdminWindowControlling

    enum Page: String, CaseIterable, Identifiable {
        case overview
        case accounts
        case proxy
        case remote
        case clientConfig
        case settings

        var id: String { self.rawValue }

        var symbolName: String {
            switch self {
            case .overview:
                return "square.grid.2x2.fill"
            case .accounts:
                return "person.2.crop.square.stack.fill"
            case .proxy:
                return "bolt.horizontal.circle.fill"
            case .remote:
                return "server.rack"
            case .settings:
                return "slider.horizontal.3"
            case .clientConfig:
                return "gearshape.2.fill"
            }
        }
    }

    struct BannerState: Identifiable, Equatable {
        enum Tone: Equatable {
            case success
            case info
            case warning
            case error
        }

        let id = UUID()
        var tone: Tone
        var title: String
        var detail: String?
    }

    struct StopDaemonConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var warningText: String?
    }

    struct ClearAccountManagedProxyNodesConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct AccountCooldownStopConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct BatchRemoveAccountsConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct ReasoningCacheClearConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct OCRCacheClearConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct DiagnosticRequestBodyClearConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct InterfaceModeSwitchConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct DeleteRemoteHostConfirmationContent: Equatable {
        var title: String
        var informativeText: String
        var actionTitle: String
    }

    struct OAuthDraft: Identifiable, Equatable {
        let id = UUID()
        var providerFamily: AccountProviderFamily
        var prepared: PreparedOAuthLogin
        var callbackURL = ""
        var expectedAuthMode: AccountAuthMode
        var baselineUpdatedAtByAccountKey: [String: Int64]
    }

    struct ManualAPIKeyDraft: Identifiable, Equatable {
        let id = UUID()
        var label = ""
        var providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible
        var baseURL = OpenAICompatibleProviderPreset.genericOpenAICompatible.defaultBaseURL
        var upstreamAdapter: ManualAPIKeyUpstreamAdapter = .responses
        var chatCompatibilityProfile: ChatCompletionsCompatibilityProfile = .auto
        var apiKey = ""
        var enabled = true
        var automaticCooldownDisabled = false
        var supportsVision = false
        var editingAccountID: String?
        var originalAccountKey: String?

        var isEditing: Bool {
            self.editingAccountID != nil
        }
    }

    enum AuthImportMode: String, CaseIterable, Identifiable {
        case paste
        case chatGPTWebSession
        case file

        var id: String { self.rawValue }
    }

    struct AuthImportDraft: Identifiable, Equatable {
        let id = UUID()
        var mode: AuthImportMode = .paste
        var pastedJSON = ""
        var chatGPTWebSessionJSON = ""
    }

    struct AccountLabelDraft: Identifiable, Equatable {
        let id = UUID()
        var accountID: String
        var accountKey: String
        var label: String
    }

    struct AccountOrderDraft: Identifiable, Equatable {
        let id = UUID()
        var accounts: [AccountSummary]
        var searchQuery = ""
    }

    struct AccountOrderVisibleEntry: Identifiable, Equatable {
        var position: Int
        var account: AccountSummary

        var id: String { self.account.id }
    }

    struct AccountManagedProxyNodeDraft: Identifiable, Equatable {
        let id = UUID()
        var accountID: String
        var accountKey: String
        var label: String
        var managedProxyNodeName: String?
    }

    struct AccountModelRoutingDraft: Identifiable, Equatable {
        let id = UUID()
        var accountID: String
        var accountKey: String
        var label: String
        var defaultTargetModel: String
        var mappings: [AccountModelMapping]
    }

    struct AccountReasoningEffortDraft: Identifiable, Equatable {
        let id = UUID()
        var accountID: String
        var accountKey: String
        var label: String
        var low: String
        var medium: String
        var high: String
        var xhigh: String
    }

    enum AccountCardEditActionKind: Equatable {
        case rename
        case editAPIKey
    }

    enum OnboardingStep: Int, CaseIterable, Identifiable {
        case accountPool
        case outboundProxy
        case clientAccess
        case completion

        var id: Int { self.rawValue }
    }

    enum RemoteWorkflowStep: Int, CaseIterable, Identifiable {
        case hosts
        case configuration
        case verification
        case operations

        var id: Int { self.rawValue }
    }

    enum OnboardingProxyChoice: String, CaseIterable, Equatable {
        case direct
        case manual
    }

    struct OnboardingProxyDraft: Equatable {
        var choice: OnboardingProxyChoice
        var scheme: OutboundProxyScheme
        var host: String
        var port: Int
        var username: String
        var password: String

        init(
            choice: OnboardingProxyChoice = .direct,
            scheme: OutboundProxyScheme = .http,
            host: String = "",
            port: Int = 0,
            username: String = "",
            password: String = ""
        ) {
            self.choice = choice
            self.scheme = scheme
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    enum MinimalProxyChoice: String, CaseIterable, Equatable {
        case direct
        case manual
    }

    struct MinimalProxyDraft: Equatable {
        var choice: MinimalProxyChoice
        var scheme: OutboundProxyScheme
        var host: String
        var port: Int
        var username: String
        var password: String

        init(
            choice: MinimalProxyChoice = .direct,
            scheme: OutboundProxyScheme = .http,
            host: String = "",
            port: Int = 0,
            username: String = "",
            password: String = ""
        ) {
            self.choice = choice
            self.scheme = scheme
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    struct SettingsOutboundProxyDraft: Equatable {
        var mode: OutboundProxyMode
        var outboundProxy: OutboundProxySettings

        init(
            mode: OutboundProxyMode = .disabled,
            outboundProxy: OutboundProxySettings = .init()
        ) {
            self.mode = mode
            self.outboundProxy = outboundProxy
        }
    }

    enum FullModeNavigationDestination: Equatable {
        case page(Page)
        case proxyAccess
        case settingsProxy
    }

    struct SidebarBrandSummary {
        let brandName: String
        let brandSubtitle: String
        let serviceText: String
        let serviceTone: StatusPill.Tone
        let accountCountText: String
        let requestCountText: String
        let versionText: String
    }

    struct AccountUsageTileDescriptor: Identifiable, Equatable {
        let id: String
        let title: String
        let value: String
        let subtitle: String?
        let helpText: String?
        let tone: StatusPill.Tone
        let symbol: String

        init(
            id: String,
            title: String,
            value: String,
            subtitle: String? = nil,
            helpText: String? = nil,
            tone: StatusPill.Tone,
            symbol: String
        ) {
            self.id = id
            self.title = title
            self.value = value
            self.subtitle = subtitle
            self.helpText = helpText
            self.tone = tone
            self.symbol = symbol
        }
    }

    @Published var selectedPage: Page = .overview {
        didSet {
            self.syncAccountPoolDetailDrawerContext()
            if self.selectedPage == .clientConfig {
                self.enterClientConfigPageIfNeeded()
            }
        }
    }
    @Published private(set) var isRemoteManagementUnlocked = false
    @Published var selectedProxyWorkspaceTab: ProxyWorkspaceTab = .access
    @Published var selectedOverviewTab: OverviewTab = .runtime
    @Published var selectedOverviewTrafficWeekOffset = 0
    @Published var selectedOverviewTrafficAPIKeyID: String?
    @Published var status: ProxyStatus?
    @Published var localServiceStatus: LocalServiceStatus?
    @Published var accounts: [AccountSummary] = [] {
        didSet {
            self.clearAccountPoolSelectionIfNeeded()
            self.pruneBatchRemoveAccountSelection()
        }
    }
    @Published var selectedAccountPoolAccountID: String?
    @Published var isAccountPoolDetailDrawerPresented = false
    @Published var isAccountBatchRemoveModeEnabled = false
    @Published var selectedBatchRemoveAccountIDs = Set<String>()
    @Published var isBatchRemovingAccounts = false
    @Published var accountPoolFilters = AccountPoolFilterState() {
        didSet {
            self.clearAccountPoolSelectionIfNeeded()
        }
    }
    @Published var settings = AppConfig()
    @Published var preferences: DesktopPreferences {
        didSet {
            self.clearAccountPoolSelectionIfNeeded()
            self.syncAccountPoolDetailDrawerContext()
        }
    }
    @Published private(set) var systemColorScheme: ColorScheme = .light
    @Published var stats = AdminStatsSummary(
        totalRequests: 0,
        totalFailures: 0,
        totalAuthFailures: 0,
        totalRateLimits: 0,
        totalQuotaFailures: 0,
        totalInputTokens: 0,
        totalOutputTokens: 0,
        totalTokens: 0,
        latestBuckets: []
    )
    @Published var selectedRemoteWorkflowStep: RemoteWorkflowStep = .hosts {
        didSet {
            self.handleSelectedRemoteWorkflowStepChange(from: oldValue, to: self.selectedRemoteWorkflowStep)
        }
    }
    @Published var remoteStatuses: [String: RemoteDeployStatus] = [:]
    @Published var remoteConnectionChecksByHostID: [String: RemoteConnectionCheck] = [:]
    @Published var remoteConnectionErrorsByHostID: [String: String] = [:]
    @Published var selectedRemoteHost = RemoteHostConfig() {
        didSet {
            self.handleSelectedRemoteHostChange(from: oldValue, to: self.selectedRemoteHost)
        }
    }
    @Published var remoteLogsByHostID: [String: String] = [:]
    @Published var localDaemonLogs = ""
    @Published var managedProxySnapshot = ManagedProxySnapshot()
    @Published var managedProxySubscriptionURLDraft = ""
    @Published var managedProxyHealthcheckURLDraft = ManagedProxyConfigSummary.defaultHealthcheckURL
    @Published var managedProxyNodeSearchQuery = ""
    @Published var isManagedProxyNodesDrawerPresented = false
    @Published var managedProxyFocusedNodeName: String?
    @Published var managedProxyHealthcheckFeedback: ManagedProxyHealthcheckFeedback?
    @Published var managedProxyNodeHealthcheckDisplayStates: [String: ManagedProxyNodeHealthcheckDisplayState] = [:]
    @Published var managedProxyWebsiteProbeResults: [ManagedProxyWebsiteProbeTarget: ManagedProxyWebsiteProbeResult] = [:]
    @Published var managedProxyWebsiteProbeRunningTargets: Set<ManagedProxyWebsiteProbeTarget> = []
    @Published var managedProxyWebsiteProbeLastBatchTestedAt: Date?
    @Published var managedProxyLogs = ""
    @Published var isManagedProxyLogsExpanded = false
    @Published var banners: [BannerState] = []
    @Published var isBusy = false
    @Published private(set) var isKeepAwakeEnabled = false
    @Published var localServiceOperation: LocalServiceOperation = .idle
    @Published var remoteOperation: RemoteOperation = .idle
    @Published var managedProxyOperation: ManagedProxyOperation = .idle
    @Published var remoteServiceLoadErrors: [String: String] = [:]
    @Published var oauthDraft: OAuthDraft?
    @Published var manualAPIKeyDraft: ManualAPIKeyDraft?
    @Published var authImportDraft: AuthImportDraft?
    @Published var accountLabelDraft: AccountLabelDraft?
    @Published var accountOrderDraft: AccountOrderDraft?
    @Published var accountManagedProxyNodeDraft: AccountManagedProxyNodeDraft?
    @Published var accountModelRoutingDraft: AccountModelRoutingDraft?
    @Published var accountReasoningEffortDraft: AccountReasoningEffortDraft?
    @Published var proxyAPIKeyDraft: ProxyAPIKeyDraft?
    @Published var manualAPIKeyIsSubmitting = false
    @Published var authImportIsSubmitting = false
    @Published var accountLabelIsSubmitting = false
    @Published var accountOrderIsSubmitting = false
    @Published var accountManagedProxyNodeIsSubmitting = false
    @Published var accountModelRoutingIsSubmitting = false
    @Published var accountReasoningEffortIsSubmitting = false
    @Published var refreshingAccountIDs: Set<String> = []
    @Published var isRefreshingAccountList = false
    @Published var isProxyTestPresented = false
    @Published var proxyTestDraft = ProxyTestDraft()
    @Published var proxyTestModelCatalog = ProxyTestModelCatalog.defaultCatalog
    @Published var proxyTestAvailableModels: [String] = ProxyTestModelCatalog.defaultCatalog.chatCompletions.models
    @Published var proxyTestRunState: ProxyTestRunState = .idle
    @Published var proxyTestResult: ProxyTestResult?
    @Published var proxyTestBanners: [BannerState] = []
    @Published var proxyTestConnectionHealthy = false
    @Published var isHelpPresented = false
    @Published var isOnboardingPresented = false
    @Published var onboardingStep: OnboardingStep = .accountPool
    @Published var onboardingManualAPIKeyDraft: ManualAPIKeyDraft?
    @Published var onboardingProxyDraft = OnboardingProxyDraft()
    @Published var minimalManualAPIKeyDraft: ManualAPIKeyDraft?
    @Published var minimalProxyDraft = MinimalProxyDraft()
    @Published var settingsOutboundProxyDraft = SettingsOutboundProxyDraft()
    @Published var selectedSettingsTab: SettingsTab = .appearance
    @Published var isManagedProxyManagerPresented = false
    @Published var isClientConfigManagerPresented = false
    @Published var clientConfigManagerState = ClientConfigManagerState()
    @Published var codexProjectRouteDraft: CodexProjectRouteDraft?
    @Published var isRequestLogsPresented = false
    @Published var requestLogsDraftFilterState = RequestLogFilterState()
    @Published var requestLogsAppliedFilterState = RequestLogFilterState()
    @Published var requestLogPage = RequestLogPage()
    @Published var requestLogFilterOptions = RequestLogFilterOptions()
    @Published var requestLogsIsRefreshing = false
    @Published var requestLogsIsExporting = false
    @Published var requestLogsBanners: [BannerState] = []
    @Published var requestLogsLastRefreshedAt: Date?
    @Published var reasoningCacheSummary = ReasoningCacheSummary()
    @Published var reasoningCacheIsRefreshing = false
    @Published var reasoningCacheIsClearing = false
    @Published var reasoningCacheSelectedAccountKey = ""
    @Published var reasoningCacheOlderThanSeconds: Int64 = 604_800
    @Published var ocrCacheSummary = OCRCacheSummary()
    @Published var ocrCacheIsRefreshing = false
    @Published var ocrCacheIsClearing = false
    @Published var ocrCacheOlderThanSeconds: Int64 = 604_800
    @Published var ocrRecognitionLogPage = OCRRecognitionLogListResponse()
    @Published var ocrRecognitionLogStatusFilter: OCRRecognitionLogStatus?
    @Published var ocrRecognitionLogsIsRefreshing = false
    @Published var ocrRecognitionResultIsLoading = false
    @Published var ocrRecognitionResult: OCRRecognitionResultLookupResponse?
    @Published var ocrRecognitionLogSummary = OCRRecognitionLogSummary()
    @Published var ocrRecognitionLogOlderThanSeconds: Int64 = 604_800
    @Published var ocrRecognitionLogIsClearing = false
    @Published var isCodexProjectRoutesPresented = false
    @Published var isOCRCacheLogsPresented = false
    @Published var isOCRModelManagerPresented = false
    @Published var isOCRRecognitionResultPresented = false
    @Published var localOCRModelsResponse = LocalOCRModelsResponse()
    @Published var localOCRModelsIsRefreshing = false
    @Published var localOCRModelOperationIDs: Set<String> = []
    @Published var localOCRRuntimeIsStopping = false
    var localOCRModelProgressRefreshTask: Task<Void, Never>?
    @Published var ocrModelTestDraft: OCRModelTestDraft?
    @Published var diagnosticRequestBodySummary = DiagnosticRequestBodySummary()
    @Published var diagnosticRequestBodyIsRefreshing = false
    @Published var diagnosticRequestBodyIsClearing = false
    @Published var diagnosticRequestBodyOlderThanSeconds: Int64 = 604_800
    @Published var diagnosticRequestBodyDetail: DiagnosticRequestBodyDetail?
    @Published var diagnosticRequestBodyDetailIsLoading = false
    @Published var isDiagnosticRequestBodyPresented = false
    @Published var proxyAPIKeyUsageFilter = ProxyAPIKeyUsageFilter()
    @Published var proxyAPIKeyUsageReport = ProxyAPIKeyUsageReport(from: 0, to: 0)
    @Published var proxyAPIKeyUsageIsRefreshing = false
    @Published var isProxyUsageRangePickerPresented = false
    @Published var appUpdateStatus: AppUpdateStatus = .idle

    let admin: AdminAPIClient
    let daemon: LocalDaemonController
    let remoteDeploy: any RemoteDeploying
    let publicProxyClient: ProxyPublicAPIClient
    let managedProxyWebsiteProbeClient: ManagedProxyWebsiteProbeClient
    let clientConfigFileService: ClientConfigFileService
    private let preferencesStore: DesktopPreferencesStore
    private let keepAwakeController: any DesktopKeepAwakeControlling
    private let confirmStopDaemonHandler: ConfirmStopDaemonHandler?
    private let confirmClearAccountManagedProxyNodesHandler: ConfirmClearAccountManagedProxyNodesHandler?
    private let confirmStopAccountCooldownHandler: ConfirmStopAccountCooldownHandler?
    private let confirmBatchRemoveAccountsHandler: ConfirmBatchRemoveAccountsHandler?
    let confirmClearReasoningCacheHandler: ConfirmClearReasoningCacheHandler?
    let confirmClearOCRCacheHandler: ConfirmClearOCRCacheHandler?
    let confirmClearDiagnosticRequestBodiesHandler: ConfirmClearDiagnosticRequestBodiesHandler?
    private let confirmInterfaceModeSwitchHandler: ConfirmInterfaceModeSwitchHandler?
    private let confirmDeleteRemoteHostHandler: ConfirmDeleteRemoteHostHandler?
    let confirmInstallUpdateHandler: ConfirmInstallUpdateHandler?
    private let importAuthFileSelectionHandler: ImportAuthFileSelectionHandler?
    private let importAuthFileReader: ImportAuthFileReader
    let proxyTestImageEditFileSelectionHandler: ProxyTestImageEditFileSelectionHandler?
    let proxyTestImageSavePanelHandler: ProxyTestImageSavePanelHandler
    let proxyTestImageDownloadHandler: ProxyTestImageDownloadHandler
    let proxyTestImageFileWriter: ProxyTestImageFileWriter
    let proxyTestImageFilenameTokenProvider: ProxyTestImageFilenameTokenProvider
    let ocrModelTestImageSelectionHandler: OCRModelTestImageSelectionHandler
    let appUpdateService: any AppUpdateServicing
    let appUpdateInstaller: any AppUpdateInstalling
    var appUpdateCurrentAppURLProvider: () -> URL?
    let appUpdateTerminateHandler: () -> Void
    let clientConfigManagerWindowFactory: ClientConfigManagerWindowFactory
    let codexProjectRoutesWindowFactory: CodexProjectRoutesWindowFactory
    let ocrCacheLogsWindowFactory: OCRCacheLogsWindowFactory
    let ocrModelManagerWindowFactory: OCRModelManagerWindowFactory
    private let remoteAdminWindowFactory: RemoteAdminWindowFactory
    let aboutWindowFactory: (DesktopAppModel) -> AboutWindowControlling
    let helpWindowFactory: (DesktopAppModel) -> HelpWindowControlling
    let onboardingWindowFactory: (DesktopAppModel) -> OnboardingWindowControlling
    private var oauthObservationTask: Task<Void, Never>?
    var toastAutoDismissDuration: Duration = .seconds(3.5)
    var proxyTestTask: Task<Void, Never>?
    var proxyTestModelCatalogTask: Task<Void, Never>?
    var aboutWindowController: AboutWindowControlling?
    var helpWindowController: HelpWindowControlling?
    var onboardingWindowController: OnboardingWindowControlling?
    var proxyTestWindowController: ProxyTestWindowController?
    var managedProxyWindowController: ManagedProxyWindowController?
    var clientConfigManagerWindowController: ClientConfigManagerWindowControlling?
    var codexProjectRoutesWindowController: CodexProjectRoutesWindowControlling?
    var ocrCacheLogsWindowController: OCRCacheLogsWindowControlling?
    var ocrModelManagerWindowController: OCRModelManagerWindowControlling?
    var clientConfigManagerRefreshGeneration = 0
    var clientConfigManagerBackupLoadGeneration = 0
    var requestLogsWindowController: RequestLogsWindowController?
    var assistantWindowController: AssistantWindowControlling?
    var remoteAdminWindowControllers: [String: RemoteAdminWindowControlling] = [:]
    var requestLogsRefreshTask: Task<Void, Never>?
    var requestLogsRefreshGeneration: UInt64 = 0
    var manualAPIKeyEditLoadGeneration: UInt64 = 0
    var requestLogsNowProvider: () -> Date = { Date() }
    var statsAutoRefreshInterval: Duration = .seconds(30)
    private var statsAutoRefreshTask: Task<Void, Never>?
    private var statsAutoRefreshGeneration: UInt64 = 0
    var adminEventStatsRefreshDebounce: Duration = .milliseconds(250)
    var adminEventReconnectInitialDelaySeconds: Int64 = 1
    var adminEventReconnectMaxDelaySeconds: Int64 = 30
    private var adminEventStreamTask: Task<Void, Never>?
    private var adminEventStatsRefreshTask: Task<Void, Never>?
    private var adminEventStreamGeneration: UInt64 = 0
    private var hasPreparedMinimalProxyDraft = false
    private var syncedMinimalProxyDraft = MinimalProxyDraft()
    private var hasPreparedSettingsOutboundProxyDraft = false
    private var syncedSettingsOutboundProxyDraft = SettingsOutboundProxyDraft()
    private var remoteManagementRevealTapCount = 0
    private var remoteManagementLastTapAt: Date?
    var managedProxyWebsiteProbeGeneration: UInt64 = 0
    var remoteAccessibleHostOverride: String?
    private let remoteManagementRevealResetInterval: TimeInterval = 1.5
    private var suppressSelectedRemoteHostChangeSideEffects = false
    private var remoteWorkflowAutomationTask: Task<Void, Never>?
    var appUpdateTask: Task<Void, Never>?
    var appUpdateNowProvider: () -> Date = { Date() }
    var appUpdateAutoCheckInterval: TimeInterval = 24 * 60 * 60
    private nonisolated static let autoStartReadinessPollInterval: Duration = .milliseconds(500)
    private nonisolated static let autoStartReadinessPollAttempts = 20

    init(
        admin: AdminAPIClient = AdminAPIClient(),
        daemon: LocalDaemonController = LocalDaemonController(),
        remoteDeploy: any RemoteDeploying = RemoteDeployService(),
        publicProxyClient: ProxyPublicAPIClient = ProxyPublicAPIClient(),
        managedProxyWebsiteProbeClient: ManagedProxyWebsiteProbeClient = ManagedProxyWebsiteProbeClient(),
        clientConfigFileService: ClientConfigFileService = ClientConfigFileService(),
        preferencesStore: DesktopPreferencesStore = DesktopPreferencesStore(),
        keepAwakeController: any DesktopKeepAwakeControlling = DesktopKeepAwakeController(),
        appUpdateService: any AppUpdateServicing = AppUpdateService(),
        appUpdateInstaller: any AppUpdateInstalling = AppUpdateInstaller(),
        appUpdateCurrentAppURLProvider: @escaping () -> URL? = { Bundle.main.bundleURL },
        appUpdateTerminateHandler: @escaping () -> Void = { NSApp.terminate(nil) },
        clientConfigManagerWindowFactory: @escaping ClientConfigManagerWindowFactory = { ClientConfigManagerWindowController(model: $0) },
        codexProjectRoutesWindowFactory: @escaping CodexProjectRoutesWindowFactory = { CodexProjectRoutesWindowController(model: $0) },
        ocrCacheLogsWindowFactory: @escaping OCRCacheLogsWindowFactory = { OCRCacheLogsWindowController(model: $0) },
        ocrModelManagerWindowFactory: @escaping OCRModelManagerWindowFactory = { OCRModelManagerWindowController(model: $0) },
        remoteAdminWindowFactory: @escaping RemoteAdminWindowFactory = {
            RemoteAdminWindowController(
                host: $0,
                preferences: $1,
                remoteDeploy: $2,
                onClose: $3,
                discoveredAdminPortHandler: $4
            )
        },
        aboutWindowFactory: @escaping (DesktopAppModel) -> AboutWindowControlling = { AboutWindowController(model: $0) },
        helpWindowFactory: @escaping (DesktopAppModel) -> HelpWindowControlling = { HelpWindowController(model: $0) },
        onboardingWindowFactory: @escaping (DesktopAppModel) -> OnboardingWindowControlling = { OnboardingWindowController(model: $0) },
        confirmStopDaemonHandler: ConfirmStopDaemonHandler? = nil,
        confirmClearAccountManagedProxyNodesHandler: ConfirmClearAccountManagedProxyNodesHandler? = nil,
        confirmStopAccountCooldownHandler: ConfirmStopAccountCooldownHandler? = nil,
        confirmBatchRemoveAccountsHandler: ConfirmBatchRemoveAccountsHandler? = nil,
        confirmClearReasoningCacheHandler: ConfirmClearReasoningCacheHandler? = nil,
        confirmClearOCRCacheHandler: ConfirmClearOCRCacheHandler? = nil,
        confirmClearDiagnosticRequestBodiesHandler: ConfirmClearDiagnosticRequestBodiesHandler? = nil,
        confirmInterfaceModeSwitchHandler: ConfirmInterfaceModeSwitchHandler? = nil,
        confirmDeleteRemoteHostHandler: ConfirmDeleteRemoteHostHandler? = nil,
        confirmInstallUpdateHandler: ConfirmInstallUpdateHandler? = nil,
        importAuthFileSelectionHandler: ImportAuthFileSelectionHandler? = nil,
        importAuthFileReader: @escaping ImportAuthFileReader = { url in
            try String(contentsOf: url, encoding: .utf8)
        },
        proxyTestImageEditFileSelectionHandler: ProxyTestImageEditFileSelectionHandler? = nil,
        proxyTestImageSavePanelHandler: @escaping ProxyTestImageSavePanelHandler = DesktopAppModel.defaultProxyTestImageSavePanel,
        proxyTestImageDownloadHandler: @escaping ProxyTestImageDownloadHandler = DesktopAppModel.defaultProxyTestImageDownload,
        proxyTestImageFileWriter: @escaping ProxyTestImageFileWriter = { data, url in
            try data.write(to: url, options: .atomic)
        },
        proxyTestImageFilenameTokenProvider: @escaping ProxyTestImageFilenameTokenProvider = DesktopAppModel.defaultProxyTestImageFilenameToken,
        ocrModelTestImageSelectionHandler: @escaping OCRModelTestImageSelectionHandler = DesktopAppModel.defaultOCRModelTestImageSelection
    ) {
        self.admin = admin
        self.daemon = daemon
        self.remoteDeploy = remoteDeploy
        self.publicProxyClient = publicProxyClient
        self.managedProxyWebsiteProbeClient = managedProxyWebsiteProbeClient
        self.clientConfigFileService = clientConfigFileService
        self.preferencesStore = preferencesStore
        self.keepAwakeController = keepAwakeController
        self.appUpdateService = appUpdateService
        self.appUpdateInstaller = appUpdateInstaller
        self.appUpdateCurrentAppURLProvider = appUpdateCurrentAppURLProvider
        self.appUpdateTerminateHandler = appUpdateTerminateHandler
        self.clientConfigManagerWindowFactory = clientConfigManagerWindowFactory
        self.codexProjectRoutesWindowFactory = codexProjectRoutesWindowFactory
        self.ocrCacheLogsWindowFactory = ocrCacheLogsWindowFactory
        self.ocrModelManagerWindowFactory = ocrModelManagerWindowFactory
        self.remoteAdminWindowFactory = remoteAdminWindowFactory
        self.aboutWindowFactory = aboutWindowFactory
        self.helpWindowFactory = helpWindowFactory
        self.onboardingWindowFactory = onboardingWindowFactory
        self.confirmStopDaemonHandler = confirmStopDaemonHandler
        self.confirmClearAccountManagedProxyNodesHandler = confirmClearAccountManagedProxyNodesHandler
        self.confirmStopAccountCooldownHandler = confirmStopAccountCooldownHandler
        self.confirmBatchRemoveAccountsHandler = confirmBatchRemoveAccountsHandler
        self.confirmClearReasoningCacheHandler = confirmClearReasoningCacheHandler
        self.confirmClearOCRCacheHandler = confirmClearOCRCacheHandler
        self.confirmClearDiagnosticRequestBodiesHandler = confirmClearDiagnosticRequestBodiesHandler
        self.confirmInterfaceModeSwitchHandler = confirmInterfaceModeSwitchHandler
        self.confirmDeleteRemoteHostHandler = confirmDeleteRemoteHostHandler
        self.confirmInstallUpdateHandler = confirmInstallUpdateHandler
        self.importAuthFileSelectionHandler = importAuthFileSelectionHandler
        self.importAuthFileReader = importAuthFileReader
        self.proxyTestImageEditFileSelectionHandler = proxyTestImageEditFileSelectionHandler
        self.proxyTestImageSavePanelHandler = proxyTestImageSavePanelHandler
        self.proxyTestImageDownloadHandler = proxyTestImageDownloadHandler
        self.proxyTestImageFileWriter = proxyTestImageFileWriter
        self.proxyTestImageFilenameTokenProvider = proxyTestImageFilenameTokenProvider
        self.ocrModelTestImageSelectionHandler = ocrModelTestImageSelectionHandler
        self.preferences = preferencesStore.load()
        self.systemColorScheme = AppearanceStore.currentSystemColorScheme()
        self.isKeepAwakeEnabled = keepAwakeController.isEnabled
        let initialRequestLogsFilterState = RequestLogFilterState.defaultState()
        self.requestLogsDraftFilterState = initialRequestLogsFilterState
        self.requestLogsAppliedFilterState = initialRequestLogsFilterState
        self.ensureLocalSecretsReady()
    }

    var localization: LocalizationStore {
        LocalizationStore(mode: self.preferences.languageMode)
    }

    var resolvedPreferredColorScheme: ColorScheme {
        switch self.preferences.themeMode {
        case .system:
            return self.systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var savedRemoteHosts: [RemoteHostConfig] {
        self.settings.remoteHosts
    }

    var visiblePages: [Page] {
        Page.allCases.filter { self.canOpenPage($0) }
    }

    var adminCapabilities: AdminAPIClient.Capabilities {
        self.admin.capabilities
    }

    var adminSupportsOAuth: Bool {
        self.adminCapabilities.supportsOAuth
    }

    var adminSupportsImportCurrent: Bool {
        self.adminCapabilities.supportsImportCurrent
    }

    var adminSupportsProxyTesting: Bool {
        self.adminCapabilities.supportsProxyTesting
    }

    var adminSupportsOnboarding: Bool {
        self.adminCapabilities.supportsOnboarding
    }

    var displayedSelectedPage: Page {
        self.canOpenPage(self.selectedPage) ? self.selectedPage : .overview
    }

    func canOpenPage(_ page: Page) -> Bool {
        switch page {
        case .remote:
            return self.isRemoteManagementUnlocked
        case .overview, .accounts, .proxy, .settings, .clientConfig:
            return true
        }
    }

    func registerRemoteManagementRevealTap(now: Date = Date()) {
        guard self.isRemoteManagementUnlocked == false else { return }

        if let lastTapAt = self.remoteManagementLastTapAt,
           now.timeIntervalSince(lastTapAt) <= self.remoteManagementRevealResetInterval {
            self.remoteManagementRevealTapCount += 1
        } else {
            self.remoteManagementRevealTapCount = 1
        }

        self.remoteManagementLastTapAt = now

        guard self.remoteManagementRevealTapCount >= 3 else { return }

        self.selectedPage = self.displayedSelectedPage
        self.isRemoteManagementUnlocked = true
        DesktopMainMenuController.shared.configure(model: self, snapshot: self.menuLocalizationSnapshot)
        self.resetRemoteManagementRevealState()
    }

    var visibleAccountPoolAccounts: [AccountSummary] {
        AccountPoolListHelper.visibleAccounts(from: self.accounts, filters: self.accountPoolFilters)
    }

    var accountPoolDisplayMode: DesktopAccountPoolDisplayMode {
        self.preferences.accountPoolDisplayMode
    }

    var selectedAccountPoolAccount: AccountSummary? {
        guard let selectedAccountPoolAccountID else { return nil }
        return self.accounts.first { $0.id == selectedAccountPoolAccountID }
    }

    var orderedAccountsBySelection: [AccountSummary] {
        self.accounts.sorted(by: AccountPoolListHelper.compare)
    }

    var accountPoolTotalCountText: String {
        "\(self.accounts.count)"
    }

    var accountPoolFilterSummaryText: String {
        "\(self.visibleAccountPoolAccounts.count) / \(self.accounts.count)"
    }

    var accountPoolHasActiveFilters: Bool {
        self.accountPoolFilters.isFiltering
    }

    var selectedBatchRemoveAccounts: [AccountSummary] {
        let selectedIDs = self.selectedBatchRemoveAccountIDs
        return self.accounts.filter { selectedIDs.contains($0.id) }
    }

    var batchRemoveSelectedCountText: String {
        self.localized(
            zh: "已选择 \(self.selectedBatchRemoveAccountIDs.count) 个账号",
            en: "\(self.selectedBatchRemoveAccountIDs.count) selected"
        )
    }

    var canRemoveSelectedBatchAccounts: Bool {
        self.selectedBatchRemoveAccountIDs.isEmpty == false && self.isBatchRemovingAccounts == false
    }

    var accountManagedProxyNodeOverrideCount: Int {
        self.accounts.reduce(into: 0) { count, account in
            if AccountSummary.normalizedManagedProxyNodeName(account.managedProxyNodeName) != nil {
                count += 1
            }
        }
    }

    var hasAccountManagedProxyNodeOverrides: Bool {
        self.accountManagedProxyNodeOverrideCount > 0
    }

    var shouldShowAccountsOnboardingCallout: Bool {
        self.accounts.isEmpty
    }

    var onboardingAccountStepCompleted: Bool {
        self.accounts.isEmpty == false
    }

    var onboardingProxyStepCompleted: Bool {
        switch self.settings.outboundProxyMode {
        case .disabled, .subscription:
            return true
        case .manual:
            return self.settings.outboundProxy.isEnabled
        }
    }

    var onboardingProxyNeedsSave: Bool {
        self.onboardingProxyDraft != self.makeOnboardingProxyDraft(from: self.settings)
    }

    var isMinimalMode: Bool {
        self.preferences.interfaceMode == .minimal
    }

    var minimalProxyNeedsSave: Bool {
        self.minimalProxyDraft != self.makeMinimalProxyDraft(from: self.settings)
    }

    var shouldAutoPresentOnboardingAfterHelpDismiss: Bool {
        self.preferences.interfaceMode == .full
            && self.accounts.isEmpty
            && self.preferences.hasAutoPresentedOnboardingAfterHelp == false
    }

    var sidebarBrandSummary: SidebarBrandSummary {
        SidebarBrandSummary(
            brandName: self.text(.brandName),
            brandSubtitle: self.text(.brandSubtitle),
            serviceText: self.shellServiceStatusText,
            serviceTone: self.shellServiceStatusTone,
            accountCountText: self.accountPoolTotalCountText,
            requestCountText: "\(self.stats.totalRequests)",
            versionText: RuntimeInfo.displayVersion
        )
    }

    var currentPageTitle: String {
        self.localization.pageTitle(for: self.displayedSelectedPage.rawValue)
    }

    var currentPageSubtitle: String {
        self.localization.pageSubtitle(for: self.displayedSelectedPage.rawValue)
    }

    var localServiceControlState: LocalServiceControlState {
        ServiceControlResolver.localState(
            localStatus: self.localServiceStatus,
            proxyStatus: self.status,
            operation: self.localServiceOperation
        )
    }

    var effectiveServiceRunning: Bool {
        switch self.localServiceControlState {
        case .starting, .runningHealthy, .runningDegraded:
            return true
        case .stopping:
            return self.localServiceStatus?.running == true
        case .checking, .notInstalled, .stopped:
            return false
        }
    }

    var shellServiceStatusText: String {
        switch self.localServiceControlState {
        case .checking:
            return self.text(.statusChecking)
        case .starting:
            return self.text(.statusStarting)
        case .stopping:
            return self.text(.statusStopping)
        case .runningHealthy:
            return self.text(.statusOnline)
        case .runningDegraded:
            return self.text(.statusRunningDegraded)
        case .stopped:
            return self.text(.statusOffline)
        case .notInstalled:
            return self.text(.statusNotInstalled)
        }
    }

    var shellServiceStatusTone: StatusPill.Tone {
        switch self.localServiceControlState {
        case .checking:
            return .neutral
        case .starting:
            return .accent
        case .stopping:
            return .warning
        case .runningHealthy:
            return .success
        case .runningDegraded:
            return .warning
        case .stopped:
            return .warning
        case .notInstalled:
            return .warning
        }
    }

    var localServicePrimaryStatusText: String {
        switch self.localServiceControlState {
        case .checking:
            return self.text(.statusChecking)
        case .notInstalled:
            return self.text(.statusNotInstalled)
        case .stopped:
            return self.text(.statusInstalledNotRunning)
        case .starting:
            return self.text(.statusStarting)
        case .runningHealthy:
            return self.text(.statusRunning)
        case .runningDegraded:
            return self.text(.statusRunningDegraded)
        case .stopping:
            return self.text(.statusStopping)
        }
    }

    var localServiceSummaryText: String {
        switch self.localServiceControlState {
        case .checking:
            return self.text(.helperServiceChecking)
        case .notInstalled:
            return self.text(.helperServiceNotInstalled)
        case .stopped:
            return self.text(.helperServiceCanStart)
        case .starting:
            return self.text(.helperServiceStarting)
        case .runningHealthy:
            return self.text(.helperServiceCanStop)
        case .runningDegraded:
            return self.text(.helperServiceDegraded)
        case .stopping:
            return self.text(.helperServiceStopping)
        }
    }

    var localServiceSummaryTone: StatusPill.Tone {
        switch self.localServiceControlState {
        case .checking:
            return .neutral
        case .notInstalled:
            return .warning
        case .stopped:
            return .neutral
        case .starting:
            return .accent
        case .runningHealthy:
            return .success
        case .runningDegraded:
            return .warning
        case .stopping:
            return .warning
        }
    }

    var localStartButtonTitle: String {
        switch self.localServiceControlState {
        case .starting:
            return self.text(.statusStarting)
        case .runningHealthy, .runningDegraded:
            return self.text(.actionDaemonAlreadyRunning)
        case .checking, .notInstalled, .stopped, .stopping:
            return self.text(.actionStartDaemon)
        }
    }

    var localStopButtonTitle: String {
        switch self.localServiceControlState {
        case .stopping:
            return self.text(.statusStopping)
        case .checking, .notInstalled, .stopped, .starting:
            return self.text(.actionDaemonAlreadyStopped)
        case .runningHealthy, .runningDegraded:
            return self.text(.actionStopDaemon)
        }
    }

    var localCanStartService: Bool {
        switch self.localServiceControlState {
        case .notInstalled, .stopped:
            return true
        case .checking, .starting, .runningHealthy, .runningDegraded, .stopping:
            return false
        }
    }

    var localCanStopService: Bool {
        switch self.localServiceControlState {
        case .runningHealthy, .runningDegraded:
            return true
        case .checking, .notInstalled, .stopped, .starting, .stopping:
            return false
        }
    }

    func text(_ key: LocalizedTextKey) -> String {
        self.localization.text(key)
    }

    var mainWindowTitle: String {
        self.text(.brandName)
    }

    var menuBarExtraTitle: String {
        self.text(.brandName)
    }

    var menuBarStatusItemToolTip: String {
        self.menuBarTokenUsagePresentation?.toolTip ?? self.menuBarExtraTitle
    }

    var menuBarStatusItemAccessibilityLabel: String {
        self.menuBarTokenUsagePresentation?.accessibilityLabel ?? self.menuBarExtraTitle
    }

    var menuBarTokenUsagePresentation: MenuBarTokenUsagePresentation? {
        guard self.preferences.showsMenuBarTokenUsage else { return nil }

        let todayUsage = self.stats.naturalTokenUsage.today
        let compactLines = self.localization.menuBarTokenUsageLines(
            inputTokens: OverviewNumberFormat.abbreviated(todayUsage.inputTokens),
            outputTokens: OverviewNumberFormat.abbreviated(todayUsage.outputTokens)
        )
        let fullInputTokens = OverviewNumberFormat.full(todayUsage.inputTokens)
        let fullOutputTokens = OverviewNumberFormat.full(todayUsage.outputTokens)

        return MenuBarTokenUsagePresentation(
            primaryLine: compactLines.primaryLine,
            secondaryLine: compactLines.secondaryLine,
            toolTip: self.localization.menuBarTokenUsageToolTip(
                appName: self.menuBarExtraTitle,
                inputTokens: fullInputTokens,
                outputTokens: fullOutputTokens
            ),
            accessibilityLabel: self.localization.menuBarTokenUsageAccessibilityText(
                appName: self.menuBarExtraTitle,
                inputTokens: fullInputTokens,
                outputTokens: fullOutputTokens
            )
        )
    }

    var menuLocalizationSnapshot: DesktopMenuLocalizationSnapshot {
        DesktopMenuLocalizationSnapshot(model: self)
    }

    var helpWindowTitle: String {
        self.text(.helpWindowTitle)
    }

    var aboutWindowTitle: String {
        self.text(.menuAboutApp)
    }

    var onboardingWindowTitle: String {
        self.text(.onboardingWindowTitle)
    }

    var helpWindowSubtitle: String {
        self.text(.helpWindowSubtitle)
    }

    var aboutWindowSubtitle: String {
        self.text(.aboutWindowSubtitle)
    }

    var appVersionText: String {
        RuntimeInfo.displayVersion
    }

    var aboutDeveloperEmail: String {
        "zuoxiupeng@live.com"
    }

    func pageTitle(_ page: Page) -> String {
        self.localization.pageTitle(for: page.rawValue)
    }

    func pageSubtitle(_ page: Page) -> String {
        self.localization.pageSubtitle(for: page.rawValue)
    }

    var outboundProxyPageTitle: String {
        self.text(.sectionOutboundProxy)
    }

    var outboundProxyPageSubtitle: String {
        self.localized(
            zh: "切换直连、手工代理和订阅代理模式。",
            en: "Switch between direct, manual, and subscription egress."
        )
    }

    func label(for mode: DesktopLanguageMode) -> String {
        self.localization.label(for: mode)
    }

    func label(for mode: DesktopThemeMode) -> String {
        self.localization.label(for: mode)
    }

    func label(for mode: DesktopInterfaceMode) -> String {
        switch mode {
        case .minimal:
            return self.localized(zh: "极简模式", en: "Minimal Mode")
        case .full:
            return self.localized(zh: "全功能模式", en: "Full Mode")
        }
    }

    func label(for mode: DesktopAccountPoolDisplayMode) -> String {
        switch mode {
        case .cards:
            return self.text(.optionCards)
        case .list:
            return self.text(.optionList)
        }
    }

    func label(for scheme: OutboundProxyScheme) -> String {
        self.localization.label(for: scheme)
    }

    func label(for authMode: RemoteHostConfig.AuthMode) -> String {
        self.localization.label(for: authMode)
    }

    func label(for providerFamily: AccountProviderFamily) -> String {
        switch providerFamily {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        }
    }

    func label(for dataSource: ProxyDataSource) -> String {
        switch dataSource {
        case .all:
            return self.text(.commonAll)
        case .openAI:
            return self.label(for: AccountProviderFamily.openAI)
        case .anthropic:
            return self.label(for: AccountProviderFamily.anthropic)
        case .gemini:
            return self.label(for: AccountProviderFamily.gemini)
        }
    }

    func label(for behavior: WindowCloseBehavior) -> String {
        self.localization.label(for: behavior)
    }

    func label(for filter: AccountPoolStatusFilter) -> String {
        switch filter {
        case .all:
            return self.text(.commonAll)
        case .enabled:
            return self.text(.statusEnabled)
        case .disabled:
            return self.text(.statusDisabled)
        case .current:
            return self.text(.statusCurrent)
        }
    }

    func label(for filter: AccountPoolPlanFilter) -> String {
        switch filter {
        case .all:
            return self.text(.commonAll)
        case .apiKey:
            return self.planText("api_key")
        case .free:
            return self.planText("free")
        case .plus:
            return self.planText("plus")
        case .pro:
            return self.planText("pro")
        case .other:
            return self.text(.optionOther)
        }
    }

    func label(for filter: AccountPoolIssueFilter) -> String {
        switch filter {
        case .all:
            return self.text(.commonAll)
        case .healthy:
            return self.text(.optionHealthy)
        case .anyIssue:
            return self.text(.optionAnyIssue)
        case .refreshBlocked:
            return self.text(.optionRefreshBlocked)
        case .usageIssue:
            return self.text(.optionUsageIssue)
        }
    }

    func runningText(_ isRunning: Bool) -> String {
        self.localization.statusText(isRunning: isRunning)
    }

    func connectivityText(_ isRunning: Bool) -> String {
        self.localization.connectivityText(isRunning: isRunning)
    }

    func planText(_ planType: String?) -> String {
        self.localization.planText(planType)
    }

    func creditsText(_ credits: CreditSnapshot?) -> String {
        self.localization.usageBalanceText(credits)
    }

    var openAICompatibleBaseURL: String {
        self.normalizedUserFacingBaseURL(
            runtimeValue: self.status?.publicBaseURL,
            fallback: "http://\(self.settings.publicHost):\(self.settings.publicPort)/v1"
        )
    }

    var anthropicBaseURL: String {
        self.normalizedUserFacingBaseURL(
            runtimeValue: self.status?.anthropicBaseURL,
            fallback: "http://\(self.settings.publicHost):\(self.settings.publicPort)"
        )
    }

    var geminiBaseURL: String {
        self.normalizedUserFacingBaseURL(
            runtimeValue: self.status?.geminiBaseURL,
            fallback: "http://\(self.settings.publicHost):\(self.settings.publicPort)"
        )
    }

    var localProxyAPIKeyValue: String {
        let runtimeKey = self.status?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runtimeKey.isEmpty {
            return runtimeKey
        }
        return self.settings.primaryProxyAPIKeyRecord?.key ?? self.settings.proxyAPIKey
    }

    var anthropicAccessProxyAPIKeyRecord: ProxyAPIKeyRecord? {
        let matchingKeys = self.configuredProxyAPIKeys.filter { record in
            record.enabled && (record.dataSource == .anthropic || record.dataSource == .all)
        }
        return matchingKeys.first(where: { $0.dataSource == .anthropic && $0.allowedAccountKeys.isEmpty })
            ?? matchingKeys.first(where: { $0.dataSource == .all && $0.allowedAccountKeys.isEmpty })
            ?? matchingKeys.first
    }

    var anthropicAccessProxyAPIKeyValue: String? {
        let trimmed = self.anthropicAccessProxyAPIKeyRecord?.key.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var anthropicAccessProxyAPIKeyDisplayValue: String {
        self.anthropicAccessProxyAPIKeyValue ?? self.text(.statusUnavailable)
    }

    var canCopyAnthropicAccessProxyAPIKey: Bool {
        self.anthropicAccessProxyAPIKeyValue != nil
    }

    var claudeCodeEnvironmentSnippet: String {
        guard let anthropicAccessProxyAPIKeyValue = self.anthropicAccessProxyAPIKeyValue else {
            return self.text(.statusUnavailable)
        }
        return """
        export ANTHROPIC_BASE_URL=\(self.anthropicBaseURL)
        export ANTHROPIC_AUTH_TOKEN=\(anthropicAccessProxyAPIKeyValue)
        """
    }

    var canCopyClaudeCodeEnvironmentSnippet: Bool {
        self.canCopyAnthropicAccessProxyAPIKey
    }

    var geminiCLIEnvironmentSnippet: String {
        """
        export GOOGLE_GEMINI_BASE_URL=\(self.geminiBaseURL)
        export GEMINI_API_KEY=\(self.localProxyAPIKeyValue)
        """
    }

    func localLaunchctlStateText() -> String {
        switch self.localServiceStatus?.launchctlState {
        case "running":
            return self.text(.statusRunning)
        case "not_installed":
            return self.text(.statusNotInstalled)
        case "not_registered":
            return self.text(.statusNotRegistered)
        case "registered":
            return self.text(.statusRegistered)
        case .some(let raw):
            return raw.replacingOccurrences(of: "_", with: " ")
        case .none:
            return self.text(.statusUnknown)
        }
    }

    func localServiceTone() -> StatusPill.Tone {
        switch self.localServiceControlState {
        case .checking:
            return .neutral
        case .starting:
            return .accent
        case .runningHealthy:
            return .success
        case .runningDegraded, .stopping, .stopped, .notInstalled:
            return .warning
        }
    }

    func usagePercentText(_ window: UsageWindow?) -> String {
        guard let window else { return self.text(.statusNoData) }
        return "\(self.effectiveUsageRemainingPercent(window))%"
    }

    func usagePercentText(for account: AccountSummary, window: UsageWindow?) -> String {
        if account.authMode == .chatGPT, account.usageWindowsVisible == false {
            return "-"
        }
        return self.usagePercentText(window)
    }

    func usageResetText(for account: AccountSummary, window: UsageWindow?) -> String? {
        guard let resetAt = AccountPoolListHelper.usageWindowResetAt(for: account, window: window) else {
            return nil
        }
        return self.localization.accountUsageResetText(
            resetAt: DesktopDateTimeFormat.compactString(fromUnixSeconds: resetAt)
        )
    }

    func accountTokenText(_ value: Int64) -> String {
        OverviewNumberFormat.abbreviated(value)
    }

    func accountTokenHelp(_ value: Int64) -> String {
        OverviewNumberFormat.full(value)
    }

    func accountUsageTiles(for account: AccountSummary) -> [AccountUsageTileDescriptor] {
        if account.authMode.isManualAPIKey || account.authMode == .anthropicSubscriptionOAuth || account.authMode == .geminiOAuth {
            let todayTokenUsage = account.todayTokenUsage ?? AccountTodayTokenUsage()
            return [
                AccountUsageTileDescriptor(
                    id: "input_tokens",
                    title: self.text(.labelInputTokens),
                    value: self.accountTokenText(todayTokenUsage.inputTokens),
                    helpText: self.accountTokenHelp(todayTokenUsage.inputTokens),
                    tone: .accent,
                    symbol: "arrow.down.circle"
                ),
                AccountUsageTileDescriptor(
                    id: "output_tokens",
                    title: self.text(.labelOutputTokens),
                    value: self.accountTokenText(todayTokenUsage.outputTokens),
                    helpText: self.accountTokenHelp(todayTokenUsage.outputTokens),
                    tone: .neutral,
                    symbol: "arrow.up.circle"
                ),
            ]
        }

        return [
            AccountUsageTileDescriptor(
                id: "five_hour_usage",
                title: "5H",
                value: self.usagePercentText(for: account, window: account.usage?.fiveHour),
                subtitle: self.usageResetText(for: account, window: account.usage?.fiveHour),
                tone: .accent,
                symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90"
            ),
            AccountUsageTileDescriptor(
                id: "one_week_usage",
                title: "1W",
                value: self.usagePercentText(for: account, window: account.usage?.oneWeek),
                subtitle: self.usageResetText(for: account, window: account.usage?.oneWeek),
                tone: .neutral,
                symbol: "calendar"
            ),
            AccountUsageTileDescriptor(
                id: "credits",
                title: self.text(.labelCredits),
                value: self.creditsText(account.usage?.credits),
                tone: .success,
                symbol: "creditcard.fill"
            ),
        ]
    }

    func accountRuntimeStatusText(_ account: AccountSummary) -> String {
        if account.isCoolingDown() {
            return self.text(.statusCoolingDown)
        }
        if self.accountQuotaBlockedUntil(account) != nil {
            return self.localization.accountQuotaBlockedLabel()
        }
        return account.authRefreshBlocked ? self.text(.statusStopped) : self.text(.statusRunning)
    }

    func accountRuntimeIssueText(_ account: AccountSummary) -> String? {
        if let cooldownUntil = account.cooldownUntil, cooldownUntil > Helpers.now() {
            return self.localized(
                zh: "API Key 冷却至 \(DesktopDateTimeFormat.string(fromUnixSeconds: cooldownUntil))，到时会自动重试。",
                en: "API key is cooling down until \(DesktopDateTimeFormat.string(fromUnixSeconds: cooldownUntil)). It will be retried automatically."
            )
        }

        if let resetAt = self.accountQuotaBlockedUntil(account) {
            return self.localization.accountQuotaResetText(
                resetAt: DesktopDateTimeFormat.string(fromUnixSeconds: resetAt)
            )
        }

        let usageError = account.usageError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if usageError.isEmpty == false, AccountPoolListHelper.hasNonStaleUsageError(account) {
            return self.localization.errorDetail(for: usageError, context: .refreshAccountUsage) ?? usageError
        }

        let refreshError = account.authRefreshError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard refreshError.isEmpty == false else {
            return nil
        }
        return self.localization.errorDetail(for: refreshError, context: .refreshAccountUsage) ?? refreshError
    }

    func minimalAccountUsageSummary(_ account: AccountSummary) -> String {
        if account.authMode.isManualAPIKey || account.authMode == .anthropicSubscriptionOAuth || account.authMode == .geminiOAuth {
            guard let todayTokenUsage = account.todayTokenUsage else {
                return self.text(.statusNoData)
            }
            let totalTokens = todayTokenUsage.inputTokens + todayTokenUsage.outputTokens
            return self.localized(
                zh: "今日 \(self.accountTokenText(totalTokens))",
                en: "Today \(self.accountTokenText(totalTokens))"
            )
        }

        let noData = self.text(.statusNoData)
        let fiveHour = self.minimalUsagePercentText(for: account, window: account.usage?.fiveHour)
        let oneWeek = self.minimalUsagePercentText(for: account, window: account.usage?.oneWeek)
        guard fiveHour != nil || oneWeek != nil else {
            return noData
        }

        return self.localized(
            zh: "5H \(fiveHour ?? noData) / 1W \(oneWeek ?? noData)",
            en: "5H \(fiveHour ?? noData) / 1W \(oneWeek ?? noData)"
        )
    }

    func minimalAccountStatusPresentation(_ account: AccountSummary) -> (text: String, tone: StatusPill.Tone) {
        if !account.enabled {
            return (self.text(.statusDisabled), .danger)
        }

        let statusText = self.accountRuntimeStatusText(account)
        if statusText != self.text(.statusRunning) || self.accountIssueText(account) != nil {
            return (statusText, .warning)
        }

        return (statusText, .success)
    }

    func displayValue(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? self.text(.statusNoData) : trimmed
    }

    private func effectiveUsageRemainingPercent(_ window: UsageWindow) -> Int {
        if let resetAt = window.resetAt, window.remainingPercent <= 0, resetAt <= Helpers.now() {
            return 100
        }
        return window.remainingPercent
    }

    private func accountQuotaBlockedUntil(_ account: AccountSummary) -> Int64? {
        AccountPoolListHelper.quotaBlockedUntil(account)
    }

    private func minimalUsagePercentText(for account: AccountSummary, window: UsageWindow?) -> String? {
        guard let window else { return nil }
        let usageText = self.usagePercentText(for: account, window: window)
        return usageText == "-" ? self.text(.statusNoData) : usageText
    }

    func selectAccountPoolAccount(_ account: AccountSummary?) {
        self.selectedAccountPoolAccountID = account?.id
        self.clearAccountPoolSelectionIfNeeded()
    }

    func presentAccountPoolDetailDrawer(for account: AccountSummary?) {
        self.selectedAccountPoolAccountID = account?.id
        self.clearAccountPoolSelectionIfNeeded()

        guard self.accountPoolDisplayMode == .list,
              self.selectedAccountPoolAccountID != nil
        else {
            self.isAccountPoolDetailDrawerPresented = false
            return
        }
        self.isAccountPoolDetailDrawerPresented = true
    }

    func dismissAccountPoolDetailDrawer() {
        self.isAccountPoolDetailDrawerPresented = false
    }

    func clearAccountPoolSelectionIfNeeded() {
        guard self.accountPoolDisplayMode == .list else {
            self.selectedAccountPoolAccountID = nil
            self.isAccountPoolDetailDrawerPresented = false
            return
        }

        guard let selectedAccountPoolAccountID else {
            self.isAccountPoolDetailDrawerPresented = false
            return
        }
        guard self.visibleAccountPoolAccounts.contains(where: { $0.id == selectedAccountPoolAccountID }) else {
            self.selectedAccountPoolAccountID = nil
            self.isAccountPoolDetailDrawerPresented = false
            return
        }
    }

    private func syncAccountPoolDetailDrawerContext() {
        guard self.preferences.interfaceMode == .full,
              self.selectedPage == .accounts
        else {
            self.isAccountPoolDetailDrawerPresented = false
            return
        }
    }

    func resetAccountPoolFilters() {
        self.accountPoolFilters = AccountPoolFilterState()
    }

    func enterAccountBatchRemoveMode() {
        self.isAccountBatchRemoveModeEnabled = true
    }

    func exitAccountBatchRemoveMode() {
        self.isAccountBatchRemoveModeEnabled = false
        self.selectedBatchRemoveAccountIDs.removeAll()
    }

    func toggleAccountBatchRemoveMode() {
        if self.isAccountBatchRemoveModeEnabled {
            self.exitAccountBatchRemoveMode()
        } else {
            self.enterAccountBatchRemoveMode()
        }
    }

    func isSelectedForBatchRemove(_ account: AccountSummary) -> Bool {
        self.selectedBatchRemoveAccountIDs.contains(account.id)
    }

    func toggleBatchRemoveSelection(for account: AccountSummary) {
        if self.selectedBatchRemoveAccountIDs.contains(account.id) {
            self.selectedBatchRemoveAccountIDs.remove(account.id)
        } else {
            self.selectedBatchRemoveAccountIDs.insert(account.id)
        }
    }

    func selectVisibleAccountsForBatchRemove() {
        for account in self.visibleAccountPoolAccounts {
            self.selectedBatchRemoveAccountIDs.insert(account.id)
        }
    }

    func clearBatchRemoveSelection() {
        self.selectedBatchRemoveAccountIDs.removeAll()
    }

    private func pruneBatchRemoveAccountSelection() {
        let existingIDs = Set(self.accounts.map(\.id))
        self.selectedBatchRemoveAccountIDs = Set(self.selectedBatchRemoveAccountIDs.filter { existingIDs.contains($0) })
        if self.accounts.isEmpty {
            self.isAccountBatchRemoveModeEnabled = false
        }
    }

    func isRefreshingUsage(for accountID: String) -> Bool {
        self.refreshingAccountIDs.contains(accountID)
    }

    func refreshUsageButtonText(for accountID: String) -> String {
        self.isRefreshingUsage(for: accountID)
            ? self.text(.actionRefreshingUsage)
            : self.text(.actionRefreshUsage)
    }

    var refreshAccountListButtonText: String {
        self.isRefreshingAccountList
            ? self.text(.actionRefreshingAccountList)
            : self.text(.actionRefreshAccountList)
    }

    func accountCardRefreshActionTitle(for accountID: String) -> String {
        self.isRefreshingUsage(for: accountID)
            ? self.text(.actionAccountCardRefreshing)
            : self.text(.actionAccountCardRefresh)
    }

    func accountCardEditActionTitle(for account: AccountSummary) -> String? {
        guard self.accountCardEditActionKind(for: account) != nil else { return nil }
        return self.text(.actionAccountCardEdit)
    }

    var accountCardNodeActionTitle: String {
        self.text(.actionAccountCardNode)
    }

    func canStopAccountCooldown(_ account: AccountSummary) -> Bool {
        account.authMode.isManualAPIKey && account.isCoolingDown()
    }

    func canUpdateAccountCooldownPolicy(_ account: AccountSummary) -> Bool {
        account.authMode.isManualAPIKey
    }

    func canEditAccountReasoningEffort(_ account: AccountSummary) -> Bool {
        guard account.authMode == .openAIAPIKey else { return false }
        if account.providerPreset.usesOpenAIChatCompletionsAPI {
            return true
        }
        return account.providerPreset == .genericOpenAICompatible
            && account.upstreamAdapter == .chatCompletions
    }

    func accountCooldownPolicyText(_ account: AccountSummary) -> String {
        account.automaticCooldownDisabled
            ? self.localized(zh: "已禁用", en: "Disabled")
            : self.localized(zh: "自动", en: "Automatic")
    }

    func accountCooldownPolicyActionTitle(_ account: AccountSummary) -> String {
        account.automaticCooldownDisabled
            ? self.text(.actionEnableAutomaticCooldown)
            : self.text(.actionDisableAutomaticCooldown)
    }

    var accountCardMoreActionTitle: String {
        self.text(.actionAccountCardMore)
    }

    func accountCardEditActionKind(for account: AccountSummary) -> AccountCardEditActionKind? {
        if self.canRenameAccount(account) {
            return .rename
        }
        if account.authMode.isManualAPIKey {
            return .editAPIKey
        }
        return nil
    }

    func performAccountCardEditAction(for account: AccountSummary) async {
        switch self.accountCardEditActionKind(for: account) {
        case .rename:
            self.openRenameAccountSheet(account)
        case .editAPIKey:
            await self.openEditAPIKeyAccountSheet(account)
        case .none:
            break
        }
    }

    func presentManualAPIKeySheet() {
        self.manualAPIKeyEditLoadGeneration += 1
        self.manualAPIKeyDraft = ManualAPIKeyDraft()
    }

    func presentGoogleGeminiManualAPIKeySheet() {
        self.manualAPIKeyEditLoadGeneration += 1
        self.manualAPIKeyDraft = ManualAPIKeyDraft(
            providerPreset: .googleGeminiCompatible,
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL
        )
    }

    func openEditAPIKeyAccountSheet(_ account: AccountSummary) async {
        guard account.authMode.isManualAPIKey else { return }
        self.manualAPIKeyEditLoadGeneration += 1
        let generation = self.manualAPIKeyEditLoadGeneration

        do {
            let details = try await self.admin.manualAPIKeyAccountDetails(id: account.id)
            guard self.manualAPIKeyEditLoadGeneration == generation else { return }

            self.manualAPIKeyDraft = ManualAPIKeyDraft(
                label: details.label,
                providerPreset: details.providerPreset,
                baseURL: details.baseURL,
                upstreamAdapter: details.upstreamAdapter ?? .responses,
                chatCompatibilityProfile: details.chatCompatibilityProfile,
                apiKey: details.apiKey,
                enabled: details.enabled,
                automaticCooldownDisabled: details.automaticCooldownDisabled,
                supportsVision: details.supportsVision,
                editingAccountID: account.id,
                originalAccountKey: account.accountKey
            )
        } catch {
            guard self.manualAPIKeyEditLoadGeneration == generation else { return }
            self.present(error: error, context: .manualUpdateAccount)
        }
    }

    func openRenameAccountSheet(_ account: AccountSummary) {
        guard self.canRenameAccount(account) else { return }
        self.accountLabelDraft = AccountLabelDraft(
            accountID: account.id,
            accountKey: account.accountKey,
            label: account.label
        )
    }

    func openAccountManagedProxyNodeSheet(_ account: AccountSummary) {
        self.accountManagedProxyNodeDraft = AccountManagedProxyNodeDraft(
            accountID: account.id,
            accountKey: account.accountKey,
            label: account.label,
            managedProxyNodeName: AccountSummary.normalizedManagedProxyNodeName(account.managedProxyNodeName)
        )
    }

    func openAccountModelRoutingSheet(_ account: AccountSummary) {
        let modelRouting = AccountSummary.normalizedModelRouting(account.modelRouting)
        self.accountModelRoutingDraft = AccountModelRoutingDraft(
            accountID: account.id,
            accountKey: account.accountKey,
            label: account.label,
            defaultTargetModel: modelRouting?.defaultTargetModel ?? "",
            mappings: modelRouting?.mappings ?? []
        )
    }

    func openAccountReasoningEffortSheet(_ account: AccountSummary) {
        guard self.canEditAccountReasoningEffort(account) else { return }
        let reasoningEffort = account.reasoningEffort
        self.accountReasoningEffortDraft = AccountReasoningEffortDraft(
            accountID: account.id,
            accountKey: account.accountKey,
            label: account.label,
            low: reasoningEffort.low,
            medium: reasoningEffort.medium,
            high: reasoningEffort.high,
            xhigh: reasoningEffort.xhigh
        )
    }

    func presentAccountOrderSheet() {
        self.accountOrderDraft = AccountOrderDraft(
            accounts: self.accounts.sorted(by: AccountPoolListHelper.compare)
        )
    }

    var accountOrderVisibleEntries: [AccountOrderVisibleEntry] {
        guard let draft = self.accountOrderDraft else { return [] }
        return draft.accounts.enumerated().compactMap { offset, account in
            guard AccountPoolListHelper.matchesSearch(account, query: draft.searchQuery) else {
                return nil
            }
            return AccountOrderVisibleEntry(position: offset + 1, account: account)
        }
    }

    var accountOrderIsSearching: Bool {
        let query = self.accountOrderDraft?.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return query.isEmpty == false
    }

    var accountOrderVisibleCountText: String {
        let visibleCount = self.accountOrderVisibleEntries.count
        let totalCount = self.accountOrderDraft?.accounts.count ?? 0
        return self.localized(zh: "显示 \(visibleCount) / \(totalCount)", en: "Showing \(visibleCount) / \(totalCount)")
    }

    func moveAccountOrderDraft(fromOffsets: IndexSet, toOffset: Int) {
        guard var draft = self.accountOrderDraft else { return }
        draft.accounts.move(fromOffsets: fromOffsets, toOffset: toOffset)
        self.accountOrderDraft = draft
    }

    func moveAccountOrderDraftToTop(accountID: String) {
        self.moveAccountOrderDraft(accountID: accountID, toZeroBasedIndex: 0)
    }

    func moveAccountOrderDraftUp(accountID: String) {
        guard let index = self.accountOrderDraftIndex(for: accountID), index > 0 else { return }
        self.moveAccountOrderDraft(accountID: accountID, toZeroBasedIndex: index - 1)
    }

    func moveAccountOrderDraftDown(accountID: String) {
        guard let draft = self.accountOrderDraft,
              let index = self.accountOrderDraftIndex(for: accountID),
              index < draft.accounts.count - 1
        else { return }
        self.moveAccountOrderDraft(accountID: accountID, toZeroBasedIndex: index + 1)
    }

    func moveAccountOrderDraftToBottom(accountID: String) {
        guard let count = self.accountOrderDraft?.accounts.count, count > 0 else { return }
        self.moveAccountOrderDraft(accountID: accountID, toZeroBasedIndex: count - 1)
    }

    @discardableResult
    func moveAccountOrderDraft(accountID: String, toOneBasedPosition rawPosition: String) -> Bool {
        let trimmed = rawPosition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let position = Int(trimmed) else { return false }
        return self.moveAccountOrderDraft(accountID: accountID, toOneBasedPosition: position)
    }

    @discardableResult
    func moveAccountOrderDraft(accountID: String, toOneBasedPosition position: Int) -> Bool {
        guard let count = self.accountOrderDraft?.accounts.count, count > 0 else { return false }
        let clampedPosition = min(max(position, 1), count)
        return self.moveAccountOrderDraft(accountID: accountID, toZeroBasedIndex: clampedPosition - 1)
    }

    func canMoveAccountOrderDraftUp(accountID: String) -> Bool {
        guard let index = self.accountOrderDraftIndex(for: accountID) else { return false }
        return index > 0
    }

    func canMoveAccountOrderDraftDown(accountID: String) -> Bool {
        guard let draft = self.accountOrderDraft,
              let index = self.accountOrderDraftIndex(for: accountID)
        else { return false }
        return index < draft.accounts.count - 1
    }

    private func accountOrderDraftIndex(for accountID: String) -> Int? {
        self.accountOrderDraft?.accounts.firstIndex { $0.id == accountID }
    }

    @discardableResult
    private func moveAccountOrderDraft(accountID: String, toZeroBasedIndex targetIndex: Int) -> Bool {
        guard var draft = self.accountOrderDraft,
              let currentIndex = draft.accounts.firstIndex(where: { $0.id == accountID })
        else { return false }
        let clampedTarget = min(max(targetIndex, 0), draft.accounts.count - 1)
        guard currentIndex != clampedTarget else { return true }

        let account = draft.accounts.remove(at: currentIndex)
        let insertionIndex = min(clampedTarget, draft.accounts.count)
        draft.accounts.insert(account, at: insertionIndex)
        self.accountOrderDraft = draft
        return true
    }

    func dismissManualAPIKeySheet() {
        guard self.manualAPIKeyIsSubmitting == false else { return }
        self.manualAPIKeyEditLoadGeneration += 1
        self.manualAPIKeyDraft = nil
    }

    func resolvedManualAPIKeyDraft(for presentedDraft: ManualAPIKeyDraft) -> ManualAPIKeyDraft {
        guard let currentDraft = self.manualAPIKeyDraft, currentDraft.id == presentedDraft.id else {
            return presentedDraft
        }
        return currentDraft
    }

    func updateManualAPIKeyDraft(_ draft: ManualAPIKeyDraft, for presentedDraft: ManualAPIKeyDraft) {
        guard let currentDraft = self.manualAPIKeyDraft, currentDraft.id == presentedDraft.id else { return }
        self.manualAPIKeyDraft = draft
    }

    func presentMinimalManualAPIKeyDraft() {
        self.minimalManualAPIKeyDraft = ManualAPIKeyDraft()
    }

    func dismissMinimalManualAPIKeyDraft() {
        guard self.manualAPIKeyIsSubmitting == false else { return }
        self.minimalManualAPIKeyDraft = nil
    }

    func updateMinimalManualAPIKeyDraft(_ draft: ManualAPIKeyDraft) {
        self.minimalManualAPIKeyDraft = draft
    }

    func submitMinimalManualAPIKeyAccount() async {
        guard let draft = self.minimalManualAPIKeyDraft else { return }

        self.manualAPIKeyIsSubmitting = true
        defer { self.manualAPIKeyIsSubmitting = false }

        do {
            let outcome = try await self.saveManualAPIKeyAccount(draft: draft)
            try await self.reloadAccountState()
            self.minimalManualAPIKeyDraft = nil
            self.publishSuccess(outcome.successContext, detail: outcome.saved.label)
        } catch is CancellationError {
            return
        } catch {
            self.present(error: error, context: draft.isEditing ? .manualUpdateAccount : .manualAddAccount)
        }
    }

    func makeMinimalProxyDraft(from settings: AppConfig) -> MinimalProxyDraft {
        let choice: MinimalProxyChoice = settings.outboundProxyMode == .manual ? .manual : .direct
        return MinimalProxyDraft(
            choice: choice,
            scheme: settings.outboundProxy.scheme == .disabled ? .http : settings.outboundProxy.scheme,
            host: settings.outboundProxy.host,
            port: settings.outboundProxy.port,
            username: settings.outboundProxy.username,
            password: settings.outboundProxy.password
        )
    }

    func syncMinimalProxyDraftFromSettingsIfNeeded(force: Bool = false) {
        let currentDraft = self.makeMinimalProxyDraft(from: self.settings)
        if force || self.hasPreparedMinimalProxyDraft == false || self.minimalProxyDraft == self.syncedMinimalProxyDraft {
            self.minimalProxyDraft = currentDraft
        }
        self.syncedMinimalProxyDraft = currentDraft
        self.hasPreparedMinimalProxyDraft = true
    }

    func updateMinimalProxyChoice(_ choice: MinimalProxyChoice) {
        self.minimalProxyDraft.choice = choice
        if choice == .manual, self.minimalProxyDraft.scheme == .disabled {
            self.minimalProxyDraft.scheme = .http
        }
    }

    func minimalProxyChoiceTitle(_ choice: MinimalProxyChoice) -> String {
        switch choice {
        case .direct:
            return self.localized(zh: "我不需要代理", en: "No Proxy Needed")
        case .manual:
            return self.localized(zh: "我要使用手工代理", en: "Use Manual Proxy")
        }
    }

    func minimalProxyChoiceHelp(_ choice: MinimalProxyChoice) -> String {
        switch choice {
        case .direct:
            return self.localized(
                zh: "适合当前网络已经能稳定访问上游接口的情况。",
                en: "Best when your current network already reaches the upstream reliably."
            )
        case .manual:
            return self.localized(
                zh: "适合你已经有 HTTP / HTTPS / SOCKS5 代理端口的情况。",
                en: "Best when you already have an HTTP / HTTPS / SOCKS5 proxy endpoint."
            )
        }
    }

    func minimalProxyModeSummary() -> String {
        switch self.settings.outboundProxyMode {
        case .disabled:
            return self.localized(
                zh: "当前保存的是直连模式，daemon 会直接访问上游。",
                en: "The current saved mode is direct egress, so the daemon connects to upstreams directly."
            )
        case .manual:
            let host = self.settings.outboundProxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.isEmpty == false, self.settings.outboundProxy.port > 0 else {
                return self.localized(
                    zh: "当前保存的是手工代理模式，但代理地址还不完整。",
                    en: "The current saved mode is manual proxy, but the proxy address is still incomplete."
                )
            }
            return self.localized(
                zh: "当前保存的是手工代理模式：\(host):\(self.settings.outboundProxy.port)。",
                en: "The current saved mode is manual proxy: \(host):\(self.settings.outboundProxy.port)."
            )
        case .subscription:
            return self.localized(
                zh: "当前正在使用订阅代理。极简模式只显示摘要，详细配置仍在设置页维护。",
                en: "The current setup uses subscription proxying. Minimal mode shows the summary only, while detailed configuration stays on the Settings page."
            )
        }
    }

    @discardableResult
    func saveMinimalProxyConfiguration() async -> Bool {
        if self.minimalProxyDraft.choice == .manual {
            let host = self.minimalProxyDraft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.isEmpty == false else {
                self.publishBanner(
                    .warning,
                    title: self.localized(zh: "请先填写代理地址", en: "Enter a proxy host first"),
                    detail: self.localized(zh: "手工代理至少需要填写 host 和 port。", en: "Manual proxy mode needs at least a host and port.")
                )
                return false
            }

            guard self.minimalProxyDraft.port > 0 else {
                self.publishBanner(
                    .warning,
                    title: self.localized(zh: "请先填写代理端口", en: "Enter a proxy port first"),
                    detail: self.localized(zh: "手工代理至少需要填写 host 和 port。", en: "Manual proxy mode needs at least a host and port.")
                )
                return false
            }
        }

        switch self.minimalProxyDraft.choice {
        case .direct:
            self.settings.outboundProxyMode = .disabled
            self.settings.outboundProxy.scheme = .disabled
        case .manual:
            self.settings.outboundProxyMode = .manual
            self.settings.outboundProxy.scheme = self.minimalProxyDraft.scheme == .disabled ? .http : self.minimalProxyDraft.scheme
            self.settings.outboundProxy.host = self.minimalProxyDraft.host
            self.settings.outboundProxy.port = self.minimalProxyDraft.port
            self.settings.outboundProxy.username = self.minimalProxyDraft.username
            self.settings.outboundProxy.password = self.minimalProxyDraft.password
        }

        let saved = await self.saveSettings(noticeContext: .saveSettings)
        if saved {
            self.syncMinimalProxyDraftFromSettingsIfNeeded(force: true)
        }
        return saved
    }

    func makeSettingsOutboundProxyDraft(from settings: AppConfig) -> SettingsOutboundProxyDraft {
        SettingsOutboundProxyDraft(
            mode: settings.outboundProxyMode,
            outboundProxy: OutboundProxySettings(
                scheme: settings.outboundProxy.scheme == .disabled ? .http : settings.outboundProxy.scheme,
                host: settings.outboundProxy.host,
                port: settings.outboundProxy.port,
                username: settings.outboundProxy.username,
                password: settings.outboundProxy.password
            )
        )
    }

    func syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: Bool = false) {
        let currentDraft = self.makeSettingsOutboundProxyDraft(from: self.settings)
        if force
            || self.hasPreparedSettingsOutboundProxyDraft == false
            || self.settingsOutboundProxyDraft == self.syncedSettingsOutboundProxyDraft
        {
            self.settingsOutboundProxyDraft = currentDraft
        }
        self.syncedSettingsOutboundProxyDraft = currentDraft
        self.hasPreparedSettingsOutboundProxyDraft = true
    }

    func syncSettingsOutboundProxyManualDraftFromSettings() {
        let currentMode = self.settingsOutboundProxyDraft.mode
        self.settingsOutboundProxyDraft.outboundProxy = self.makeSettingsOutboundProxyDraft(from: self.settings).outboundProxy
        self.syncedSettingsOutboundProxyDraft = self.makeSettingsOutboundProxyDraft(from: self.settings)
        self.settingsOutboundProxyDraft.mode = currentMode
        self.hasPreparedSettingsOutboundProxyDraft = true
    }

    func dismissAccountLabelSheet() {
        guard self.accountLabelIsSubmitting == false else { return }
        self.accountLabelDraft = nil
    }

    func dismissAccountOrderSheet() {
        guard self.accountOrderIsSubmitting == false else { return }
        self.accountOrderDraft = nil
    }

    func dismissAccountManagedProxyNodeSheet() {
        guard self.accountManagedProxyNodeIsSubmitting == false else { return }
        self.accountManagedProxyNodeDraft = nil
    }

    func dismissAccountModelRoutingSheet() {
        guard self.accountModelRoutingIsSubmitting == false else { return }
        self.accountModelRoutingDraft = nil
    }

    func dismissAccountReasoningEffortSheet() {
        guard self.accountReasoningEffortIsSubmitting == false else { return }
        self.accountReasoningEffortDraft = nil
    }

    func manualAPIKeySheetTitle(for presentedDraft: ManualAPIKeyDraft) -> String {
        let draft = self.resolvedManualAPIKeyDraft(for: presentedDraft)
        return draft.isEditing ? self.text(.actionEditAPIKey) : self.text(.actionManualAddAccount)
    }

    var accountLabelSheetTitle: String {
        self.text(.actionEditAccountName)
    }

    var accountOrderSheetTitle: String {
        self.text(.actionManageAccountOrder)
    }

    var accountManagedProxyNodeSheetTitle: String {
        self.text(.actionEditOutboundNode)
    }

    var accountModelRoutingSheetTitle: String {
        self.text(.actionEditModelRouting)
    }

    var accountReasoningEffortSheetTitle: String {
        self.text(.actionEditReasoningEffort)
    }

    var availableManagedProxyNodeNames: [String] {
        self.managedProxySnapshot.nodes.map(\.name)
    }

    var canSelectAccountManagedProxyNodeOptions: Bool {
        !self.availableManagedProxyNodeNames.isEmpty
    }

    func normalizedAccountModelRouting(for draft: AccountModelRoutingDraft) -> AccountModelRoutingConfig? {
        AccountModelRoutingConfig(
            defaultTargetModel: draft.defaultTargetModel,
            mappings: draft.mappings
        ).normalizedOrNil
    }

    func accountAuthModeText(_ account: AccountSummary) -> String {
        switch account.authMode {
        case .chatGPT:
            return self.localized(zh: "OpenAI OAuth", en: "OpenAI OAuth")
        case .openAIAPIKey:
            return self.localized(zh: "OpenAI API Key", en: "OpenAI API Key")
        case .anthropicAPIKey:
            return self.localized(zh: "Anthropic API Key", en: "Anthropic API Key")
        case .anthropicSubscriptionOAuth:
            return self.localized(zh: "Anthropic OAuth", en: "Anthropic OAuth")
        case .geminiOAuth:
            return self.localized(zh: "Google / Gemini 登录", en: "Google / Gemini Login")
        }
    }

    func providerPresetText(_ preset: OpenAICompatibleProviderPreset) -> String {
        switch preset {
        case .genericOpenAICompatible:
            return self.text(.providerPresetGenericOpenAICompatible)
        case .aliyunQwenCodingPlan:
            return self.text(.providerPresetAliyunQwenCodingPlan)
        case .anthropicAPICompatible:
            return self.text(.providerPresetAnthropicAPICompatible)
        case .googleGeminiCompatible:
            return self.text(.providerPresetGoogleGeminiCompatible)
        }
    }

    func accountProviderPresetText(_ account: AccountSummary) -> String? {
        guard account.authMode.isManualAPIKey else { return nil }
        return self.providerPresetText(account.providerPreset)
    }

    func manualAPIKeyProviderPresetHelp(_ preset: OpenAICompatibleProviderPreset) -> String {
        switch preset {
        case .genericOpenAICompatible:
            return self.text(.helperManualAccountGenericOpenAICompatible)
        case .aliyunQwenCodingPlan:
            return self.text(.helperManualAccountAliyunCodingPlan)
        case .anthropicAPICompatible:
            return self.text(.helperManualAccountAnthropicAPICompatible)
        case .googleGeminiCompatible:
            return self.text(.helperManualAccountGoogleGeminiCompatible)
        }
    }

    func manualAPIKeyUpstreamAdapterText(_ adapter: ManualAPIKeyUpstreamAdapter) -> String {
        switch adapter {
        case .responses:
            return self.text(.optionUpstreamAdapterResponses)
        case .chatCompletions:
            return self.text(.optionUpstreamAdapterChatCompletions)
        }
    }

    func chatCompatibilityProfileText(_ profile: ChatCompletionsCompatibilityProfile) -> String {
        switch profile {
        case .auto:
            return self.text(.optionChatCompatibilityAuto)
        case .generic:
            return self.text(.optionChatCompatibilityGeneric)
        case .genericStrict:
            return self.text(.optionChatCompatibilityGenericStrict)
        case .deepSeekV4Thinking:
            return self.text(.optionChatCompatibilityDeepSeekV4Thinking)
        case .deepSeekLegacyReasoner:
            return self.text(.optionChatCompatibilityDeepSeekLegacyReasoner)
        case .mimoStrict:
            return self.text(.optionChatCompatibilityMiMoStrict)
        case .minimaxStrict:
            return self.text(.optionChatCompatibilityMiniMaxStrict)
        case .senseNovaStrict:
            return self.text(.optionChatCompatibilitySenseNovaStrict)
        case .kimiStrict:
            return self.text(.optionChatCompatibilityKimiStrict)
        }
    }

    func manualAPIKeyBaseURLPlaceholder(for preset: OpenAICompatibleProviderPreset) -> String {
        switch preset {
        case .genericOpenAICompatible:
            return self.text(.placeholderManualAccountBaseURL)
        case .aliyunQwenCodingPlan:
            return self.text(.placeholderAliyunCodingPlanBaseURL)
        case .anthropicAPICompatible:
            return self.text(.placeholderAnthropicAPICompatibleBaseURL)
        case .googleGeminiCompatible:
            return self.text(.placeholderGoogleGeminiCompatibleBaseURL)
        }
    }

    func manualAPIKeyDraft(
        _ draft: ManualAPIKeyDraft,
        updatingProviderPreset providerPreset: OpenAICompatibleProviderPreset
    ) -> ManualAPIKeyDraft {
        var updated = draft
        let previous = updated.providerPreset
        if previous == providerPreset {
            return updated
        }
        updated.providerPreset = providerPreset
        if providerPreset != .genericOpenAICompatible {
            updated.upstreamAdapter = .responses
            updated.chatCompatibilityProfile = .auto
        }

        let currentBaseURL = updated.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousDefault = previous.defaultBaseURL
        let shouldReplaceBaseURL = currentBaseURL.isEmpty
            || self.normalizedBaseURLIfPossible(currentBaseURL, providerPreset: previous)
                == self.normalizedBaseURLIfPossible(previousDefault, providerPreset: previous)
            || currentBaseURL == previousDefault
        if shouldReplaceBaseURL {
            updated.baseURL = providerPreset.defaultBaseURL
        }
        return updated
    }

    func manualAPIKeyDraft(
        _ draft: ManualAPIKeyDraft,
        updatingUpstreamAdapter upstreamAdapter: ManualAPIKeyUpstreamAdapter
    ) -> ManualAPIKeyDraft {
        var updated = draft
        guard updated.providerPreset == .genericOpenAICompatible else {
            updated.upstreamAdapter = .responses
            return updated
        }

        updated.upstreamAdapter = upstreamAdapter
        if upstreamAdapter != .chatCompletions {
            updated.chatCompatibilityProfile = .auto
        }
        return updated
    }

    func updateManualAPIKeyProviderPreset(_ providerPreset: OpenAICompatibleProviderPreset) {
        guard let draft = self.manualAPIKeyDraft else { return }
        self.manualAPIKeyDraft = self.manualAPIKeyDraft(
            draft,
            updatingProviderPreset: providerPreset
        )
    }

    func providerFamilyTone(_ providerFamily: AccountProviderFamily) -> StatusPill.Tone {
        switch providerFamily {
        case .openAI:
            return .accent
        case .anthropic:
            return .warning
        case .gemini:
            return .success
        }
    }

    func proxyDataSourceTone(_ dataSource: ProxyDataSource) -> StatusPill.Tone {
        switch dataSource {
        case .all:
            return .neutral
        case .openAI:
            return self.providerFamilyTone(.openAI)
        case .anthropic:
            return self.providerFamilyTone(.anthropic)
        case .gemini:
            return self.providerFamilyTone(.gemini)
        }
    }

    func oauthLoginTitle(for providerFamily: AccountProviderFamily) -> String {
        switch providerFamily {
        case .openAI:
            return self.localized(zh: "OpenAI 登录", en: "OpenAI Login")
        case .anthropic:
            return self.localized(zh: "Anthropic 登录", en: "Anthropic Login")
        case .gemini:
            return self.localized(zh: "Google / Gemini 登录", en: "Google / Gemini Login")
        }
    }

    func oauthQuickActionHelp(for providerFamily: AccountProviderFamily) -> String {
        switch providerFamily {
        case .openAI:
            return self.localized(
                zh: "通过浏览器登录 OpenAI / ChatGPT，并在授权成功后自动导入账号。",
                en: "Sign in to OpenAI / ChatGPT in the browser and import the account when authorization completes."
            )
        case .anthropic:
            return self.localized(
                zh: "通过浏览器登录 Anthropic / Claude，并在授权成功后自动导入账号。",
                en: "Sign in to Anthropic / Claude in the browser and import the account when authorization completes."
            )
        case .gemini:
            return self.localized(
                zh: "通过浏览器登录个人 Google / Gemini 账号，并在授权成功后自动导入。这个账号类型现在只用于官方 Gemini CLI / 原生 Gemini endpoint，不参与普通 `/v1` 兼容路由。",
                en: "Sign in to a personal Google / Gemini account in the browser and import it after authorization. This account type is now reserved for the official Gemini CLI and native Gemini endpoint only, and is not used for regular `/v1` compatibility routing."
            )
        }
    }

    func oauthFlowTitle(for providerFamily: AccountProviderFamily) -> String {
        switch providerFamily {
        case .openAI:
            return self.localized(zh: "OpenAI 网页授权", en: "OpenAI Web Sign-In")
        case .anthropic:
            return self.localized(zh: "Anthropic 网页授权", en: "Anthropic Web Sign-In")
        case .gemini:
            return self.localized(zh: "Google / Gemini 网页授权", en: "Google / Gemini Web Sign-In")
        }
    }

    func oauthExpectedAuthMode(for providerFamily: AccountProviderFamily) -> AccountAuthMode {
        switch providerFamily {
        case .openAI:
            return .chatGPT
        case .anthropic:
            return .anthropicSubscriptionOAuth
        case .gemini:
            return .geminiOAuth
        }
    }

    func oauthBaselineUpdatedAtByAccountKey(from accounts: [AccountSummary]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.accountKey, $0.updatedAt) })
    }

    func observedImportedOAuthAccount(
        in accounts: [AccountSummary],
        expectedAuthMode: AccountAuthMode,
        baselineUpdatedAtByAccountKey: [String: Int64]
    ) -> AccountSummary? {
        accounts
            .filter { $0.authMode == expectedAuthMode }
            .filter { account in
                guard let baselineUpdatedAt = baselineUpdatedAtByAccountKey[account.accountKey] else {
                    return true
                }
                return account.updatedAt > baselineUpdatedAt
            }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    func oauthManualHint(for providerFamily: AccountProviderFamily) -> String {
        switch providerFamily {
        case .openAI:
            return self.localized(
                zh: "OpenAI 浏览器登录已经在本地回调地址上等待。如果浏览器没有自动完成导入，把最终回调链接粘贴到这里即可。",
                en: "The local callback listener is ready for OpenAI sign-in. If the browser does not complete the import automatically, paste the final callback URL here."
            )
        case .anthropic:
            return self.localized(
                zh: "Anthropic 浏览器登录已经在本地回调地址上等待。如果浏览器没有自动完成导入，把最终回调链接粘贴到这里即可。",
                en: "The local callback listener is ready for Anthropic sign-in. If the browser does not complete the import automatically, paste the final callback URL here."
            )
        case .gemini:
            return self.localized(
                zh: "Google / Gemini 浏览器登录已经在本地回调地址上等待。如果浏览器没有自动完成导入，把最终回调链接粘贴到这里即可。",
                en: "The local callback listener is ready for Google / Gemini sign-in. If the browser does not complete the import automatically, paste the final callback URL here."
            )
        }
    }

    func proxyDataSourceDetailText(_ dataSource: ProxyDataSource) -> String {
        switch dataSource {
        case .all:
            return self.localized(
                zh: "按账号顺序在全部可用上游里自动选择；下游请求协议会继续由本地代理做兼容转换。",
                en: "Automatically pick from every available upstream account in order while the local proxy keeps handling downstream protocol translation."
            )
        case .openAI:
            return self.localized(
                zh: "只从 OpenAI 账号池取上游数据源；仍可服务 Codex 和 Claude 协议请求。",
                en: "Only route to the OpenAI account pool. This key can still serve Codex and Claude protocol clients."
            )
        case .anthropic:
            return self.localized(
                zh: "只从 Anthropic 账号池取上游数据源；仍可服务 Claude 和 OpenAI-compatible 请求。",
                en: "Only route to the Anthropic account pool. This key can still serve Claude and OpenAI-compatible clients."
            )
        case .gemini:
            return self.localized(
                zh: "只从 Google / Gemini 账号池取上游数据源；Gemini 公共 POST 路由现在只服务官方 Gemini CLI，会话执行需要 `Google / Gemini Login` 账号。",
                en: "Only route to the Google / Gemini account pool. Gemini public POST routes now serve official Gemini CLI traffic only, and execution requires a `Google / Gemini Login` account."
            )
        }
    }

    func canRenameAccount(_ account: AccountSummary) -> Bool {
        account.authMode.isManualAPIKey == false
    }

    func isAccountManagedProxyNodeUnavailable(_ account: AccountSummary) -> Bool {
        guard let nodeName = AccountSummary.normalizedManagedProxyNodeName(account.managedProxyNodeName),
              !self.availableManagedProxyNodeNames.isEmpty
        else {
            return false
        }
        return self.availableManagedProxyNodeNames.contains(nodeName) == false
    }

    func accountManagedProxyNodeStatusText(_ account: AccountSummary) -> String {
        guard let nodeName = AccountSummary.normalizedManagedProxyNodeName(account.managedProxyNodeName) else {
            return self.localized(zh: "跟随全局", en: "Use Global")
        }
        guard self.isAccountManagedProxyNodeUnavailable(account) == false else {
            return self.localized(zh: "节点不可用：\(nodeName)", en: "Node unavailable: \(nodeName)")
        }
        return nodeName
    }

    func accountModelRoutingStatusText(_ account: AccountSummary) -> String {
        guard let modelRouting = AccountSummary.normalizedModelRouting(account.modelRouting) else {
            return self.localized(zh: "未配置", en: "Not Configured")
        }

        let mappingCount = modelRouting.mappings.count
        let defaultTargetModel = modelRouting.defaultTargetModel

        if let defaultTargetModel, mappingCount > 0 {
            return self.localized(
                zh: "默认 -> \(defaultTargetModel) · \(mappingCount) 条映射",
                en: "Default -> \(defaultTargetModel) · \(mappingCount) mappings"
            )
        }
        if let defaultTargetModel {
            return self.localized(
                zh: "默认 -> \(defaultTargetModel)",
                en: "Default -> \(defaultTargetModel)"
            )
        }
        if mappingCount > 0 {
            return self.localized(
                zh: "\(mappingCount) 条映射",
                en: "\(mappingCount) mappings"
            )
        }
        return self.localized(zh: "未配置", en: "Not Configured")
    }

    func accountModelRoutingHint() -> String {
        self.localized(
            zh: "账号映射优先，其次是账号默认目标模型。两者都未命中时，Anthropic / Claude 请求才会继续回退到设置页里的全局 Anthropic 模型映射；其它请求再回到各自现有的默认模型解析。",
            en: "Exact account mappings win first, then the account default target model. When neither matches, Anthropic / Claude requests still fall back to the global Anthropic model mapping from Proxy, and other requests continue using their existing default model resolution."
        )
    }

    func accountReasoningEffortHint() -> String {
        self.text(.helperAccountReasoningEffort)
    }

    func accountReasoningEffortStatusText(for draft: AccountReasoningEffortDraft) -> String {
        [
            "\(self.text(.labelReasoningEffortLow)) -> \(draft.low.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "low" : draft.low)",
            "\(self.text(.labelReasoningEffortMedium)) -> \(draft.medium.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "medium" : draft.medium)",
            "\(self.text(.labelReasoningEffortHigh)) -> \(draft.high.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "high" : draft.high)",
            "\(self.text(.labelReasoningEffortXHigh)) -> \(draft.xhigh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "xhigh" : draft.xhigh)",
        ].joined(separator: " · ")
    }

    func accountModelRoutingTargetHint() -> String {
        self.localized(
            zh: "目标模型会按原样发给该账号的上游，不会再经过 provider preset 的二次改写。模型名匹配采用 trim 后精确匹配，区分大小写。",
            en: "Target models are sent upstream for this account as-is without another provider preset remap. Source model matching uses trimmed exact matches and remains case-sensitive."
        )
    }

    func accountManagedProxyNodePickerHint() -> String {
        if self.availableManagedProxyNodeNames.isEmpty {
            return self.localized(
                zh: "当前没有可用的订阅节点。你仍然可以把这个账号清空为“不自定义 / 跟随全局”；只要后续节点恢复可用，账号级覆盖仍会继续优先于设置页全局模式。",
                en: "No subscription nodes are currently available. You can still clear this account back to Use Global. Whenever nodes become available again, the account override will still take priority over Settings."
            )
        }
        return self.localized(
            zh: "留空表示不自定义，继续跟随设置页当前的全局出站模式。只要这里选了节点，这个账号就会优先走该出站节点，不再跟随设置页默认出口。",
            en: "Leave this empty to keep following the current global outbound mode from Settings. As soon as you choose a node here, this account prefers that outbound node over the Settings default."
        )
    }

    func accountManagedProxyNodeUnavailableWarning(for draft: AccountManagedProxyNodeDraft) -> String? {
        guard let nodeName = AccountSummary.normalizedManagedProxyNodeName(draft.managedProxyNodeName) else { return nil }
        return self.accountManagedProxyNodeIssueText(nodeName: nodeName)
    }

    func accountIssueText(_ account: AccountSummary) -> String? {
        if let nodeName = AccountSummary.normalizedManagedProxyNodeName(account.managedProxyNodeName),
           let issue = self.accountManagedProxyNodeIssueText(nodeName: nodeName)
        {
            return issue
        }
        return self.accountRuntimeIssueText(account)
    }

    private func accountManagedProxyNodeIssueText(nodeName: String) -> String? {
        if !self.availableManagedProxyNodeNames.isEmpty,
           self.availableManagedProxyNodeNames.contains(nodeName) == false
        {
            return self.localized(
                zh: "已保存的自定义出站节点 `\(nodeName)` 当前不在订阅列表中。这个账号会在请求前直接失败，直到你清空为跟随全局或重新选择节点。",
                en: "The saved custom outbound node `\(nodeName)` is no longer in the current subscription list. Requests for this account will fail before sending until you clear it back to Use Global or choose another node."
            )
        }
        if self.managedProxySnapshot.subscriptionConfigured == false {
            return self.localized(
                zh: "已保存的自定义出站节点 `\(nodeName)` 需要可用的订阅配置。这个账号会在请求前直接失败，直到你补充订阅地址，或清空为跟随全局。",
                en: "The saved custom outbound node `\(nodeName)` requires a working subscription configuration. Requests for this account will fail before sending until you provide a subscription URL or clear it back to Use Global."
            )
        }
        if self.status?.running == false {
            return self.localized(
                zh: "已保存的自定义出站节点 `\(nodeName)` 依赖本地订阅服务。当前本地服务未运行，这个账号会在请求前直接失败，直到你恢复服务或清空为跟随全局。",
                en: "The saved custom outbound node `\(nodeName)` depends on the local subscription service. The local daemon is currently offline, so requests for this account will fail before sending until you restart it or clear the override."
            )
        }
        if self.status?.running == true,
           self.managedProxySnapshot.listeners.contains(where: {
               $0.kind == .nodeListener
                   && AccountSummary.normalizedManagedProxyNodeName($0.nodeName) == nodeName
           }) == false
        {
            return self.localized(
                zh: "已保存的自定义出站节点 `\(nodeName)` 当前监听端口不可用。这个账号会在请求前直接失败，直到你重新选择节点、修复订阅环境，或清空为跟随全局。",
                en: "The saved custom outbound node `\(nodeName)` does not currently have a usable listener port. Requests for this account will fail before sending until you choose another node, repair the subscription environment, or clear the override."
            )
        }
        return nil
    }

    func accountSelectionDuplicateLabels(in accounts: [AccountSummary]) -> Set<String> {
        Set(
            Dictionary(grouping: accounts) { account in
                account.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
                .filter { key, groupedAccounts in !key.isEmpty && groupedAccounts.count > 1 }
                .map(\.key)
        )
    }

    func accountSelectionOptionTitle(
        for account: AccountSummary,
        duplicateLabels: Set<String>
    ) -> String {
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard duplicateLabels.contains(label.lowercased()) else {
            return label
        }

        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !email.isEmpty {
            return "\(label) · \(email)"
        }

        let accountID = account.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accountID.isEmpty {
            return "\(label) · \(accountID)"
        }

        return label
    }

    func remoteHostSelectionID() -> String {
        if self.selectedRemoteHost.id.isEmpty, let first = self.savedRemoteHosts.first {
            return first.id
        }
        return self.selectedRemoteHost.id
    }

    var currentRemoteLogs: String {
        self.remoteLogsByHostID[self.selectedRemoteHost.id] ?? ""
    }

    var selectedRemoteConnectionCheck: RemoteConnectionCheck? {
        self.remoteConnectionChecksByHostID[self.selectedRemoteHost.id]
    }

    var selectedRemoteConnectionError: String? {
        self.remoteConnectionErrorsByHostID[self.selectedRemoteHost.id]
    }

    var selectedRemoteHostDisplayName: String {
        let label = self.selectedRemoteHost.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }

        let host = self.selectedRemoteHost.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            return host
        }

        return self.text(.remoteTitle)
    }

    func selectRemoteHost(id: String) {
        guard let host = self.savedRemoteHosts.first(where: { $0.id == id }) else { return }
        self.selectedRemoteHost = host
        self.selectedRemoteWorkflowStep = .configuration
    }

    func selectRemoteWorkflowStep(_ step: RemoteWorkflowStep) {
        guard self.canEnterRemoteWorkflowStep(step) else {
            self.syncRemoteWorkflowStepForSelectedHost()
            return
        }
        self.selectedRemoteWorkflowStep = step
    }

    func advanceRemoteWorkflowStep() {
        guard let next = RemoteWorkflowStep(rawValue: self.selectedRemoteWorkflowStep.rawValue + 1) else { return }
        self.selectRemoteWorkflowStep(next)
    }

    func retreatRemoteWorkflowStep() {
        guard let previous = RemoteWorkflowStep(rawValue: self.selectedRemoteWorkflowStep.rawValue - 1) else { return }
        self.selectedRemoteWorkflowStep = previous
    }

    func isSelectedRemoteHostSaved() -> Bool {
        self.savedRemoteHosts.contains(where: { $0.id == self.selectedRemoteHost.id })
    }

    func hasUnsavedRemoteHostChanges() -> Bool {
        guard let saved = self.savedRemoteHosts.first(where: { $0.id == self.selectedRemoteHost.id }) else {
            return true
        }
        return saved != self.selectedRemoteHost
    }

    func canSaveSelectedRemoteHost() -> Bool {
        self.remoteHostValidationMessage(for: self.selectedRemoteHost) == nil
    }

    func canDeleteSelectedRemoteHost() -> Bool {
        self.isSelectedRemoteHostSaved() && !self.isRemoteDeleting(hostID: self.selectedRemoteHost.id)
    }

    func canOpenRemoteAdminWindow(for hostID: String) -> Bool {
        guard self.isSelectedRemoteHostSaved(),
              self.selectedRemoteHost.id == hostID,
              self.canManageRemoteHostOperations(for: hostID),
              let status = self.remoteStatuses[hostID]
        else {
            return false
        }
        return status.running
    }

    func openSelectedRemoteAdminWindow() {
        let host = self.selectedRemoteHost
        let hostID = host.id
        guard !hostID.isEmpty, self.canOpenRemoteAdminWindow(for: hostID) else { return }

        if let controller = self.remoteAdminWindowControllers[hostID] {
            controller.refreshWindow(preferences: self.preferences)
            controller.showWindow()
            return
        }

        let controller = self.remoteAdminWindowFactory(
            host,
            self.preferences,
            self.remoteDeploy,
            { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRemoteAdminWindowDidClose(hostID: hostID)
                }
            },
            { [weak self] adminPort in
                guard let self else {
                    return .failed("The desktop app is no longer available to sync the remote admin port.")
                }
                return await self.syncRemoteAdminDiscoveredPort(hostID: hostID, adminPort: adminPort)
            }
        )
        self.remoteAdminWindowControllers[hostID] = controller
        controller.showWindow()
    }

    func dismissRemoteAdminWindow(hostID: String) {
        self.remoteAdminWindowControllers[hostID]?.closeWindow()
    }

    func canEnterRemoteWorkflowStep(_ step: RemoteWorkflowStep) -> Bool {
        switch step {
        case .hosts, .configuration:
            return true
        case .verification:
            return self.isSelectedRemoteHostSaved() && !self.hasUnsavedRemoteHostChanges()
        case .operations:
            return self.canManageRemoteHostOperations(for: self.selectedRemoteHost.id)
        }
    }

    private func handleRemoteAdminWindowDidClose(hostID: String) {
        self.remoteAdminWindowControllers[hostID] = nil
    }

    func remoteWorkflowStepTitle(_ step: RemoteWorkflowStep) -> String {
        switch step {
        case .hosts:
            return self.text(.remoteWorkflowHostsTitle)
        case .configuration:
            return self.text(.remoteWorkflowConfigurationTitle)
        case .verification:
            return self.text(.remoteWorkflowVerificationTitle)
        case .operations:
            return self.text(.remoteWorkflowOperationsTitle)
        }
    }

    func remoteWorkflowStepSubtitle(_ step: RemoteWorkflowStep) -> String {
        switch step {
        case .hosts:
            return self.text(.remoteWorkflowHostsSubtitle)
        case .configuration:
            return self.text(.remoteWorkflowConfigurationSubtitle)
        case .verification:
            return self.text(.remoteWorkflowVerificationSubtitle)
        case .operations:
            return self.text(.remoteWorkflowOperationsSubtitle)
        }
    }

    func remoteWorkflowStepStatusText(_ step: RemoteWorkflowStep) -> String {
        switch step {
        case .hosts:
            return self.savedRemoteHosts.isEmpty ? self.text(.statusNoData) : "\(self.savedRemoteHosts.count)"
        case .configuration:
            return self.isSelectedRemoteHostSaved() && !self.hasUnsavedRemoteHostChanges()
                ? self.text(.statusReady)
                : self.localized(zh: "草稿", en: "Draft")
        case .verification:
            if self.hasSuccessfulRemoteManagementCheck(for: self.selectedRemoteHost.id) {
                return self.text(.statusReady)
            }
            if self.selectedRemoteConnectionError?.isEmpty == false {
                return self.text(.statusFailed)
            }
            if self.selectedRemoteConnectionCheck != nil {
                return self.text(.statusUnavailable)
            }
            return self.text(.statusNoData)
        case .operations:
            return self.canEnterRemoteWorkflowStep(.operations) ? self.text(.statusReady) : self.text(.statusUnavailable)
        }
    }

    func remoteWorkflowStepTone(_ step: RemoteWorkflowStep) -> StatusPill.Tone {
        switch step {
        case .hosts:
            return self.savedRemoteHosts.isEmpty ? .warning : .accent
        case .configuration:
            return self.isSelectedRemoteHostSaved() && !self.hasUnsavedRemoteHostChanges() ? .success : .neutral
        case .verification:
            if self.hasSuccessfulRemoteManagementCheck(for: self.selectedRemoteHost.id) {
                return .success
            }
            if self.selectedRemoteConnectionError?.isEmpty == false {
                return .danger
            }
            if self.selectedRemoteConnectionCheck != nil {
                return .warning
            }
            return .neutral
        case .operations:
            return self.canEnterRemoteWorkflowStep(.operations) ? .success : .neutral
        }
    }

    func canManageRemoteHostOperations(for hostID: String) -> Bool {
        guard !hostID.isEmpty,
              self.isSelectedRemoteHostSaved(),
              self.selectedRemoteHost.id == hostID,
              !self.hasUnsavedRemoteHostChanges()
        else {
            return false
        }
        return self.hasSuccessfulRemoteManagementCheck(for: hostID)
    }

    func canDeployRemoteHost(for hostID: String) -> Bool {
        self.canManageRemoteHostOperations(for: hostID) && self.hasSuccessfulRemoteDeployCheck(for: hostID)
    }

    func remoteDeployActionMode(for hostID: String) -> RemoteDeployActionMode {
        self.remoteStatuses[hostID]?.installed == true ? .redeploy : .deploy
    }

    func remoteDeployButtonTitle(for hostID: String) -> String {
        switch self.remoteDeployActionMode(for: hostID) {
        case .deploy:
            return self.isRemoteDeploying(hostID: hostID) ? self.text(.statusDeploying) : self.text(.actionDeploy)
        case .redeploy:
            return self.isRemoteDeploying(hostID: hostID) ? self.text(.statusRedeploying) : self.text(.actionRedeploy)
        }
    }

    func remoteDeployButtonHelpText(for hostID: String) -> String {
        if let disabledMessage = self.remoteDeployDisabledMessage(for: hostID) {
            return disabledMessage
        }

        switch self.remoteDeployActionMode(for: hostID) {
        case .deploy:
            return self.remoteWorkflowStepSubtitle(.operations)
        case .redeploy:
            return self.text(.helperRemoteRedeploy)
        }
    }

    func hasSuccessfulRemoteManagementCheck(for hostID: String) -> Bool {
        guard let check = self.remoteConnectionChecksByHostID[hostID] else { return false }
        return check.remoteDirectoryWritable
            && check.systemctlAvailable
            && check.sudoAvailable
    }

    func hasSuccessfulRemoteDeployCheck(for hostID: String) -> Bool {
        guard let check = self.remoteConnectionChecksByHostID[hostID] else { return false }
        return self.hasSuccessfulRemoteManagementCheck(for: hostID) && check.localArtifactAvailable
    }

    func remoteDeployDisabledMessage(for hostID: String) -> String? {
        guard self.canManageRemoteHostOperations(for: hostID),
              let check = self.remoteConnectionChecksByHostID[hostID],
              !check.localArtifactAvailable
        else {
            return nil
        }
        return self.text(.helperRemoteDeployUnavailable)
    }

    func remoteReadinessIssues(for hostID: String) -> [String] {
        if let error = self.remoteConnectionErrorsByHostID[hostID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return [error]
        }

        guard let check = self.remoteConnectionChecksByHostID[hostID] else {
            return [self.text(.helperRemoteNeedsVerification)]
        }

        var issues: [String] = []
        if !check.localArtifactAvailable {
            issues.append(self.remoteBundledArtifactsIssueMessage(for: check))
        }
        if !check.systemctlAvailable {
            issues.append(self.text(.helperRemoteSystemctlUnavailable))
        }
        if !check.sudoAvailable {
            issues.append(self.text(.helperRemoteSudoUnavailable))
        }
        if !check.remoteDirectoryWritable {
            issues.append(self.text(.helperRemoteDirectoryUnavailable))
        }
        return issues
    }

    func remoteReadinessTone(for hostID: String) -> StatusPill.Tone {
        if let error = self.remoteConnectionErrorsByHostID[hostID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return .danger
        }
        return self.remoteReadinessIssues(for: hostID).isEmpty ? .success : .warning
    }

    private func remoteBundledArtifactsIssueMessage(for check: RemoteConnectionCheck) -> String {
        if RemoteDeployArtifactResolver.defaultSearchRoots().isEmpty {
            return self.localized(
                zh: "当前构建不包含应用内置 Linux 部署包。你仍可进入远端运维查看状态、日志并管理已部署服务；若要远程部署，请改用通过 `Scripts/build-macos-app.sh` 或 `Scripts/package-release.sh` 生成的远程部署版应用。",
                en: "This build does not include bundled Linux deployment packages. You can still inspect remote status, logs, and existing service controls, but remote deploy requires the remote-capable app built with `Scripts/build-macos-app.sh` or `Scripts/package-release.sh`."
            )
        }
        return self.localized(
            zh: "当前应用包内没有适用于 `\(check.architecture)` 的完整 Linux 部署包。你仍可进入远端运维管理已部署服务；若要远程部署，请重新打包应用后再试。",
            en: "This app bundle does not include a complete bundled Linux deployment package for `\(check.architecture)`. You can still manage an already deployed remote service, but deploying again requires rebuilding the app bundle."
        )
    }

    func remoteHostValidationMessage(for host: RemoteHostConfig) -> String? {
        if host.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return self.localized(zh: "请填写远程主机地址。", en: "Enter the remote host address.")
        }
        if host.sshUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return self.localized(zh: "请填写 SSH 用户。", en: "Enter the SSH user.")
        }
        if host.sshPort <= 0 {
            return self.localized(zh: "SSH 端口必须大于 0。", en: "SSH port must be greater than 0.")
        }
        if host.publicPort <= 0 || host.adminPort <= 0 {
            return self.localized(zh: "公开端口和管理端口都必须大于 0。", en: "Public and admin ports must both be greater than 0.")
        }
        if host.remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return self.localized(zh: "请填写远程目录。", en: "Enter the remote directory.")
        }

        switch host.authMode {
        case .sshKeyPath:
            break
        case .sshKeyContent:
            if host.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return self.localized(zh: "请粘贴 SSH 私钥内容。", en: "Paste the SSH private key content.")
            }
        case .password:
            if host.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return self.localized(zh: "请填写 SSH 密码。", en: "Enter the SSH password.")
            }
        }

        return nil
    }

    func remoteServiceControlState(for hostID: String) -> RemoteServiceControlState {
        ServiceControlResolver.remoteState(
            status: self.remoteStatuses[hostID],
            loadError: self.remoteServiceLoadErrors[hostID],
            operation: self.remoteOperation,
            hostID: hostID
        )
    }

    func remoteServiceStatusText(for hostID: String) -> String {
        switch self.remoteServiceControlState(for: hostID) {
        case .unloaded:
            return self.text(.statusNoData)
        case .stopped:
            return self.text(.statusStopped)
        case .starting:
            return self.text(.statusStarting)
        case .running:
            return self.text(.statusRunning)
        case .stopping:
            return self.text(.statusStopping)
        case .unreachable:
            return self.text(.statusUnavailable)
        }
    }

    func remoteServiceTone(for hostID: String) -> StatusPill.Tone {
        switch self.remoteServiceControlState(for: hostID) {
        case .unloaded:
            return .neutral
        case .stopped:
            return .warning
        case .starting:
            return .accent
        case .running:
            return .success
        case .stopping:
            return .warning
        case .unreachable:
            return .danger
        }
    }

    func remoteServiceHelperText(for hostID: String) -> String {
        switch self.remoteServiceControlState(for: hostID) {
        case .unloaded:
            return self.text(.helperRemoteStatusRequired)
        case .stopped:
            return self.text(.helperRemoteCanStart)
        case .starting:
            return self.text(.helperRemoteStarting)
        case .running:
            return self.text(.helperRemoteCanStop)
        case .stopping:
            return self.text(.helperRemoteStopping)
        case .unreachable:
            return self.text(.helperRemoteUnreachable)
        }
    }

    func remoteServiceHelperTone(for hostID: String) -> StatusPill.Tone {
        switch self.remoteServiceControlState(for: hostID) {
        case .unloaded:
            return .neutral
        case .stopped:
            return .neutral
        case .starting:
            return .accent
        case .running:
            return .success
        case .stopping:
            return .warning
        case .unreachable:
            return .danger
        }
    }

    func remoteStartButtonTitle(for hostID: String) -> String {
        switch self.remoteServiceControlState(for: hostID) {
        case .starting:
            return self.text(.statusStarting)
        case .running:
            return self.text(.statusRunning)
        case .unloaded, .stopped, .stopping, .unreachable:
            return self.text(.actionStart)
        }
    }

    func remoteStopButtonTitle(for hostID: String) -> String {
        switch self.remoteServiceControlState(for: hostID) {
        case .stopping:
            return self.text(.statusStopping)
        case .stopped:
            return self.text(.statusStopped)
        case .running:
            return self.text(.actionStop)
        case .unloaded, .starting, .unreachable:
            return self.text(.actionStop)
        }
    }

    func remoteCanStartService(for hostID: String) -> Bool {
        self.canManageRemoteHostOperations(for: hostID)
            && self.remoteServiceControlState(for: hostID) == .stopped
            && self.remoteOperation == .idle
    }

    func remoteCanStopService(for hostID: String) -> Bool {
        self.canManageRemoteHostOperations(for: hostID)
            && self.remoteServiceControlState(for: hostID) == .running
            && self.remoteOperation == .idle
    }

    func isRemoteServiceStarting(for hostID: String) -> Bool {
        if case .starting(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func isRemoteServiceStopping(for hostID: String) -> Bool {
        if case .stopping(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func isRemoteSaving(hostID: String?) -> Bool {
        if case .saving(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func isRemoteTesting(hostID: String) -> Bool {
        if case .testing(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func isRemoteDeploying(hostID: String) -> Bool {
        if case .deploying(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func isRemoteStatusLoading(hostID: String) -> Bool {
        if case .loadingStatus(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func isRemoteLogsLoading(hostID: String) -> Bool {
        if case .loadingLogs(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func isRemoteDeleting(hostID: String) -> Bool {
        if case .deleting(let currentHostID) = self.remoteOperation {
            return currentHostID == hostID
        }
        return false
    }

    func updateLanguage(_ mode: DesktopLanguageMode) {
        guard self.preferences.languageMode != mode else { return }
        self.updatePreferences { preferences in
            preferences.languageMode = mode
        }
        DesktopMainMenuController.shared.configure(model: self, snapshot: self.menuLocalizationSnapshot)
    }

    func updateTheme(_ mode: DesktopThemeMode) {
        guard self.preferences.themeMode != mode else { return }
        self.updatePreferences { preferences in
            preferences.themeMode = mode
        }
    }

    func updateAccountPoolDisplayMode(_ mode: DesktopAccountPoolDisplayMode) {
        guard self.preferences.accountPoolDisplayMode != mode else { return }
        self.updatePreferences(showSuccessNotice: false) { preferences in
            preferences.accountPoolDisplayMode = mode
        }
    }

    func updateShowsMenuBarTokenUsage(_ shows: Bool) {
        guard self.preferences.showsMenuBarTokenUsage != shows else { return }
        self.updatePreferences(showSuccessNotice: false) { preferences in
            preferences.showsMenuBarTokenUsage = shows
        }
    }

    var keepAwakeActionTitle: String {
        self.text(self.isKeepAwakeEnabled ? .actionDisableKeepAwake : .actionEnableKeepAwake)
    }

    var keepAwakeSymbolName: String {
        "display"
    }

    var keepAwakeStatusText: String {
        self.text(self.isKeepAwakeEnabled ? .statusKeepAwakeEnabled : .statusKeepAwakeDisabled)
    }

    var keepAwakeStatusTone: StatusPill.Tone {
        self.isKeepAwakeEnabled ? .success : .neutral
    }

    var keepAwakeHelperText: String {
        self.text(.helperKeepAwake)
    }

    func toggleKeepAwake() {
        self.setKeepAwakeEnabled(!self.isKeepAwakeEnabled)
    }

    func setKeepAwakeEnabled(_ isEnabled: Bool) {
        guard self.isKeepAwakeEnabled != isEnabled else { return }

        do {
            try self.keepAwakeController.setEnabled(isEnabled)
            self.isKeepAwakeEnabled = self.keepAwakeController.isEnabled
            self.publishBanner(
                .success,
                title: self.text(isEnabled ? .successKeepAwakeEnabled : .successKeepAwakeDisabled),
                detail: nil
            )
        } catch {
            self.isKeepAwakeEnabled = self.keepAwakeController.isEnabled
            self.publishBanner(
                .error,
                title: self.text(.errorKeepAwakeFailed),
                detail: error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    func releaseKeepAwakeSilently() {
        try? self.keepAwakeController.setEnabled(false)
        self.isKeepAwakeEnabled = self.keepAwakeController.isEnabled
    }

    var switchToMinimalModeButtonTitle: String {
        self.localized(zh: "切换到极简模式", en: "Switch to Minimal Mode")
    }

    var switchToFullModeButtonTitle: String {
        self.localized(zh: "切换到全功能模式", en: "Switch to Full Mode")
    }

    var minimalModeTitle: String {
        self.localized(zh: "极简模式", en: "Minimal Mode")
    }

    var minimalModeSubtitle: String {
        self.localized(
            zh: "把账号添加、出站代理和客户端接入集中到一个页面里，常用配置一步完成。",
            en: "Keep account setup, outbound proxying, and client access on one page for the most common setup flow."
        )
    }

    func interfaceModeSwitchConfirmationContent(to target: DesktopInterfaceMode) -> InterfaceModeSwitchConfirmationContent {
        switch target {
        case .minimal:
            return InterfaceModeSwitchConfirmationContent(
                title: self.localized(zh: "切换到极简模式？", en: "Switch to Minimal Mode?"),
                informativeText: self.localized(
                    zh: "这只会切换界面风格，不会修改账号、代理或 API Key 配置。",
                    en: "This only changes the interface layout. Your accounts, proxy settings, and API keys will stay unchanged."
                ),
                actionTitle: self.switchToMinimalModeButtonTitle
            )
        case .full:
            return InterfaceModeSwitchConfirmationContent(
                title: self.localized(zh: "切换到全功能模式？", en: "Switch to Full Mode?"),
                informativeText: self.localized(
                    zh: "这只会切换界面风格，不会修改账号、代理或 API Key 配置。",
                    en: "This only changes the interface layout. Your accounts, proxy settings, and API keys will stay unchanged."
                ),
                actionTitle: self.switchToFullModeButtonTitle
            )
        }
    }

    func switchInterfaceMode(target: DesktopInterfaceMode, destination: FullModeNavigationDestination? = nil) {
        if self.preferences.interfaceMode == target {
            if target == .full, let destination {
                self.navigateToFullMode(destination)
            } else if target == .minimal {
                self.syncMinimalProxyDraftFromSettingsIfNeeded()
            }
            return
        }

        guard self.confirmInterfaceModeSwitch(to: target) else { return }

        if target == .full, let destination {
            self.navigateToFullMode(destination)
        } else if target == .minimal {
            self.syncMinimalProxyDraftFromSettingsIfNeeded()
        }

        self.updatePreferences(showSuccessNotice: false) { preferences in
            preferences.interfaceMode = target
        }
    }

    private func navigateToFullMode(_ destination: FullModeNavigationDestination) {
        switch destination {
        case .page(let page):
            guard self.canOpenPage(page) else { return }
            self.selectedPage = page
        case .proxyAccess:
            self.selectedProxyWorkspaceTab = .access
            self.selectedPage = .proxy
        case .settingsProxy:
            self.selectedSettingsTab = .proxy
            self.selectedPage = .settings
        }
    }

    private func confirmInterfaceModeSwitch(to target: DesktopInterfaceMode) -> Bool {
        if let confirmInterfaceModeSwitchHandler {
            return confirmInterfaceModeSwitchHandler(target)
        }

        let content = self.interfaceModeSwitchConfirmationContent(to: target)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func clearBanner() {
        withAnimation(.easeInOut(duration: 0.18)) {
            self.banners.removeAll()
        }
    }

    func dismissBanner(id: BannerState.ID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            self.banners.removeAll { $0.id == id }
        }
    }

    func loadAll() async {
        self.isBusy = true
        defer { self.isBusy = false }

        var firstError: (Error, OperationContext)?
        var didResolveStatusDuringAutoStartWait = false
        var shouldLoadAdminData = true
        do {
            self.settings = try await self.admin.getSettings()
            self.syncMinimalProxyDraftFromSettingsIfNeeded()
            self.syncSettingsOutboundProxyDraftFromSettingsIfNeeded()
            self.syncSelectedRemoteHost()
            self.localServiceStatus = await self.daemon.status()
        } catch {
            firstError = firstError ?? (error, .loadAll)
        }

        if firstError == nil {
            do {
                try await self.daemon.prepareForLaunch(config: self.settings)
                self.localServiceStatus = await self.daemon.status()
                if self.settings.autoStart {
                    if let readyStatus = await self.resolveReadyLocalDaemonStatus(refreshLocalStatus: false) {
                        self.status = readyStatus
                        didResolveStatusDuringAutoStartWait = true
                    } else if let readyStatus = await self.waitForLocalDaemonReadyAfterAutoStart() {
                        self.status = readyStatus
                        didResolveStatusDuringAutoStartWait = true
                    } else {
                        firstError = firstError ?? (self.autoStartDaemonReadinessTimeoutError(), .startDaemon)
                        shouldLoadAdminData = false
                    }
                }
            } catch {
                firstError = firstError ?? (error, .startDaemon)
            }
        }

        if shouldLoadAdminData {
            do {
                if didResolveStatusDuringAutoStartWait == false {
                    self.status = try await self.admin.getStatus()
                }
            } catch {
                firstError = firstError ?? (error, .loadAll)
            }

            do {
                self.accounts = try await self.admin.getAccounts()
            } catch {
                firstError = firstError ?? (error, .loadAll)
            }

            do {
                self.stats = try await self.admin.getStats(apiKey: self.overviewTrafficStatsAPIKeyValue)
            } catch {
                firstError = firstError ?? (error, .loadAll)
            }

            do {
                self.proxyAPIKeyUsageReport = try await self.admin.getProxyAPIKeyUsage(query: self.proxyAPIKeyUsageFilter.query)
            } catch {
                firstError = firstError ?? (error, .loadAll)
            }

            do {
                let snapshot = try await self.admin.getManagedProxySnapshot()
                self.syncManagedProxySnapshotState(snapshot)
            } catch {
                firstError = firstError ?? (error, .loadAll)
            }
        }

        if let firstError {
            self.present(error: firstError.0, context: firstError.1)
        }
    }

    private func resolveReadyLocalDaemonStatus(refreshLocalStatus: Bool) async -> ProxyStatus? {
        if refreshLocalStatus {
            self.localServiceStatus = await self.daemon.status()
        }
        guard self.localServiceStatus?.running == true else { return nil }
        do {
            let status = try await self.admin.getStatus()
            guard status.running else { return nil }
            return status
        } catch {
            return nil
        }
    }

    private func waitForLocalDaemonReadyAfterAutoStart() async -> ProxyStatus? {
        let previousOperation = self.localServiceOperation
        self.localServiceOperation = .starting
        defer { self.localServiceOperation = previousOperation }

        for _ in 0..<Self.autoStartReadinessPollAttempts {
            await self.daemon.sleep(for: Self.autoStartReadinessPollInterval)
            if let status = await self.resolveReadyLocalDaemonStatus(refreshLocalStatus: true) {
                return status
            }
        }
        return nil
    }

    private func autoStartDaemonReadinessTimeoutError() -> Error {
        ProxyError.message(
            self.localized(
                zh: "本地服务在 10 秒内没有完成启动，请查看本地日志后重试。",
                en: "The local service did not finish starting within 10 seconds. Check the local logs and try again."
            )
        )
    }

    func startStatsAutoRefreshIfNeeded(immediately: Bool = true) {
        guard self.statsAutoRefreshTask == nil else { return }

        self.statsAutoRefreshGeneration += 1
        let generation = self.statsAutoRefreshGeneration
        let interval = self.statsAutoRefreshInterval
        self.statsAutoRefreshTask = Task { [weak self] in
            await self?.runStatsAutoRefreshLoop(generation: generation, interval: interval, immediately: immediately)
        }
    }

    func stopStatsAutoRefresh() {
        self.statsAutoRefreshGeneration += 1
        self.statsAutoRefreshTask?.cancel()
        self.statsAutoRefreshTask = nil
    }

    func startAdminEventStreamIfNeeded() {
        guard self.adminEventStreamTask == nil else { return }

        self.adminEventStreamGeneration += 1
        let generation = self.adminEventStreamGeneration
        self.adminEventStreamTask = Task { [weak self] in
            await self?.runAdminEventStreamLoop(generation: generation)
        }
    }

    func stopAdminEventStream() {
        self.adminEventStreamGeneration += 1
        self.adminEventStreamTask?.cancel()
        self.adminEventStreamTask = nil
        self.adminEventStatsRefreshTask?.cancel()
        self.adminEventStatsRefreshTask = nil
    }

    private func runStatsAutoRefreshLoop(
        generation: UInt64,
        interval: Duration,
        immediately: Bool
    ) async {
        defer {
            if self.statsAutoRefreshGeneration == generation {
                self.statsAutoRefreshTask = nil
            }
        }

        if immediately {
            await self.refreshStatsSilently(generation: generation)
        }

        while Task.isCancelled == false {
            do {
                try await Task.sleep(for: interval)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard Task.isCancelled == false, self.statsAutoRefreshGeneration == generation else {
                return
            }
            await self.refreshStatsSilently(generation: generation)
        }
    }

    private func refreshStatsSilently(generation: UInt64) async {
        do {
            let stats = try await self.admin.getStats(apiKey: self.overviewTrafficStatsAPIKeyValue)
            try Task.checkCancellation()
            guard self.statsAutoRefreshGeneration == generation else { return }
            self.stats = stats
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func runAdminEventStreamLoop(generation: UInt64) async {
        defer {
            if self.adminEventStreamGeneration == generation {
                self.adminEventStreamTask = nil
            }
        }

        var reconnectDelay = max(1, self.adminEventReconnectInitialDelaySeconds)
        let maxReconnectDelay = max(reconnectDelay, self.adminEventReconnectMaxDelaySeconds)
        while Task.isCancelled == false, self.adminEventStreamGeneration == generation {
            do {
                let stream = try await self.admin.streamAdminEvents()
                reconnectDelay = max(1, self.adminEventReconnectInitialDelaySeconds)
                for try await event in stream {
                    guard Task.isCancelled == false, self.adminEventStreamGeneration == generation else {
                        return
                    }
                    await self.handleAdminEvent(event, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                // The 30-second stats polling loop remains the fallback while the event stream reconnects.
            }

            guard Task.isCancelled == false, self.adminEventStreamGeneration == generation else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(reconnectDelay))
            } catch {
                return
            }
            reconnectDelay = min(maxReconnectDelay, reconnectDelay * 2)
        }
    }

    private func handleAdminEvent(_ event: AdminEvent, generation: UInt64) async {
        switch event.type {
        case .requestLogged, .statsChanged:
            self.scheduleStatsRefreshFromAdminEvent(generation: generation)
        }
    }

    private func scheduleStatsRefreshFromAdminEvent(generation: UInt64) {
        self.adminEventStatsRefreshTask?.cancel()
        let debounce = self.adminEventStatsRefreshDebounce
        self.adminEventStatsRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            await self?.refreshStatsFromAdminEvent(generation: generation)
        }
    }

    private func refreshStatsFromAdminEvent(generation: UInt64) async {
        guard self.adminEventStreamGeneration == generation else { return }
        do {
            let stats = try await self.admin.getStats(apiKey: self.overviewTrafficStatsAPIKeyValue)
            try Task.checkCancellation()
            guard self.adminEventStreamGeneration == generation else { return }
            self.stats = stats
        } catch {
            return
        }
    }

    func startDaemon() async {
        guard self.localCanStartService else { return }
        self.isBusy = true
        self.localServiceOperation = .starting
        defer {
            self.localServiceOperation = .idle
            self.isBusy = false
        }
        do {
            try await self.daemon.start(config: self.settings)
            await self.refreshLocalServiceSnapshot(refreshRelatedData: true)
            self.publishSuccess(.startDaemon)
            if self.isProxyTestPresented {
                await self.refreshProxyTestConsole()
            }
        } catch {
            await self.refreshLocalServiceSnapshot()
            self.present(error: error, context: .startDaemon)
        }
    }

    func stopDaemon() async {
        guard self.localCanStopService else { return }
        guard self.confirmStopDaemon() else { return }
        await self.performStopDaemon()
    }

    private func performStopDaemon() async {
        self.isBusy = true
        self.localServiceOperation = .stopping
        defer {
            self.localServiceOperation = .idle
            self.isBusy = false
        }
        do {
            self.dismissOAuthDraft()
            try await self.daemon.stop()
            await self.refreshLocalServiceSnapshot()
            if self.isProxyTestPresented {
                await self.refreshProxyTestConsole()
            }
            self.publishSuccess(.stopDaemon)
        } catch {
            await self.refreshLocalServiceSnapshot()
            self.present(error: error, context: .stopDaemon)
        }
    }

    func importCurrentAuth() async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            _ = try await self.admin.importCurrentAuth()
            self.accounts = try await self.admin.getAccounts()
            self.publishSuccess(.importCurrentAuth)
        } catch {
            self.present(error: error, context: .importCurrentAuth)
        }
    }

    func presentAuthImportSheet() {
        self.authImportDraft = AuthImportDraft()
    }

    func dismissAuthImportSheet() {
        guard self.authImportIsSubmitting == false else { return }
        self.authImportDraft = nil
    }

    func submitAuthImportDraft() async {
        guard let draft = self.authImportDraft else { return }
        switch draft.mode {
        case .paste:
            guard let content = self.validatedPastedAuthImportContent(draft.pastedJSON) else { return }
            await self.importAuthJSONItems([
                AuthJsonImportInput(source: "pasted-auth.json", content: content, label: nil),
            ])
        case .chatGPTWebSession:
            guard let items = self.validatedChatGPTWebSessionImportItems(draft.chatGPTWebSessionJSON) else { return }
            await self.importAuthJSONItems(items)
        case .file:
            await self.importJSONFiles()
        }
    }

    func importJSONFiles() async {
        guard let urls = self.selectAuthImportJSONFileURLs(), urls.isEmpty == false else { return }

        do {
            let items = try urls.map { url in
                AuthJsonImportInput(
                    source: url.lastPathComponent,
                    content: try self.importAuthFileReader(url),
                    label: nil
                )
            }
            await self.importAuthJSONItems(items)
        } catch {
            self.present(error: error, context: .importJSON)
        }
    }

    private func importAuthJSONItems(_ items: [AuthJsonImportInput]) async {
        self.isBusy = true
        self.authImportIsSubmitting = true
        defer { self.isBusy = false }
        defer { self.authImportIsSubmitting = false }
        do {
            let result = try await self.admin.importAuthJSONItems(items)
            self.accounts = try await self.admin.getAccounts()
            self.authImportDraft = nil
            self.publishAuthImportResult(result)
        } catch {
            self.present(error: error, context: .importJSON)
        }
    }

    private func selectAuthImportJSONFileURLs() -> [URL]? {
        if let importAuthFileSelectionHandler {
            return importAuthFileSelectionHandler()
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func validatedPastedAuthImportContent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.text(.errorImportFailed),
                detail: self.text(.helperAuthImportPasteRequired)
            )
            return nil
        }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            guard value is [String: Any] || value is [[String: Any]] else {
                self.publishBanner(
                    .warning,
                    title: self.text(.errorImportFailed),
                    detail: self.text(.helperAuthImportJSONInvalid)
                )
                return nil
            }
            return trimmed
        } catch {
            self.publishBanner(
                .warning,
                title: self.text(.errorImportFailed),
                detail: self.text(.helperAuthImportJSONInvalid)
            )
            return nil
        }
    }

    private func validatedChatGPTWebSessionImportItems(_ raw: String) -> [AuthJsonImportInput]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.text(.errorImportFailed),
                detail: self.text(.helperAuthImportChatGPTSessionRequired)
            )
            return nil
        }

        do {
            let conversions = try ChatGPTWebSessionCPAConverter().convertPastedSessions(trimmed)
            return conversions.enumerated().map { index, conversion in
                let source = conversions.count == 1
                    ? "chatgpt-web-session-cpa.json"
                    : "chatgpt-web-session-\(index + 1)-cpa.json"
                return AuthJsonImportInput(source: source, content: conversion.cpaJSON, label: nil)
            }
        } catch {
            self.publishBanner(
                .warning,
                title: self.text(.errorImportFailed),
                detail: self.text(.helperAuthImportChatGPTSessionInvalid)
            )
            return nil
        }
    }

    private func publishAuthImportResult(_ result: ImportAccountsResult) {
        let detail = self.authImportResultDetail(result)
        if result.failures.isEmpty {
            self.publishSuccess(.importJSON, detail: detail)
        } else {
            self.publishBanner(
                .warning,
                title: self.text(.warningAuthImportPartialFailure),
                detail: detail
            )
        }
    }

    func authImportResultDetail(_ result: ImportAccountsResult) -> String {
        var detail = self.localized(
            zh: "新增 \(result.importedCount) 个，更新 \(result.updatedCount) 个，失败 \(result.failures.count) 个。",
            en: "Imported \(result.importedCount), updated \(result.updatedCount), failed \(result.failures.count)."
        )
        if let firstFailure = result.failures.first {
            detail += " " + self.localized(
                zh: "首个失败：\(firstFailure.source) - \(firstFailure.error)",
                en: "First failure: \(firstFailure.source) - \(firstFailure.error)"
            )
        }
        return detail
    }

    private func preparedManualAPIKeySavePayload(
        from draft: ManualAPIKeyDraft
    ) -> (
        label: String?,
        baseURL: String,
        baseURLMode: ManualAPIKeyBaseURLMode?,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter?,
        chatCompatibilityProfile: ChatCompletionsCompatibilityProfile,
        apiKey: String,
        supportsVision: Bool
    )? {
        let trimmedAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else {
            self.publishBanner(.warning, title: self.text(.errorAccountManagementFailed), detail: self.text(.helperManualAccountAPIKeyRequired))
            return nil
        }

        let normalizedBaseURL: String
        do {
            normalizedBaseURL = try OpenAICompatibleUpstream.normalizeBaseURL(
                draft.baseURL,
                providerPreset: draft.providerPreset
            )
        } catch {
            self.publishBanner(.warning, title: self.text(.errorAccountManagementFailed), detail: self.text(.helperManualAccountBaseURLInvalid))
            return nil
        }

        if let configurationError = OpenAICompatibleUpstream.configurationError(
            baseURL: normalizedBaseURL,
            providerPreset: draft.providerPreset,
            apiKey: trimmedAPIKey
        ) {
            let detail: String
            if configurationError == OpenAICompatibleUpstream.geminiCompatibilityRootRequiresGeminiPresetMessage {
                detail = self.text(.errorManualAccountGoogleGeminiPresetRequired)
            } else if configurationError == OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage {
                detail = self.text(.errorManualAccountGoogleGeminiAPIKeyOnly)
            } else {
                detail = configurationError
            }
            self.publishBanner(
                .warning,
                title: self.text(.errorAccountManagementFailed),
                detail: detail
            )
            return nil
        }

        let trimmedLabel = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURLMode: ManualAPIKeyBaseURLMode? = draft.providerPreset == .genericOpenAICompatible
            ? .exactAPIPrefix
            : nil
        let upstreamAdapter: ManualAPIKeyUpstreamAdapter?
        if draft.providerPreset == .genericOpenAICompatible {
            upstreamAdapter = draft.upstreamAdapter
        } else {
            upstreamAdapter = nil
        }
        return (
            trimmedLabel.isEmpty ? nil : trimmedLabel,
            normalizedBaseURL,
            baseURLMode,
            upstreamAdapter,
            draft.upstreamAdapter == .chatCompletions ? draft.chatCompatibilityProfile : .auto,
            trimmedAPIKey,
            draft.supportsVision
        )
    }

    private func saveManualAPIKeyAccount(
        draft: ManualAPIKeyDraft
    ) async throws -> (saved: AccountSummary, successContext: OperationContext) {
        guard let payload = self.preparedManualAPIKeySavePayload(from: draft) else {
            throw CancellationError()
        }

        if let editingAccountID = draft.editingAccountID {
            let saved = try await self.admin.updateManualAPIKeyAccount(
                id: editingAccountID,
                input: UpdateManualAPIKeyAccountRequest(
                    label: payload.label,
                    providerPreset: draft.providerPreset,
                    baseURL: payload.baseURL,
                    baseURLMode: payload.baseURLMode,
                    upstreamAdapter: payload.upstreamAdapter,
                    chatCompatibilityProfile: payload.chatCompatibilityProfile,
                    apiKey: payload.apiKey,
                    enabled: draft.enabled,
                    automaticCooldownDisabled: draft.automaticCooldownDisabled,
                    supportsVision: payload.supportsVision
                )
            )
            return (saved, .manualUpdateAccount)
        }

        let saved = try await self.admin.manualAddAPIKeyAccount(
            ManualAPIKeyAccountInput(
                label: payload.label,
                providerPreset: draft.providerPreset,
                baseURL: payload.baseURL,
                baseURLMode: payload.baseURLMode,
                upstreamAdapter: payload.upstreamAdapter,
                chatCompatibilityProfile: payload.chatCompatibilityProfile,
                apiKey: payload.apiKey,
                enabled: draft.enabled,
                automaticCooldownDisabled: draft.automaticCooldownDisabled,
                supportsVision: payload.supportsVision
            )
        )
        return (saved, .manualAddAccount)
    }

    func submitManualAPIKeyAccount() async {
        guard let draft = self.manualAPIKeyDraft else { return }

        self.manualAPIKeyIsSubmitting = true
        defer { self.manualAPIKeyIsSubmitting = false }

        do {
            let outcome = try await self.saveManualAPIKeyAccount(draft: draft)
            try await self.reloadAccountState()
            self.manualAPIKeyDraft = nil
            self.publishSuccess(outcome.successContext, detail: outcome.saved.label)
        } catch is CancellationError {
            return
        } catch {
            self.present(error: error, context: draft.isEditing ? .manualUpdateAccount : .manualAddAccount)
        }
    }

    func submitOnboardingManualAPIKeyAccount() async {
        guard let draft = self.onboardingManualAPIKeyDraft else { return }

        self.manualAPIKeyIsSubmitting = true
        defer { self.manualAPIKeyIsSubmitting = false }

        do {
            let outcome = try await self.saveManualAPIKeyAccount(draft: draft)
            try await self.reloadAccountState()
            self.onboardingManualAPIKeyDraft = nil
            self.publishSuccess(outcome.successContext, detail: outcome.saved.label)
        } catch is CancellationError {
            return
        } catch {
            self.present(error: error, context: draft.isEditing ? .manualUpdateAccount : .manualAddAccount)
        }
    }

    private func normalizedBaseURLIfPossible(
        _ value: String,
        providerPreset: OpenAICompatibleProviderPreset
    ) -> String {
        (try? OpenAICompatibleUpstream.normalizeBaseURL(value, providerPreset: providerPreset))
            ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func submitAccountLabelUpdate() async {
        guard let draft = self.accountLabelDraft else { return }

        let trimmedLabel = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLabel.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.text(.errorAccountManagementFailed),
                detail: self.text(.helperAccountLabelRequired)
            )
            return
        }

        self.accountLabelIsSubmitting = true
        defer { self.accountLabelIsSubmitting = false }

        do {
            let saved = try await self.admin.updateAccountLabel(
                id: draft.accountID,
                input: UpdateAccountLabelRequest(label: trimmedLabel)
            )
            try await self.reloadAccountState()
            self.accountLabelDraft = nil
            self.publishSuccess(.renameAccountLabel, detail: saved.label)
        } catch {
            self.present(error: error, context: .renameAccountLabel)
        }
    }

    func submitAccountManagedProxyNodeUpdate() async {
        guard let draft = self.accountManagedProxyNodeDraft else { return }

        self.accountManagedProxyNodeIsSubmitting = true
        defer { self.accountManagedProxyNodeIsSubmitting = false }

        do {
            let saved = try await self.admin.updateAccountManagedProxyNode(
                id: draft.accountID,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: draft.managedProxyNodeName)
            )
            try await self.reloadAccountState()
            self.accountManagedProxyNodeDraft = nil
            self.publishSuccess(.updateAccountManagedProxyNode, detail: saved.label)
        } catch {
            self.present(error: error, context: .updateAccountManagedProxyNode)
        }
    }

    func clearAllAccountManagedProxyNodes() async {
        guard self.hasAccountManagedProxyNodeOverrides else { return }
        guard self.confirmClearAccountManagedProxyNodes() else { return }

        do {
            let result = try await self.admin.clearAccountManagedProxyNodes()
            try await self.reloadAccountState()
            self.publishSuccess(.clearAccountManagedProxyNodes, detail: String(result.clearedCount))
        } catch {
            self.present(error: error, context: .clearAccountManagedProxyNodes)
        }
    }

    func submitAccountModelRoutingUpdate() async {
        guard let draft = self.accountModelRoutingDraft else { return }

        self.accountModelRoutingIsSubmitting = true
        defer { self.accountModelRoutingIsSubmitting = false }

        do {
            let normalized = self.normalizedAccountModelRouting(for: draft)
            let saved = try await self.admin.updateAccountModelRouting(
                id: draft.accountID,
                input: UpdateAccountModelRoutingRequest(
                    defaultTargetModel: normalized?.defaultTargetModel,
                    mappings: normalized?.mappings ?? []
                )
            )
            try await self.reloadAccountState()
            self.accountModelRoutingDraft = nil
            self.publishSuccess(.updateAccountModelRouting, detail: saved.label)
        } catch {
            self.present(error: error, context: .updateAccountModelRouting)
        }
    }

    func submitAccountReasoningEffortUpdate() async {
        guard let draft = self.accountReasoningEffortDraft else { return }

        self.accountReasoningEffortIsSubmitting = true
        defer { self.accountReasoningEffortIsSubmitting = false }

        do {
            let saved = try await self.admin.updateAccountReasoningEffort(
                id: draft.accountID,
                input: UpdateAccountReasoningEffortRequest(
                    low: draft.low,
                    medium: draft.medium,
                    high: draft.high,
                    xhigh: draft.xhigh
                )
            )
            try await self.reloadAccountState()
            self.accountReasoningEffortDraft = nil
            self.publishSuccess(.updateAccountReasoningEffort, detail: saved.label)
        } catch {
            self.present(error: error, context: .updateAccountReasoningEffort)
        }
    }

    func exportAccounts() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codex-proxy-accounts.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        self.isBusy = true
        defer { self.isBusy = false }
        do {
            let data = try await self.admin.exportAccounts()
            try data.write(to: url)
            self.publishSuccess(.exportAccounts)
        } catch {
            self.present(error: error, context: .exportAccounts)
        }
    }

    func refreshUsage() async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            self.accounts = try await self.admin.refreshUsage()
            self.stats = (try? await self.admin.getStats(apiKey: self.overviewTrafficStatsAPIKeyValue)) ?? self.stats
            self.publishSuccess(.refreshUsage)
        } catch {
            self.present(error: error, context: .refreshUsage)
        }
    }

    func refreshAccountList() async {
        guard self.isRefreshingAccountList == false else { return }
        self.isRefreshingAccountList = true
        defer { self.isRefreshingAccountList = false }

        do {
            self.accounts = try await self.admin.getAccounts()
            self.publishSuccess(.refreshAccountList)
        } catch {
            self.present(error: error, context: .refreshAccountList)
        }
    }

    func refreshUsage(for account: AccountSummary) async {
        guard self.refreshingAccountIDs.contains(account.id) == false else { return }
        self.refreshingAccountIDs.insert(account.id)
        defer { self.refreshingAccountIDs.remove(account.id) }

        do {
            let updated = try await self.admin.refreshAccountUsage(id: account.id)
            try await self.reloadAccountState()
            let refreshed = self.accounts.first(where: { $0.id == account.id }) ?? updated
            if refreshed.authMode.isManualAPIKey {
                if self.manualAPIKeyRefreshCanReportSuccess(refreshed) {
                    self.publishBanner(
                        .success,
                        title: self.text(.successAccountUsageRefreshed),
                        detail: self.text(.helperAPIKeyAccountNoStandardUsage)
                    )
                } else {
                    let warning = self.manualAPIKeyRefreshWarning(refreshed)
                    self.publishBanner(.warning, title: warning.title, detail: warning.detail)
                }
            } else {
                self.publishSuccess(.refreshAccountUsage, detail: updated.label)
            }
        } catch {
            self.present(error: error, context: .refreshAccountUsage)
        }
    }

    private func manualAPIKeyRefreshCanReportSuccess(_ account: AccountSummary) -> Bool {
        guard account.authMode.isManualAPIKey else { return false }
        let usageError = account.usageError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refreshError = account.authRefreshError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return usageError.isEmpty && refreshError.isEmpty && self.accountRuntimeIssueText(account) == nil
    }

    private func manualAPIKeyRefreshWarning(_ account: AccountSummary) -> (title: String, detail: String?) {
        if let usageError = self.trimmedRefreshWarningDetail(account.usageError) {
            return (
                self.localization.errorTitle(for: usageError, context: .refreshAccountUsage),
                self.localization.errorDetail(for: usageError, context: .refreshAccountUsage) ?? usageError
            )
        }
        if let refreshError = self.trimmedRefreshWarningDetail(account.authRefreshError) {
            return (
                self.localization.errorTitle(for: refreshError, context: .refreshAccountUsage),
                self.localization.errorDetail(for: refreshError, context: .refreshAccountUsage) ?? refreshError
            )
        }
        let issue = self.accountRuntimeIssueText(account)
        return (
            self.localization.errorTitle(for: issue ?? "", context: .refreshAccountUsage),
            issue
        )
    }

    private func trimmedRefreshWarningDetail(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func toggleAccountEnabled(_ account: AccountSummary) async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            let updated = try await self.admin.setAccountEnabled(id: account.id, enabled: !account.enabled)
            try await self.reloadAccountState()
            self.publishSuccess(updated.enabled ? .enableAccount : .disableAccount, detail: updated.label)
        } catch {
            self.present(error: error, context: account.enabled ? .disableAccount : .enableAccount)
        }
    }

    func stopAccountCooldown(_ account: AccountSummary) async {
        guard self.canStopAccountCooldown(account) else { return }
        guard self.confirmStopAccountCooldown(for: account) else { return }

        self.isBusy = true
        defer { self.isBusy = false }
        do {
            let updated = try await self.admin.stopAccountCooldown(id: account.id)
            try await self.reloadAccountState()
            self.publishSuccess(.stopAccountCooldown, detail: updated.label)
        } catch {
            self.present(error: error, context: .stopAccountCooldown)
        }
    }

    func toggleAccountCooldownPolicy(_ account: AccountSummary) async {
        guard self.canUpdateAccountCooldownPolicy(account) else { return }

        self.isBusy = true
        defer { self.isBusy = false }
        do {
            let updated = try await self.admin.updateAccountCooldownPolicy(
                id: account.id,
                input: UpdateAccountCooldownPolicyRequest(
                    automaticCooldownDisabled: !account.automaticCooldownDisabled
                )
            )
            try await self.reloadAccountState()
            self.publishSuccess(.updateAccountCooldownPolicy, detail: updated.label)
        } catch {
            self.present(error: error, context: .updateAccountCooldownPolicy)
        }
    }

    func removeAccount(_ account: AccountSummary) async {
        guard self.confirmRemoveAuthorization(for: account) else { return }

        self.isBusy = true
        defer { self.isBusy = false }
        do {
            let result = try await self.admin.removeAccount(id: account.id)
            try await self.reloadAccountState()
            self.publishSuccess(.removeAccount, detail: result.label)
        } catch {
            self.present(error: error, context: .removeAccount)
        }
    }

    func removeSelectedBatchAccounts() async {
        let accounts = self.selectedBatchRemoveAccounts
        guard accounts.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.text(.errorAccountManagementFailed),
                detail: self.localized(zh: "请先选择要移除的账号。", en: "Select at least one account to remove first.")
            )
            return
        }
        guard self.confirmBatchRemoveAccounts(accounts) else { return }

        self.isBatchRemovingAccounts = true
        defer { self.isBatchRemovingAccounts = false }
        do {
            let result = try await self.admin.removeAccounts(
                BatchDeleteAccountsRequest(accountIDs: accounts.map(\.id))
            )
            try await self.reloadAccountState()
            let deletedIDs = Set(result.deleted.map(\.id))
            self.selectedBatchRemoveAccountIDs.subtract(deletedIDs)
            if result.failures.isEmpty {
                self.exitAccountBatchRemoveMode()
                self.publishBanner(
                    .success,
                    title: self.text(.successBatchRemoveAccounts),
                    detail: self.localized(
                        zh: "已移除 \(result.deleted.count) 个账号。",
                        en: "Removed \(result.deleted.count) accounts."
                    )
                )
            } else {
                self.isAccountBatchRemoveModeEnabled = true
                let firstFailure = result.failures.first
                self.publishBanner(
                    .warning,
                    title: self.text(.warningBatchRemoveAccountsPartial),
                    detail: self.localized(
                        zh: "已移除 \(result.deleted.count) 个，失败 \(result.failures.count) 个。\(firstFailure.map { "首个失败：\($0.id) - \($0.error)" } ?? "")",
                        en: "Removed \(result.deleted.count), failed \(result.failures.count). \(firstFailure.map { "First failure: \($0.id) - \($0.error)" } ?? "")"
                    )
                )
            }
        } catch {
            self.present(error: error, context: .removeAccount)
        }
    }

    func submitAccountOrderUpdate() async {
        guard let draft = self.accountOrderDraft else { return }

        self.accountOrderIsSubmitting = true
        defer { self.accountOrderIsSubmitting = false }

        do {
            self.accounts = try await self.admin.updateAccountOrder(
                UpdateAccountOrderRequest(orderedAccountIDs: draft.accounts.map(\.id))
            )
            self.accountOrderDraft = nil
            self.publishSuccess(.reorderAccounts)
        } catch {
            self.present(error: error, context: .reorderAccounts)
        }
    }

    func rotateProxyKey() async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            self.status = try await self.admin.rotateProxyAPIKey()
            self.settings = try await self.admin.getSettings()
            self.syncMinimalProxyDraftFromSettingsIfNeeded()
            self.syncSettingsOutboundProxyDraftFromSettingsIfNeeded()
            _ = try await self.daemon.applyLaunchConfiguration(
                config: self.settings,
                preserveRunningService: true
            )
            self.localServiceStatus = await self.daemon.status()
            self.proxyAPIKeyUsageReport = try await self.admin.getProxyAPIKeyUsage(query: self.proxyAPIKeyUsageFilter.query)
            if self.isProxyTestPresented {
                await self.refreshProxyTestConsole()
            }
            self.publishSuccess(.rotateProxyKey)
        } catch {
            self.present(error: error, context: .rotateProxyKey)
        }
    }

    @discardableResult
    func saveSettings(noticeContext: OperationContext = .saveSettings) async -> Bool {
        let saved = await self.persistSettingsUpdate(self.settings, noticeContext: noticeContext)
        if saved {
            self.syncMinimalProxyDraftFromSettingsIfNeeded()
            self.syncSettingsOutboundProxyDraftFromSettingsIfNeeded()
        }
        return saved
    }

    @discardableResult
    func persistSettingsUpdate(
        _ updatedSettings: AppConfig,
        noticeContext: OperationContext = .saveSettings,
        successTitle: String? = nil,
        successDetail: String? = nil
    ) async -> Bool {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            self.settings = try await self.admin.saveSettings(updatedSettings)
            let applyOutcome = try await self.daemon.applyLaunchConfiguration(
                config: self.settings,
                preserveRunningService: true
            )
            await self.refreshLocalServiceSnapshot()
            self.syncSelectedRemoteHost()
            self.proxyAPIKeyUsageReport = try await self.admin.getProxyAPIKeyUsage(query: self.proxyAPIKeyUsageFilter.query)
            if self.isProxyTestPresented {
                await self.refreshProxyTestConsole()
            }
            self.publishLaunchConfigurationOutcome(
                applyOutcome,
                successTitle: successTitle ?? self.localization.successTitle(for: noticeContext),
                successDetail: successDetail ?? self.localization.successDetail(for: noticeContext, rawDetail: nil)
            )
            return true
        } catch {
            self.present(error: error, context: noticeContext)
            return false
        }
    }

    func startOAuth(providerFamily: AccountProviderFamily = .openAI) async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            if await self.daemon.isRunning() == false {
                try await self.daemon.start(config: self.settings)
                try await Task.sleep(for: .seconds(1))
            }

            let baselineAccounts = (try? await self.admin.getAccounts()) ?? self.accounts
            let prepared = try await self.admin.prepareOAuth(providerFamily: providerFamily)
            guard let url = URL(string: prepared.authURL) else {
                throw ProxyError.message("OAuth 授权链接无效")
            }
            let draft = OAuthDraft(
                providerFamily: providerFamily,
                prepared: prepared,
                expectedAuthMode: self.oauthExpectedAuthMode(for: providerFamily),
                baselineUpdatedAtByAccountKey: self.oauthBaselineUpdatedAtByAccountKey(from: baselineAccounts)
            )
            self.oauthDraft = draft
            self.beginOAuthObservation(for: draft)

            if NSWorkspace.shared.open(url) {
                self.publishSuccess(.startOAuth, detail: prepared.redirectURI)
            } else {
                self.publishBanner(.warning, title: self.text(.oauthBrowserOpenFailed), detail: prepared.authURL)
            }
        } catch {
            self.present(error: error, context: .startOAuth)
        }
    }

    func openOAuthAuthorizationPage() {
        guard let authURL = self.oauthDraft?.prepared.authURL,
              let url = URL(string: authURL)
        else {
            self.publishBanner(.warning, title: self.text(.oauthInvalidLink), detail: nil)
            return
        }

        if NSWorkspace.shared.open(url) {
            self.publishSuccess(.startOAuth, detail: self.oauthDraft?.prepared.redirectURI)
        } else {
            self.publishBanner(.warning, title: self.text(.oauthBrowserOpenFailed), detail: authURL)
        }
    }

    func completeOAuth() async {
        guard let draft = self.oauthDraft else { return }
        let callbackURL = draft.callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard callbackURL.isEmpty == false else {
            self.publishBanner(.warning, title: self.text(.oauthCallbackMissing), detail: self.text(.oauthCallbackPlaceholder))
            return
        }

        self.isBusy = true
        defer { self.isBusy = false }
        do {
            let account = try await self.admin.completeOAuthCallback(
                callbackURL,
                providerFamily: draft.providerFamily
            )
            self.oauthObservationTask?.cancel()
            self.oauthObservationTask = nil
            self.oauthDraft = nil
            self.accounts = try await self.admin.getAccounts()
            self.status = try? await self.admin.getStatus()
            self.publishSuccess(.completeOAuth, detail: account.label)
        } catch {
            self.present(error: error, context: .completeOAuth)
        }
    }

    func dismissOAuthDraft() {
        self.oauthObservationTask?.cancel()
        self.oauthObservationTask = nil
        self.oauthDraft = nil
    }

    func copyOAuthAuthorizationLink() {
        self.copyToPasteboard(self.oauthDraft?.prepared.authURL ?? "", context: .copyOAuthLink)
    }

    func createNewRemoteHost() {
        self.selectedRemoteHost = RemoteHostConfig()
        self.selectedRemoteWorkflowStep = .configuration
    }

    func saveSelectedRemoteHostAndContinue() async {
        guard await self.upsertRemoteHost() else { return }
        self.selectedRemoteWorkflowStep = .verification
    }

    func testSelectedRemoteConnection() async {
        let hostID = self.selectedRemoteHost.id
        guard self.canEnterRemoteWorkflowStep(.verification), !hostID.isEmpty else {
            self.selectedRemoteWorkflowStep = .configuration
            return
        }

        self.isBusy = true
        self.remoteOperation = .testing(hostID: hostID)
        defer {
            self.remoteOperation = .idle
            self.isBusy = false
        }
        do {
            let check = try await self.remoteDeploy.testConnection(host: self.selectedRemoteHost)
            self.remoteConnectionChecksByHostID[hostID] = check
            self.remoteConnectionErrorsByHostID[hostID] = nil
            self.publishSuccess(.remoteConnectionTest)
        } catch {
            self.remoteConnectionChecksByHostID[hostID] = nil
            self.remoteConnectionErrorsByHostID[hostID] = error.localizedDescription
            self.present(error: error, context: .remoteConnectionTest)
        }
    }

    func deploySelectedRemote() async {
        let host = self.selectedRemoteHost
        let hostID = host.id
        guard !hostID.isEmpty, self.canDeployRemoteHost(for: hostID) else { return }
        self.isBusy = true
        self.remoteOperation = .deploying(hostID: hostID)
        defer {
            self.remoteOperation = .idle
            self.isBusy = false
        }
        do {
            let exportData = try await self.admin.exportAccounts()
            let status = try await self.remoteDeploy.deploy(host: host, exportedAccountsJSON: exportData, config: self.settings)
            self.remoteStatuses[hostID] = status
            self.remoteServiceLoadErrors[hostID] = nil
            self.publishSuccess(.deployRemote)
        } catch {
            await self.captureRemoteDeployFailureContext(
                hostID: hostID,
                host: host,
                fallbackError: error.localizedDescription
            )
            self.present(error: error, context: .deployRemote)
        }
    }

    func refreshSelectedRemote() async {
        let hostID = self.selectedRemoteHost.id
        guard !hostID.isEmpty, self.canManageRemoteHostOperations(for: hostID) else { return }
        self.isBusy = true
        self.remoteOperation = .loadingStatus(hostID: hostID)
        defer {
            self.remoteOperation = .idle
            self.isBusy = false
        }
        do {
            let status = try await self.remoteDeploy.status(host: self.selectedRemoteHost)
            self.remoteStatuses[hostID] = status
            self.remoteServiceLoadErrors[hostID] = nil
            self.publishSuccess(.remoteStatus)
        } catch {
            self.remoteServiceLoadErrors[hostID] = error.localizedDescription
            self.present(error: error, context: .remoteStatus)
        }
    }

    func startSelectedRemote() async {
        let hostID = self.selectedRemoteHost.id
        guard !hostID.isEmpty, self.remoteCanStartService(for: hostID) else { return }
        self.isBusy = true
        self.remoteOperation = .starting(hostID: hostID)
        defer {
            self.remoteOperation = .idle
            self.isBusy = false
        }
        do {
            let status = try await self.remoteDeploy.start(host: self.selectedRemoteHost)
            self.remoteStatuses[hostID] = status
            self.remoteServiceLoadErrors[hostID] = nil
            self.publishSuccess(.remoteStart)
        } catch {
            if self.remoteStatuses[hostID] == nil {
                self.remoteServiceLoadErrors[hostID] = error.localizedDescription
            }
            self.present(error: error, context: .remoteStart)
        }
    }

    func stopSelectedRemote() async {
        let hostID = self.selectedRemoteHost.id
        guard !hostID.isEmpty, self.remoteCanStopService(for: hostID) else { return }
        self.isBusy = true
        self.remoteOperation = .stopping(hostID: hostID)
        defer {
            self.remoteOperation = .idle
            self.isBusy = false
        }
        do {
            let status = try await self.remoteDeploy.stop(host: self.selectedRemoteHost)
            self.remoteStatuses[hostID] = status
            self.remoteServiceLoadErrors[hostID] = nil
            self.publishSuccess(.remoteStop)
        } catch {
            if self.remoteStatuses[hostID] == nil {
                self.remoteServiceLoadErrors[hostID] = error.localizedDescription
            }
            self.present(error: error, context: .remoteStop)
        }
    }

    func loadSelectedRemoteLogs() async {
        let hostID = self.selectedRemoteHost.id
        guard !hostID.isEmpty, self.canManageRemoteHostOperations(for: hostID) else { return }
        self.isBusy = true
        self.remoteOperation = .loadingLogs(hostID: hostID)
        defer {
            self.remoteOperation = .idle
            self.isBusy = false
        }
        do {
            self.remoteLogsByHostID[hostID] = try await self.remoteDeploy.logs(host: self.selectedRemoteHost, lines: 120)
            self.publishSuccess(.remoteLogs)
        } catch {
            self.present(error: error, context: .remoteLogs)
        }
    }

    private func captureRemoteDeployFailureContext(
        hostID: String,
        host: RemoteHostConfig,
        fallbackError: String
    ) async {
        do {
            let status = try await self.remoteDeploy.status(host: host)
            self.remoteStatuses[hostID] = status
            self.remoteServiceLoadErrors[hostID] = nil
        } catch {
            if self.remoteStatuses[hostID] == nil {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                self.remoteServiceLoadErrors[hostID] = detail.isEmpty ? fallbackError : detail
            }
        }

        do {
            let logs = try await self.remoteDeploy.logs(host: host, lines: 120)
            if !logs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.remoteLogsByHostID[hostID] = logs
            }
        } catch {
            // Best-effort diagnostics should not mask the original deploy failure.
        }
    }

    @discardableResult
    func upsertRemoteHost(notice: Bool = true) async -> Bool {
        if let validationMessage = self.remoteHostValidationMessage(for: self.selectedRemoteHost) {
            self.publishBanner(.warning, title: self.text(.errorConfigurationFailed), detail: validationMessage)
            return false
        }

        self.remoteOperation = .saving(hostID: self.selectedRemoteHost.id)
        defer {
            if case .saving = self.remoteOperation {
                self.remoteOperation = .idle
            }
        }

        var updatedSettings = self.settings
        if let index = updatedSettings.remoteHosts.firstIndex(where: { $0.id == self.selectedRemoteHost.id }) {
            updatedSettings.remoteHosts[index] = self.selectedRemoteHost
        } else {
            updatedSettings.remoteHosts.append(self.selectedRemoteHost)
        }

        let saved = await self.persistSettingsUpdate(updatedSettings, noticeContext: .saveRemoteHost)
        if saved && !notice {
            self.clearBanner()
        }
        return saved
    }

    func removeSelectedRemoteHost() async {
        guard self.isSelectedRemoteHostSaved() else { return }
        let host = self.selectedRemoteHost
        guard self.confirmDeleteRemoteHost(host) else { return }

        var updatedSettings = self.settings
        updatedSettings.remoteHosts.removeAll { $0.id == host.id }
        let nextHost = updatedSettings.remoteHosts.first ?? RemoteHostConfig()
        let previousHost = self.selectedRemoteHost
        let previousStep = self.selectedRemoteWorkflowStep

        self.selectedRemoteHost = nextHost
        self.selectedRemoteWorkflowStep = .hosts
        self.remoteOperation = .deleting(hostID: host.id)
        defer {
            if case .deleting = self.remoteOperation {
                self.remoteOperation = .idle
            }
        }

        let deleted = await self.persistSettingsUpdate(updatedSettings, noticeContext: .deleteRemoteHost)
        if deleted {
            self.dismissRemoteAdminWindow(hostID: host.id)
            self.clearRemoteTransientState(for: host.id)
        } else {
            self.selectedRemoteHost = previousHost
            self.selectedRemoteWorkflowStep = previousStep
        }
    }

    func copyEndpoint() {
        self.copyToPasteboard(self.openAICompatibleBaseURL, context: .copyEndpoint)
    }

    func copyAPIKey() {
        self.copyToPasteboard(self.localProxyAPIKeyValue, context: .copyAPIKey)
    }

    func copyAnthropicAccessAPIKey() {
        guard let anthropicAccessProxyAPIKeyValue = self.anthropicAccessProxyAPIKeyValue else {
            self.publishBanner(.warning, title: self.text(.errorCopyFailed), detail: self.text(.statusUnavailable))
            return
        }
        self.copyToPasteboard(anthropicAccessProxyAPIKeyValue, context: .copyAPIKey)
    }

    func copyAnthropicBaseURL() {
        self.copyToPasteboard(self.anthropicBaseURL, context: .copyEndpoint)
    }

    func copyGeminiBaseURL() {
        self.copyToPasteboard(self.geminiBaseURL, context: .copyEndpoint)
    }

    func copyClaudeCodeEnvironment() {
        guard self.canCopyClaudeCodeEnvironmentSnippet else {
            self.publishBanner(.warning, title: self.text(.errorCopyFailed), detail: self.text(.statusUnavailable))
            return
        }
        self.copyToPasteboard(self.claudeCodeEnvironmentSnippet, context: .copyClaudeCodeEnv)
    }

    func copyGeminiCLIEnvironment() {
        self.copyToPasteboard(self.geminiCLIEnvironmentSnippet, context: .copyGeminiCLIEnv)
    }

    func copyCurrentProxyTestEndpoint() {
        let endpoint = self.proxyTestDraft.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.isEmpty {
            self.copyToPasteboard(
                self.proxyTestDraft.endpoint == .anthropicMessages
                    ? self.anthropicBaseURL
                    : (self.proxyTestDraft.endpoint == .geminiGenerateContent ? self.geminiBaseURL : self.openAICompatibleBaseURL),
                context: .copyEndpoint
            )
            return
        }
        self.copyToPasteboard(self.normalizedUserFacingBaseURL(endpoint), context: .copyEndpoint)
    }

    private func persistPreferences(showSuccessNotice: Bool = true) {
        do {
            try self.preferencesStore.save(self.preferences)
            if showSuccessNotice {
                self.publishSuccess(.savePreferences, detail: nil)
            }
        } catch {
            self.present(error: error, context: .savePreferences)
        }
    }

    func updatePreferences(showSuccessNotice: Bool = true, _ mutate: (inout DesktopPreferences) -> Void) {
        let previousPreferences = self.preferences
        var preferences = previousPreferences
        mutate(&preferences)
        if previousPreferences.themeMode != preferences.themeMode, preferences.themeMode == .system {
            self.refreshSystemColorScheme()
        }
        self.preferences = preferences
        if previousPreferences.themeMode != preferences.themeMode {
            AppearanceStore.applyAppAppearance(for: preferences.themeMode)
        }
        self.persistPreferences(showSuccessNotice: showSuccessNotice)
        self.refreshThemeSensitiveWindows()
    }

    func refreshThemeSensitiveWindows() {
        self.aboutWindowController?.refreshWindow()
        self.helpWindowController?.refreshWindow()
        self.onboardingWindowController?.refreshWindow()
        self.proxyTestWindowController?.refreshWindow()
        self.managedProxyWindowController?.refreshWindow()
        self.clientConfigManagerWindowController?.refreshWindow()
        self.codexProjectRoutesWindowController?.refreshWindow()
        self.ocrCacheLogsWindowController?.refreshWindow()
        self.ocrModelManagerWindowController?.refreshWindow()
        self.requestLogsWindowController?.refreshWindow()
        self.assistantWindowController?.refreshWindow()
        self.remoteAdminWindowControllers.values.forEach { $0.refreshWindow(preferences: self.preferences) }
    }

    @discardableResult
    func refreshSystemColorScheme() -> Bool {
        let colorScheme = AppearanceStore.currentSystemColorScheme()
        guard self.systemColorScheme != colorScheme else { return false }
        self.systemColorScheme = colorScheme
        return true
    }

    private func resetRemoteManagementRevealState() {
        self.remoteManagementRevealTapCount = 0
        self.remoteManagementLastTapAt = nil
    }

    private func handleSelectedRemoteWorkflowStepChange(from oldValue: RemoteWorkflowStep, to newValue: RemoteWorkflowStep) {
        guard oldValue != newValue else { return }
        self.cancelRemoteWorkflowAutomation()

        let hostID = self.selectedRemoteHost.id
        switch newValue {
        case .verification:
            guard self.shouldAutomaticallyTestSelectedRemoteConnection(for: hostID) else { return }
            self.remoteWorkflowAutomationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.testSelectedRemoteConnection()
                guard !Task.isCancelled else { return }
                guard self.selectedRemoteWorkflowStep == .verification,
                      self.selectedRemoteHost.id == hostID,
                      self.hasSuccessfulRemoteManagementCheck(for: hostID)
                else {
                    return
                }
                self.selectedRemoteWorkflowStep = .operations
            }
        case .operations:
            guard self.shouldAutomaticallyRefreshSelectedRemoteStatus(for: hostID) else { return }
            self.remoteWorkflowAutomationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard !Task.isCancelled,
                      self.selectedRemoteWorkflowStep == .operations,
                      self.selectedRemoteHost.id == hostID
                else {
                    return
                }
                await self.refreshSelectedRemote()
            }
        case .hosts, .configuration:
            break
        }
    }

    private func handleSelectedRemoteHostChange(from oldValue: RemoteHostConfig, to newValue: RemoteHostConfig) {
        guard oldValue != newValue else { return }
        guard !self.suppressSelectedRemoteHostChangeSideEffects else { return }
        self.cancelRemoteWorkflowAutomation()

        if oldValue.id == newValue.id {
            self.dismissRemoteAdminWindow(hostID: newValue.id)
            self.invalidateRemoteVerification(for: newValue.id)
            self.clearRemoteRuntimeState(for: newValue.id)
            if self.selectedRemoteWorkflowStep.rawValue > RemoteWorkflowStep.configuration.rawValue {
                self.selectedRemoteWorkflowStep = .configuration
            }
        } else {
            self.syncRemoteWorkflowStepForSelectedHost()
        }
    }

    private func invalidateRemoteVerification(for hostID: String) {
        self.remoteConnectionChecksByHostID[hostID] = nil
        self.remoteConnectionErrorsByHostID[hostID] = nil
    }

    private func clearRemoteRuntimeState(for hostID: String) {
        self.remoteStatuses[hostID] = nil
        self.remoteServiceLoadErrors[hostID] = nil
        self.remoteLogsByHostID[hostID] = nil
    }

    private func clearRemoteTransientState(for hostID: String) {
        self.invalidateRemoteVerification(for: hostID)
        self.clearRemoteRuntimeState(for: hostID)
    }

    private func cancelRemoteWorkflowAutomation() {
        self.remoteWorkflowAutomationTask?.cancel()
        self.remoteWorkflowAutomationTask = nil
    }

    private func shouldAutomaticallyTestSelectedRemoteConnection(for hostID: String) -> Bool {
        guard !hostID.isEmpty,
              self.canEnterRemoteWorkflowStep(.verification),
              self.isRemoteTesting(hostID: hostID) == false
        else {
            return false
        }
        return self.hasSuccessfulRemoteManagementCheck(for: hostID) == false
    }

    private func shouldAutomaticallyRefreshSelectedRemoteStatus(for hostID: String) -> Bool {
        guard !hostID.isEmpty,
              self.canManageRemoteHostOperations(for: hostID),
              self.isRemoteStatusLoading(hostID: hostID) == false
        else {
            return false
        }
        return true
    }

    func syncRemoteAdminDiscoveredPort(hostID: String, adminPort: Int) async -> RemoteAdminPortSyncResult {
        guard adminPort > 0 else {
            return .failed("The discovered remote admin port is invalid.")
        }
        guard let hostIndex = self.settings.remoteHosts.firstIndex(where: { $0.id == hostID }) else {
            return .failed("The remote host could not be found in local settings.")
        }

        if self.settings.remoteHosts[hostIndex].adminPort == adminPort {
            self.syncSelectedRemoteHost(suppressSideEffects: true)
            return .alreadyCurrent(adminPort: adminPort)
        }

        var updatedSettings = self.settings
        updatedSettings.remoteHosts[hostIndex].adminPort = adminPort

        do {
            self.settings = try await self.admin.saveSettings(updatedSettings)
            self.syncSelectedRemoteHost(suppressSideEffects: true)
            return .synced(adminPort: adminPort)
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? "Failed to save the updated remote admin port." : detail)
        }
    }

    private func syncRemoteWorkflowStepForSelectedHost() {
        if self.savedRemoteHosts.isEmpty {
            self.selectedRemoteWorkflowStep = .hosts
            return
        }

        if !self.isSelectedRemoteHostSaved() {
            self.selectedRemoteWorkflowStep = .configuration
            return
        }

        if self.canManageRemoteHostOperations(for: self.selectedRemoteHost.id) {
            return
        }

        if self.selectedRemoteWorkflowStep == .operations {
            self.selectedRemoteWorkflowStep = .verification
        }
    }

    func syncSelectedRemoteHost(suppressSideEffects: Bool = false) {
        let previousSuppression = self.suppressSelectedRemoteHostChangeSideEffects
        if suppressSideEffects {
            self.suppressSelectedRemoteHostChangeSideEffects = true
        }
        defer { self.suppressSelectedRemoteHostChangeSideEffects = previousSuppression }

        guard !self.settings.remoteHosts.isEmpty else {
            if self.selectedRemoteHost.id.isEmpty {
                self.selectedRemoteHost = RemoteHostConfig()
            }
            self.syncRemoteWorkflowStepForSelectedHost()
            return
        }

        if let current = self.settings.remoteHosts.first(where: { $0.id == self.selectedRemoteHost.id }) {
            self.selectedRemoteHost = current
        } else if let first = self.settings.remoteHosts.first {
            self.selectedRemoteHost = first
        }
        self.syncRemoteWorkflowStepForSelectedHost()
    }

    func reloadAccountState() async throws {
        self.settings = (try? await self.admin.getSettings()) ?? self.settings
        self.syncMinimalProxyDraftFromSettingsIfNeeded()
        self.syncSettingsOutboundProxyDraftFromSettingsIfNeeded()
        self.syncSelectedRemoteHost()
        self.accounts = try await self.admin.getAccounts()
        self.status = try? await self.admin.getStatus()
        self.stats = (try? await self.admin.getStats(apiKey: self.overviewTrafficStatsAPIKeyValue)) ?? self.stats
        if let snapshot = try? await self.admin.getManagedProxySnapshot() {
            self.syncManagedProxySnapshotState(snapshot)
        }
    }

    func publishSuccess(_ context: OperationContext, detail: String? = nil) {
        self.publishBanner(
            .success,
            title: self.localization.successTitle(for: context),
            detail: self.localization.successDetail(for: context, rawDetail: detail)
        )
    }

    func present(error: Error, context: OperationContext) {
        let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publishBanner(
            .error,
            title: self.localization.errorTitle(for: rawDetail, context: context),
            detail: self.localization.errorDetail(for: rawDetail, context: context)
        )
    }

    func localized(zh: String, en: String) -> String {
        self.localization.resolvedLanguage == .zhHans ? zh : en
    }

    func copyToPasteboard(_ value: String, context: OperationContext) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.publishBanner(.warning, title: self.text(.errorCopyFailed), detail: self.text(.statusNoData))
            return
        }
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.setString(value, forType: .string)
        if success {
            self.publishSuccess(context)
        } else {
            self.publishBanner(.error, title: self.text(.errorCopyFailed), detail: nil)
        }
    }

    private func normalizedUserFacingBaseURL(runtimeValue: String?, fallback: String) -> String {
        let trimmedRuntimeValue = runtimeValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedRuntimeValue.isEmpty == false {
            return self.normalizedUserFacingBaseURL(trimmedRuntimeValue)
        }
        return self.normalizedUserFacingBaseURL(fallback)
    }

    private func normalizedUserFacingBaseURL(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.isEmpty == false,
              let remoteHostOverride = self.trimmedRemoteAccessibleHostOverride
        else {
            return trimmedValue
        }
        guard let url = URL(string: trimmedValue),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              Self.shouldReplaceUserFacingProxyHost(host)
        else {
            return trimmedValue
        }

        components.host = remoteHostOverride
        return components.string ?? trimmedValue
    }

    private var trimmedRemoteAccessibleHostOverride: String? {
        let trimmed = self.remoteAccessibleHostOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shouldReplaceUserFacingProxyHost(_ host: String) -> Bool {
        switch host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0.0.0.0", "127.0.0.1", "localhost", "::", "::1", "0:0:0:0:0:0:0:0", "0:0:0:0:0:0:0:1":
            return true
        default:
            return false
        }
    }

    func publishBanner(_ tone: BannerState.Tone, title: String, detail: String?) {
        let state = BannerState(tone: tone, title: title, detail: detail)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            self.banners.insert(state, at: 0)
        }
        guard tone != .error else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.toastAutoDismissDuration ?? .seconds(3.5))
            guard self?.banners.contains(where: { $0.id == state.id }) == true else { return }
            self?.dismissBanner(id: state.id)
        }
    }

    func refreshLocalServiceStatus() async {
        await self.refreshLocalServiceSnapshot()
    }

    func loadLocalDaemonLogs() async {
        self.localDaemonLogs = await self.daemon.logs()
    }

    private func ensureLocalSecretsReady() {
        _ = try? SecretStore(dataDirectory: Paths.defaultDataDirectory()).masterKey()
    }

    func refreshLocalServiceSnapshot(refreshRelatedData: Bool = false) async {
        self.localServiceStatus = await self.daemon.status()
        self.status = try? await self.admin.getStatus()
        if let snapshot = try? await self.admin.getManagedProxySnapshot() {
            self.syncManagedProxySnapshotState(snapshot)
        }

        guard refreshRelatedData else { return }
        if let accounts = try? await self.admin.getAccounts() {
            self.accounts = accounts
        }
        if let stats = try? await self.admin.getStats(apiKey: self.overviewTrafficStatsAPIKeyValue) {
            self.stats = stats
        }
    }

    private func confirmRemoveAuthorization(for account: AccountSummary) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = self.text(.confirmRemoveAuthorizationTitle)
        alert.informativeText = "\(account.label)\n\n\(self.text(.confirmRemoveAuthorizationMessage))"
        alert.addButton(withTitle: self.text(.actionRemoveAuthorization))
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func batchRemoveAccountsConfirmationContent(for accounts: [AccountSummary]) -> BatchRemoveAccountsConfirmationContent {
        let previewLabels = accounts.prefix(5).map(\.label).joined(separator: "\n")
        let moreCount = max(0, accounts.count - 5)
        let moreText = moreCount > 0
            ? self.localized(zh: "\n等 \(accounts.count) 个账号", en: "\nand \(moreCount) more")
            : ""
        return BatchRemoveAccountsConfirmationContent(
            title: self.text(.confirmBatchRemoveAccountsTitle),
            informativeText: self.localized(
                zh: "即将从账号池移除以下账号：\n\n\(previewLabels)\(moreText)\n\n这个操作只删除本地保存的授权记录，不会清除外部服务上的账号。",
                en: "The following accounts will be removed from the account pool:\n\n\(previewLabels)\(moreText)\n\nThis only removes locally saved authorizations and does not delete external provider accounts."
            ),
            actionTitle: self.text(.confirmBatchRemoveAccountsAction)
        )
    }

    func stopDaemonConfirmationContent() -> StopDaemonConfirmationContent {
        StopDaemonConfirmationContent(
            title: self.text(.confirmStopDaemonTitle),
            informativeText: self.text(.confirmStopDaemonMessage),
            warningText: self.settings.autoStart ? self.text(.confirmStopDaemonAutoStartWarning) : nil
        )
    }

    func clearAccountManagedProxyNodesConfirmationContent() -> ClearAccountManagedProxyNodesConfirmationContent {
        ClearAccountManagedProxyNodesConfirmationContent(
            title: self.text(.confirmClearAccountManagedProxyNodesTitle),
            informativeText: self.text(.confirmClearAccountManagedProxyNodesMessage),
            actionTitle: self.text(.confirmClearAccountManagedProxyNodesAction)
        )
    }

    func stopAccountCooldownConfirmationContent(for account: AccountSummary) -> AccountCooldownStopConfirmationContent {
        AccountCooldownStopConfirmationContent(
            title: self.text(.confirmStopAccountCooldownTitle),
            informativeText: self.localized(
                zh: "即将停止 `\(account.label)` 的本地 API Key 冷却状态。确认后该账号会立刻重新参与请求路由；如果上游仍然失败，系统会重新累计失败并再次进入冷却。",
                en: "This stops the local API key cooldown for `\(account.label)`. After confirmation, this account can be routed immediately again. If the upstream still fails, failures will be counted again and cooldown may return."
            ),
            actionTitle: self.text(.confirmStopAccountCooldownAction)
        )
    }

    func deleteRemoteHostConfirmationContent(for host: RemoteHostConfig) -> DeleteRemoteHostConfirmationContent {
        let hostName = host.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? host.host
            : host.label
        return DeleteRemoteHostConfirmationContent(
            title: self.text(.confirmDeleteRemoteHostTitle),
            informativeText: self.localized(
                zh: "即将删除远程主机 `\(hostName)` 的已保存配置。这不会修改远端机器上的已部署服务，只会从桌面端移除这条记录。",
                en: "This removes the saved configuration for `\(hostName)` from the desktop app only. It does not change anything already deployed on the remote machine."
            ),
            actionTitle: self.text(.confirmDeleteRemoteHostAction)
        )
    }

    private func confirmStopDaemon() -> Bool {
        if let confirmStopDaemonHandler {
            return confirmStopDaemonHandler()
        }

        let content = self.stopDaemonConfirmationContent()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        if let warningText = content.warningText {
            alert.accessoryView = self.stopDaemonWarningAccessoryView(text: warningText)
        }
        alert.addButton(withTitle: self.text(.confirmStopDaemonAction))
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmClearAccountManagedProxyNodes() -> Bool {
        if let confirmClearAccountManagedProxyNodesHandler {
            return confirmClearAccountManagedProxyNodesHandler()
        }

        let content = self.clearAccountManagedProxyNodesConfirmationContent()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmStopAccountCooldown(for account: AccountSummary) -> Bool {
        let content = self.stopAccountCooldownConfirmationContent(for: account)
        if let confirmStopAccountCooldownHandler {
            return confirmStopAccountCooldownHandler(content)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmBatchRemoveAccounts(_ accounts: [AccountSummary]) -> Bool {
        let content = self.batchRemoveAccountsConfirmationContent(for: accounts)
        if let confirmBatchRemoveAccountsHandler {
            return confirmBatchRemoveAccountsHandler(content)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDeleteRemoteHost(_ host: RemoteHostConfig) -> Bool {
        if let confirmDeleteRemoteHostHandler {
            return confirmDeleteRemoteHostHandler(host)
        }

        let content = self.deleteRemoteHostConfirmationContent(for: host)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.actionTitle)
        alert.addButton(withTitle: self.text(.commonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func stopDaemonWarningAccessoryView(text: String) -> NSView {
        let warningLabel = NSTextField(labelWithString: text)
        warningLabel.isEditable = false
        warningLabel.isSelectable = false
        warningLabel.isBordered = false
        warningLabel.drawsBackground = false
        warningLabel.textColor = .systemRed
        warningLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 0
        warningLabel.usesSingleLineMode = false
        warningLabel.cell?.wraps = true
        warningLabel.cell?.usesSingleLineMode = false

        let width: CGFloat = 320
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let fittedSize = warningLabel.cell?.cellSize(forBounds: bounds) ?? .zero
        warningLabel.frame = NSRect(x: 0, y: 0, width: width, height: ceil(fittedSize.height))

        let container = NSView(frame: warningLabel.frame)
        container.addSubview(warningLabel)
        return container
    }

    private func publishLaunchConfigurationOutcome(
        _ outcome: LocalDaemonController.ApplyLaunchConfigurationOutcome,
        successTitle: String,
        successDetail: String?
    ) {
        switch outcome {
        case .appliedNow:
            self.publishBanner(.success, title: successTitle, detail: successDetail)
        case .savedButRestartRequired:
            self.publishBanner(
                .warning,
                title: successTitle,
                detail: self.text(.warningLaunchConfigurationSavedRestartRequired)
            )
        }
    }

    private func beginOAuthObservation(for draft: OAuthDraft) {
        self.oauthObservationTask?.cancel()
        let draftID = draft.id
        let expectedAuthMode = draft.expectedAuthMode
        let baselineUpdatedAtByAccountKey = draft.baselineUpdatedAtByAccountKey
        self.oauthObservationTask = Task { [weak self] in
            await self?.observeOAuthCompletion(
                draftID: draftID,
                expectedAuthMode: expectedAuthMode,
                baselineUpdatedAtByAccountKey: baselineUpdatedAtByAccountKey
            )
        }
    }

    private func observeOAuthCompletion(
        draftID: UUID,
        expectedAuthMode: AccountAuthMode,
        baselineUpdatedAtByAccountKey: [String: Int64]
    ) async {
        for _ in 0..<150 {
            guard Task.isCancelled == false else { return }
            try? await Task.sleep(for: .seconds(2))
            guard Task.isCancelled == false else { return }
            guard self.oauthDraft?.id == draftID else { return }

            do {
                let accounts = try await self.admin.getAccounts()
                if let imported = self.observedImportedOAuthAccount(
                    in: accounts,
                    expectedAuthMode: expectedAuthMode,
                    baselineUpdatedAtByAccountKey: baselineUpdatedAtByAccountKey
                ) {
                    self.accounts = accounts
                    self.status = try? await self.admin.getStatus()
                    self.oauthDraft = nil
                    self.oauthObservationTask = nil
                    self.publishSuccess(.completeOAuth, detail: imported.label)
                    return
                }
            } catch {
                continue
            }
        }

        if self.oauthDraft?.id == draftID {
            self.oauthObservationTask = nil
        }
    }
}
#endif
