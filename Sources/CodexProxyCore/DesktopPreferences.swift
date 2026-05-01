import Foundation

public enum DesktopLanguageMode: String, Codable, Sendable, CaseIterable, Equatable {
    case system
    case zhHans
    case english
}

public enum DesktopThemeMode: String, Codable, Sendable, CaseIterable, Equatable {
    case system
    case light
    case dark
}

public enum DesktopInterfaceMode: String, Codable, Sendable, CaseIterable, Equatable {
    case minimal
    case full
}

public enum DesktopAccountPoolDisplayMode: String, Codable, Sendable, CaseIterable, Equatable {
    case cards
    case list
}

public struct DesktopPreferences: Codable, Sendable, Equatable {
    public var languageMode: DesktopLanguageMode
    public var themeMode: DesktopThemeMode
    public var interfaceMode: DesktopInterfaceMode
    public var accountPoolDisplayMode: DesktopAccountPoolDisplayMode
    public var showsMenuBarTokenUsage: Bool
    public var hasSeenHelpWindow: Bool
    public var hasAutoPresentedOnboardingAfterHelp: Bool

    public init(
        languageMode: DesktopLanguageMode = .system,
        themeMode: DesktopThemeMode = .system,
        interfaceMode: DesktopInterfaceMode = .minimal,
        accountPoolDisplayMode: DesktopAccountPoolDisplayMode = .cards,
        showsMenuBarTokenUsage: Bool = true,
        hasSeenHelpWindow: Bool = false,
        hasAutoPresentedOnboardingAfterHelp: Bool = false
    ) {
        self.languageMode = languageMode
        self.themeMode = themeMode
        self.interfaceMode = interfaceMode
        self.accountPoolDisplayMode = accountPoolDisplayMode
        self.showsMenuBarTokenUsage = showsMenuBarTokenUsage
        self.hasSeenHelpWindow = hasSeenHelpWindow
        self.hasAutoPresentedOnboardingAfterHelp = hasAutoPresentedOnboardingAfterHelp
    }

    private enum CodingKeys: String, CodingKey {
        case languageMode
        case themeMode
        case interfaceMode
        case accountPoolDisplayMode
        case showsMenuBarTokenUsage
        case hasSeenHelpWindow
        case hasAutoPresentedOnboardingAfterHelp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            languageMode: try container.decodeIfPresent(DesktopLanguageMode.self, forKey: .languageMode) ?? .system,
            themeMode: try container.decodeIfPresent(DesktopThemeMode.self, forKey: .themeMode) ?? .system,
            interfaceMode: try container.decodeIfPresent(DesktopInterfaceMode.self, forKey: .interfaceMode) ?? .full,
            accountPoolDisplayMode: try container.decodeIfPresent(DesktopAccountPoolDisplayMode.self, forKey: .accountPoolDisplayMode) ?? .cards,
            showsMenuBarTokenUsage: try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarTokenUsage) ?? true,
            hasSeenHelpWindow: try container.decodeIfPresent(Bool.self, forKey: .hasSeenHelpWindow) ?? false,
            hasAutoPresentedOnboardingAfterHelp: try container.decodeIfPresent(Bool.self, forKey: .hasAutoPresentedOnboardingAfterHelp) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.languageMode, forKey: .languageMode)
        try container.encode(self.themeMode, forKey: .themeMode)
        try container.encode(self.interfaceMode, forKey: .interfaceMode)
        try container.encode(self.accountPoolDisplayMode, forKey: .accountPoolDisplayMode)
        try container.encode(self.showsMenuBarTokenUsage, forKey: .showsMenuBarTokenUsage)
        try container.encode(self.hasSeenHelpWindow, forKey: .hasSeenHelpWindow)
        try container.encode(self.hasAutoPresentedOnboardingAfterHelp, forKey: .hasAutoPresentedOnboardingAfterHelp)
    }
}

public final class DesktopPreferencesStore: @unchecked Sendable {
    private let dataDirectory: URL

    public init(dataDirectory: URL = Paths.defaultDataDirectory()) {
        self.dataDirectory = dataDirectory
    }

    public func load() -> DesktopPreferences {
        let url = Paths.desktopPreferencesURL(in: self.dataDirectory)
        guard
            let data = try? Data(contentsOf: url),
            let preferences = try? Helpers.readJSON(DesktopPreferences.self, from: data)
        else {
            return DesktopPreferences()
        }
        return preferences
    }

    public func save(_ preferences: DesktopPreferences) throws {
        let data = try Helpers.encodeJSON(preferences, pretty: true)
        try Helpers.writeFile(Paths.desktopPreferencesURL(in: self.dataDirectory), data: data)
    }
}

public enum LocalizedTextKey: String, Sendable, CaseIterable {
    case brandName
    case brandSubtitle
    case overviewTitle
    case overviewSubtitle
    case accountsTitle
    case accountsSubtitle
    case proxyTitle
    case proxySubtitle
    case remoteTitle
    case remoteSubtitle
    case settingsTitle
    case settingsSubtitle
    case menuDaemonRunning
    case menuDaemonStopped
    case menuNoEndpoint
    case menuOpenMinimalMode
    case menuOpenFullMode
    case menuOpenDashboard
    case menuReload
    case menuQuit
    case menuAboutApp
    case menuSettings
    case menuHideApp
    case menuHideOthers
    case menuShowAll
    case menuEdit
    case menuView
    case menuUndo
    case menuRedo
    case menuCut
    case menuPaste
    case menuSelectAll
    case commonReload
    case commonCancel
    case commonDismiss
    case commonCopy
    case commonAll
    case statusRunning
    case statusStopped
    case statusEnabled
    case statusDisabled
    case statusOnline
    case statusOffline
    case statusChecking
    case statusDeploying
    case statusRedeploying
    case statusStarting
    case statusStopping
    case statusRunningDegraded
    case statusInstalledNotRunning
    case statusCurrent
    case statusUnavailable
    case statusUnknown
    case statusRegistered
    case statusNotRegistered
    case statusNotInstalled
    case statusUnlimited
    case statusNoData
    case statusLoadingModels
    case statusLoadingLogs
    case statusCoolingDown
    case statusOAuthAccount
    case statusAPIKeyAccount
    case statusReady
    case statusSuccess
    case statusTesting
    case statusCompleted
    case statusFailed
    case statusCancelled
    case statusNotApplicable
    case labelStatus
    case labelTime
    case labelTimeRange
    case labelFrom
    case labelTo
    case labelSortBy
    case labelSortDirection
    case labelAccounts
    case labelRequests
    case labelFailures
    case labelInputTokens
    case labelOutputTokens
    case labelNaturalTokenUsage
    case labelTotalTokens
    case labelCacheHitTokens
    case labelRateLimits
    case labelQuotaErrors
    case labelEndpoint
    case labelUpstreamURL
    case labelUpstreamAdapter
    case labelThinkingCompatibility
    case labelOpenAIBaseURL
    case labelAPIKey
    case labelAllowedAccounts
    case labelPrimary
    case labelAnthropicBaseURL
    case labelAnthropicAuthToken
    case labelClaudeCodeEnv
    case labelGeminiBaseURL
    case labelGeminiCLIEnv
    case labelAnthropicDefaultTargetModel
    case labelAnthropicSourceModel
    case labelAnthropicTargetModel
    case labelClientSource
    case labelAccountLabel
    case labelActiveLabel
    case labelActiveAccount
    case labelLastError
    case labelErrorSummary
    case labelPublicHost
    case labelPublicPort
    case labelAdminPort
    case labelAutoStart
    case labelLabel
    case labelHost
    case labelSSHUser
    case labelSSHPort
    case labelAuth
    case labelSSHPassword
    case labelIdentityFile
    case labelPrivateKey
    case labelRemoteDirectory
    case labelScheme
    case labelUsername
    case labelPassword
    case labelCloseAction
    case labelChatGPTBaseURL
    case labelDaemonBinaryOverride
    case labelStatsRetentionDays
    case labelLanguage
    case labelTheme
    case labelDisplay
    case labelMenuBarTokenUsage
    case labelPlan
    case labelEmail
    case labelIssue
    case labelFilteredResults
    case labelCredits
    case labelProviderPreset
    case labelAccountBaseURL
    case labelModel
    case labelRequestedModel
    case labelActualModel
    case labelReasoningEffort
    case labelTestAccount
    case labelInterface
    case labelStream
    case labelToolsJSON
    case labelSystemPrompt
    case labelUserPrompt
    case labelRequestPreview
    case labelRawResponse
    case labelStreamTranscript
    case labelLatency
    case labelHTTPStatus
    case labelResponseText
    case labelInstalled
    case labelRunning
    case labelLaunchctlState
    case labelEnabled
    case labelArchitecture
    case labelRemoteUser
    case labelSystemctl
    case labelSudo
    case labelLocalArtifacts
    case labelReadiness
    case labelProxySummary
    case labelCurrentEffectiveProxyMode
    case labelPendingProxyMode
    case labelStdoutLog
    case labelStderrLog
    case labelRedirectURI
    case labelLastRefreshed
    case labelOutboundNode
    case labelModelRouting
    case sectionRuntime
    case sectionTraffic
    case sectionLatestActivity
    case sectionQuickActions
    case sectionOAuthFlow
    case sectionAccountPool
    case sectionAccessInfo
    case sectionAPIKeys
    case sectionAPIKeyUsage
    case sectionAdvanced
    case sectionAnthropicAccess
    case sectionAnthropicModelMapping
    case sectionGeminiAccess
    case sectionRuntimeSelection
    case sectionNetworkSettings
    case sectionRemoteHost
    case sectionRemoteConnection
    case sectionRemoteAuthentication
    case sectionRemoteRuntimeConfig
    case sectionRemoteVerification
    case sectionRemoteOperations
    case sectionRemoteStatus
    case sectionLogs
    case sectionAppearance
    case sectionGeneral
    case sectionOutboundProxy
    case sectionBehavior
    case sectionService
    case sectionSavedHosts
    case sectionServiceDiagnostics
    case sectionRequestLogFilters
    case sectionRequestLogs
    case sectionTestRequest
    case sectionTestResult
    case actionStartDaemon
    case actionStopDaemon
    case actionDaemonAlreadyRunning
    case actionDaemonAlreadyStopped
    case actionImportCurrentAuth
    case actionOAuthLogin
    case actionImportCurrent
    case actionImportLocalAccountsToRemote
    case actionImportJSON
    case actionExportBackup
    case actionManualAddAccount
    case actionRefreshUsage
    case actionRefreshingUsage
    case actionAccountCardRefresh
    case actionAccountCardRefreshing
    case actionAccountCardEdit
    case actionAccountCardNode
    case actionAccountCardMore
    case actionStopAccountCooldown
    case actionSaveAccount
    case actionRotateAPIKey
    case actionOpenRequestLogs
    case actionSaveProxySettings
    case actionConfirmProxyModeChange
    case actionSaveManualProxy
    case actionSaveGeneralSettings
    case actionSaveHost
    case actionCreateRemoteHost
    case actionDeleteHost
    case actionSaveAndContinue
    case actionTestConnection
    case actionRetestConnection
    case actionBack
    case actionContinue
    case actionDeploy
    case actionRedeploy
    case actionLoadStatus
    case actionStart
    case actionStop
    case actionLogs
    case actionCopyEndpoint
    case actionCopyUpstreamURL
    case actionCopyAPIKey
    case actionCopyClaudeCodeEnv
    case actionCopyGeminiCLIEnv
    case actionAddAPIKey
    case actionEditAPIKey
    case actionEditAccountName
    case actionEditOutboundNode
    case actionEditModelRouting
    case actionRemoveAPIKey
    case actionSetPrimaryAPIKey
    case actionRegenerateAPIKey
    case actionEnableAPIKey
    case actionDisableAPIKey
    case actionSelectAllCompatibleAccounts
    case actionClearAccountRestriction
    case actionSelectTimeRange
    case actionAddAnthropicMapping
    case actionRemoveAnthropicMapping
    case actionCreateFirstHost
    case actionApplyNow
    case actionLoadLocalLogs
    case actionEnableAccount
    case actionDisableAccount
    case actionRemoveAuthorization
    case actionManageAccountOrder
    case actionSaveAccountOrder
    case actionClearAccountManagedProxyNodes
    case actionClearFilters
    case actionTestProxy
    case actionOpenHelp
    case actionSendTest
    case actionCancelTest
    case actionPreviousPage
    case actionNextPage
    case actionCopyErrorSummary
    case actionQueryRequestLogs
    case actionExportRequestLogs
    case actionCopyTime
    case actionCopyModel
    case actionCopyRequestedModel
    case actionCopyActualModel
    case actionCopyReasoningEffort
    case actionCopyAccountLabel
    case actionCopyRowCSV
    case placeholderNoEndpoint
    case placeholderNoAccounts
    case placeholderSearchAccounts
    case placeholderNoMatchingAccounts
    case placeholderManualAccountLabel
    case placeholderManualAccountBaseURL
    case placeholderAliyunCodingPlanBaseURL
    case placeholderAnthropicAPICompatibleBaseURL
    case placeholderGoogleGeminiCompatibleBaseURL
    case placeholderManualAccountAPIKey
    case placeholderNoRecentRequests
    case placeholderNoRemoteStatus
    case placeholderNoLogs
    case placeholderNoRemoteLogsForHost
    case placeholderNoLocalLogs
    case placeholderProxyTestPrompt
    case placeholderProxyTestSystem
    case placeholderProxyTestTools
    case placeholderProxyTestResult
    case placeholderNoRequestLogs
    case placeholderNoProxyAPIKeys
    case placeholderNoProxyAPIKeyUsage
    case placeholderProxyAPIKeyNoCompatibleAccounts
    case helperAppearanceAppliesImmediately
    case helperThemeFollowsSystem
    case helperLanguageFollowsSystem
    case helperThemeOptionSystem
    case helperThemeOptionLight
    case helperThemeOptionDark
    case helperLanguageOptionSystem
    case helperLanguageOptionChinese
    case helperLanguageOptionEnglish
    case helperMenuBarTokenUsage
    case helperQuickActionOAuth
    case helperQuickActionImportCurrent
    case helperQuickActionImportLocalAccountsToRemote
    case helperQuickActionImportJSON
    case helperQuickActionManualAdd
    case helperQuickActionExportBackup
    case helperQuickActionTestProxy
    case helperQuickActionRefreshUsage
    case helperSelectionPolicy
    case helperManualAPIKeyAccount
    case helperManualAccountGenericOpenAICompatible
    case helperManualAccountUpstreamAdapter
    case helperManualAccountThinkingCompatibility
    case helperManualAccountAliyunCodingPlan
    case helperManualAccountAnthropicAPICompatible
    case helperManualAccountGoogleGeminiCompatible
    case helperAPIKeyAccountNoStandardUsage
    case helperAccountLabelRequired
    case helperManualAccountAPIKeyRequired
    case helperManualAccountBaseURLInvalid
    case errorManualAccountGoogleGeminiPresetRequired
    case errorManualAccountGoogleGeminiAPIKeyOnly
    case helperServiceDiagnostics
    case helperAnthropicConnection
    case helperGeminiConnection
    case helperOutboundProxyGlobalModeDisabled
    case helperSaveManualProxyDoesNotSwitchMode
    case helperConfirmProxyModeChangeNeedsManualSave
    case helperConfirmProxyModeChangeNeedsSubscription
    case helperProxyAPIKeys
    case helperProxyAPIKeyUsage
    case helperNaturalTokenUsage
    case helperProxyAPIKeyValueRequired
    case helperProxyAPIKeyAtLeastOne
    case helperProxyAPIKeyAtLeastOneEnabled
    case helperProxyAPIKeyAllowedAccounts
    case helperProxyAPIKeyStaleSelections
    case helperAnthropicModelMapping
    case helperAnthropicMappingFallback
    case helperAnthropicOAuthModelFallback
    case helperServiceChecking
    case helperServiceCanStart
    case helperServiceCanStop
    case helperServiceDegraded
    case helperServiceNotInstalled
    case helperServiceStarting
    case helperServiceStopping
    case warningLaunchConfigurationSavedRestartRequired
    case helperRemoteStatusRequired
    case helperRemoteCanStart
    case helperRemoteCanStop
    case helperRemoteUnreachable
    case helperRemoteStarting
    case helperRemoteStopping
    case helperRemoteNeedsSavedHost
    case helperRemoteNeedsVerification
    case helperRemoteSystemctlUnavailable
    case helperRemoteSudoUnavailable
    case helperRemoteDirectoryUnavailable
    case helperRemoteDeployUnavailable
    case helperRemoteRedeploy
    case helperRemoteOperationsLocked
    case oauthFlowDescription
    case oauthLinkLabel
    case oauthCallbackLabel
    case oauthCallbackPlaceholder
    case oauthListening
    case oauthOpenBrowser
    case oauthParseCallback
    case oauthManualHint
    case oauthAutoImportHint
    case oauthCallbackHint
    case oauthBrowserOpenFailed
    case oauthInvalidLink
    case oauthCallbackMissing
    case confirmStopDaemonTitle
    case confirmStopDaemonMessage
    case confirmStopDaemonAutoStartWarning
    case confirmStopDaemonAction
    case confirmClearAccountManagedProxyNodesTitle
    case confirmClearAccountManagedProxyNodesMessage
    case confirmClearAccountManagedProxyNodesAction
    case confirmStopAccountCooldownTitle
    case confirmStopAccountCooldownAction
    case confirmRemoveAuthorizationTitle
    case confirmRemoveAuthorizationMessage
    case confirmImportLocalAccountsToRemoteTitle
    case confirmImportLocalAccountsToRemoteAction
    case confirmDeleteRemoteHostTitle
    case confirmDeleteRemoteHostAction
    case helperNoMatchingAccounts
    case optionFollowSystem
    case optionLight
    case optionDark
    case optionChineseSimplified
    case optionEnglish
    case optionCards
    case optionList
    case optionDisabled
    case optionHTTP
    case optionHTTPS
    case optionSOCKS5
    case optionHideToMenuBar
    case optionQuit
    case optionSSHKeyPath
    case optionSSHKeyContent
    case optionPassword
    case optionHealthy
    case optionAnyIssue
    case optionRefreshBlocked
    case optionUsageIssue
    case optionCustom
    case optionToday
    case optionThisWeek
    case optionThisMonth
    case optionLastWeek
    case optionTwoWeeksAgo
    case optionThreeWeeksAgo
    case optionOther
    case optionLast15Minutes
    case optionLast1Hour
    case optionLast24Hours
    case optionLast7Days
    case optionAscending
    case optionDescending
    case optionChatCompletions
    case optionResponses
    case optionUpstreamAdapterChatCompletions
    case optionUpstreamAdapterResponses
    case optionThinkingCompatibilityDisabled
    case optionThinkingCompatibilityEnabled
    case optionAnthropicMessages
    case optionGeminiGenerateContent
    case optionAutoSelectByOrder
    case providerPresetGenericOpenAICompatible
    case providerPresetAliyunQwenCodingPlan
    case providerPresetAnthropicAPICompatible
    case providerPresetGoogleGeminiCompatible
    case remoteWorkflowHostsTitle
    case remoteWorkflowHostsSubtitle
    case remoteWorkflowConfigurationTitle
    case remoteWorkflowConfigurationSubtitle
    case remoteWorkflowVerificationTitle
    case remoteWorkflowVerificationSubtitle
    case remoteWorkflowOperationsTitle
    case remoteWorkflowOperationsSubtitle
    case remoteSavedHostsEmpty
    case remoteLogsHint
    case proxyConnectionHint
    case labelRecentFourWeeks
    case labelDailyTrend
    case labelWeeklyTrend
    case overviewServiceHint
    case overviewTrafficHint
    case overviewDiagnosticsHint
    case requestLogsTitle
    case requestLogsSubtitle
    case requestLogsFilterHint
    case requestLogsPendingFiltersHint
    case requestLogsPendingFiltersCompactHint
    case requestLogsTableHint
    case requestLogsEmptyHint
    case proxyTestTitle
    case proxyTestSubtitle
    case proxyTestHealthHint
    case proxyTestRequestHint
    case proxyTestResultHint
    case proxyTestFallbackModels
    case proxyTestMissingOpenAIDataSourceAPIKey
    case proxyTestMissingAnthropicDataSourceAPIKey
    case proxyTestMissingGeminiDataSourceAPIKey
    case proxyTestMissingAnthropicOAuthCompatibleAPIKey
    case proxyTestSelectedAccountOutsideAPIKeyAllowlist
    case helpWindowTitle
    case onboardingWindowTitle
    case helpWindowSubtitle
    case aboutWindowSubtitle
    case aboutOverviewTitle
    case aboutOverviewBody
    case aboutCapabilityAccounts
    case aboutCapabilityAccess
    case aboutCapabilityRemote
    case aboutDeveloperTitle
    case aboutDeveloperBody
    case errorOperationFailed
    case errorNetworkIssue
    case errorAuthorizationFailed
    case errorImportFailed
    case errorUsageRefreshFailed
    case errorRemoteConnectionFailed
    case errorRemoteDeployFailed
    case errorDaemonControlFailed
    case errorConfigurationFailed
    case errorAccountManagementFailed
    case errorCopyFailed
    case errorRequestLogsFailed
    case errorRequestLogsExportFailed
    case errorProxyTestFailed
    case errorProxyAPIKeyFailed
    case errorProxyAPIKeyUsageFailed
    case successDaemonStarted
    case successDaemonStopped
    case successAuthImported
    case successLocalAccountsImportedToRemote
    case successJSONImported
    case successBackupExported
    case successManualAPIKeyAccountAdded
    case successManualAPIKeyAccountUpdated
    case successAccountLabelUpdated
    case successAccountManagedProxyNodeUpdated
    case successAccountManagedProxyNodesCleared
    case successAccountModelRoutingUpdated
    case successAccountCooldownStopped
    case successUsageRefreshed
    case successAccountUsageRefreshed
    case successProxyKeyRotated
    case successSettingsSaved
    case successPreferencesSaved
    case successOAuthStarted
    case successOAuthCompleted
    case successRemoteConnectionTested
    case successRemoteDeployed
    case successRemoteHostDeleted
    case successRemoteStarted
    case successRemoteStopped
    case successRemoteStatusLoaded
    case successRemoteLogsLoaded
    case successCopiedEndpoint
    case successCopiedUpstreamURL
    case successCopiedAPIKey
    case successCopiedClaudeCodeEnv
    case successCopiedGeminiCLIEnv
    case successCopiedOAuthLink
    case successCopiedManagedProxyTerminalCommand
    case successCopiedErrorSummary
    case successCopiedTime
    case successCopiedModel
    case successCopiedRequestedModel
    case successCopiedActualModel
    case successCopiedReasoningEffort
    case successCopiedAccountLabel
    case successCopiedRowCSV
    case successRequestLogsExported
    case successHostSaved
    case successAccountEnabled
    case successAccountDisabled
    case successAuthorizationRemoved
    case successAccountOrderUpdated
    case successProxyTestCompleted
    case successProxyModelsLoaded
    case successProxyAPIKeyAdded
    case successProxyAPIKeyUpdated
    case successProxyAPIKeyRemoved
    case successProxyAPIKeyRegenerated
    case successProxyAPIKeyPrimaryChanged
}

public enum OperationContext: String, Sendable {
    case loadAll
    case loadRequestLogs
    case startDaemon
    case stopDaemon
    case importCurrentAuth
    case importLocalAccountsToRemote
    case importJSON
    case exportAccounts
    case manualAddAccount
    case manualUpdateAccount
    case renameAccountLabel
    case updateAccountManagedProxyNode
    case clearAccountManagedProxyNodes
    case updateAccountModelRouting
    case stopAccountCooldown
    case refreshUsage
    case refreshAccountUsage
    case rotateProxyKey
    case saveSettings
    case savePreferences
    case startOAuth
    case completeOAuth
    case remoteConnectionTest
    case deployRemote
    case remoteStatus
    case remoteStart
    case remoteStop
    case remoteLogs
    case copyEndpoint
    case copyAPIKey
    case copyClaudeCodeEnv
    case copyGeminiCLIEnv
    case copyOAuthLink
    case copyManagedProxyTerminalCommand
    case saveRemoteHost
    case deleteRemoteHost
    case enableAccount
    case disableAccount
    case removeAccount
    case reorderAccounts
    case runProxyTest
    case loadProxyTestModels
    case generic
}

public struct LocalizationStore: Sendable, Equatable {
    public struct RequestLogTokenSummaryLines: Sendable, Equatable {
        public let primaryLine: String
        public let secondaryLine: String

        public init(primaryLine: String, secondaryLine: String) {
            self.primaryLine = primaryLine
            self.secondaryLine = secondaryLine
        }
    }

    public struct MenuBarTokenUsageLines: Sendable, Equatable {
        public let primaryLine: String
        public let secondaryLine: String

        public init(primaryLine: String, secondaryLine: String) {
            self.primaryLine = primaryLine
            self.secondaryLine = secondaryLine
        }
    }

    public enum ResolvedLanguage: String, Sendable, Equatable {
        case zhHans
        case english
    }

    public let mode: DesktopLanguageMode
    public let preferredLanguages: [String]

    public init(
        mode: DesktopLanguageMode,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.mode = mode
        self.preferredLanguages = preferredLanguages
    }

    public var resolvedLanguage: ResolvedLanguage {
        switch self.mode {
        case .zhHans:
            return .zhHans
        case .english:
            return .english
        case .system:
            let first = self.preferredLanguages.first?.lowercased() ?? ""
            return first.hasPrefix("zh") ? .zhHans : .english
        }
    }

    public func text(_ key: LocalizedTextKey) -> String {
        Self.catalog[resolvedLanguage]?[key] ?? Self.catalog[.english]?[key] ?? key.rawValue
    }

    public func pageTitle(for rawValue: String) -> String {
        switch rawValue {
        case "overview":
            return self.text(.overviewTitle)
        case "accounts":
            return self.text(.accountsTitle)
        case "proxy":
            return self.text(.proxyTitle)
        case "remote":
            return self.text(.remoteTitle)
        case "settings":
            return self.text(.settingsTitle)
        default:
            return rawValue
        }
    }

    public func pageSubtitle(for rawValue: String) -> String {
        switch rawValue {
        case "overview":
            return self.text(.overviewSubtitle)
        case "accounts":
            return self.text(.accountsSubtitle)
        case "proxy":
            return self.text(.proxySubtitle)
        case "remote":
            return self.text(.remoteSubtitle)
        case "settings":
            return self.text(.settingsSubtitle)
        default:
            return self.text(.brandSubtitle)
        }
    }

    public func label(for mode: DesktopLanguageMode) -> String {
        switch mode {
        case .system:
            return self.text(.optionFollowSystem)
        case .zhHans:
            return self.text(.optionChineseSimplified)
        case .english:
            return self.text(.optionEnglish)
        }
    }

    public func label(for mode: DesktopThemeMode) -> String {
        switch mode {
        case .system:
            return self.text(.optionFollowSystem)
        case .light:
            return self.text(.optionLight)
        case .dark:
            return self.text(.optionDark)
        }
    }

    public func label(for scheme: OutboundProxyScheme) -> String {
        switch scheme {
        case .disabled:
            return self.text(.optionDisabled)
        case .http:
            return self.text(.optionHTTP)
        case .https:
            return self.text(.optionHTTPS)
        case .socks5:
            return self.text(.optionSOCKS5)
        }
    }

    public func label(for behavior: WindowCloseBehavior) -> String {
        switch behavior {
        case .hideToMenuBar:
            return self.text(.optionHideToMenuBar)
        case .quit:
            return self.text(.optionQuit)
        }
    }

    public func label(for authMode: RemoteHostConfig.AuthMode) -> String {
        switch authMode {
        case .sshKeyPath:
            return self.text(.optionSSHKeyPath)
        case .sshKeyContent:
            return self.text(.optionSSHKeyContent)
        case .password:
            return self.text(.optionPassword)
        }
    }

    public func label(for preset: RequestLogTimePreset) -> String {
        switch preset {
        case .last15Minutes:
            return self.text(.optionLast15Minutes)
        case .lastHour:
            return self.text(.optionLast1Hour)
        case .last24Hours:
            return self.text(.optionLast24Hours)
        case .last7Days:
            return self.text(.optionLast7Days)
        case .custom:
            return self.text(.optionCustom)
        }
    }

    public func label(for sortField: RequestLogSortField) -> String {
        switch sortField {
        case .time:
            return self.text(.labelTime)
        case .endpoint:
            return self.text(.labelInterface)
        case .model:
            return self.text(.labelModel)
        case .accountLabel:
            return self.text(.labelAccountLabel)
        case .status:
            return self.text(.labelStatus)
        case .latency:
            return self.text(.labelLatency)
        case .totalTokens:
            return self.text(.labelTotalTokens)
        }
    }

    public func label(for sortDirection: RequestLogSortDirection) -> String {
        switch sortDirection {
        case .ascending:
            return self.text(.optionAscending)
        case .descending:
            return self.text(.optionDescending)
        }
    }

    public func statusText(isRunning: Bool) -> String {
        self.text(isRunning ? .statusRunning : .statusStopped)
    }

    public func connectivityText(isRunning: Bool) -> String {
        self.text(isRunning ? .statusOnline : .statusOffline)
    }

    public func requestLogsSummaryText(totalCount: Int64, page: Int, pageSize: Int, hasMore: Bool) -> String {
        if self.resolvedLanguage == .zhHans {
            let suffix = hasMore ? "，可继续翻页" : ""
            return "共 \(totalCount) 条，第 \(page) 页，每页 \(pageSize) 条\(suffix)"
        }
        let suffix = hasMore ? ", more pages available" : ""
        return "\(totalCount) total, page \(page), \(pageSize) per page\(suffix)"
    }

    public func requestLogsLatencyText(_ latencyMS: Int64) -> String {
        self.localized(zh: "\(latencyMS) 毫秒", en: "\(latencyMS) ms")
    }

    public func requestLogsTokenSummaryLines(
        inputTokens: String,
        outputTokens: String,
        totalTokens: String,
        cacheHitTokens: String
    ) -> RequestLogTokenSummaryLines {
        if self.resolvedLanguage == .zhHans {
            return RequestLogTokenSummaryLines(
                primaryLine: "输入 \(inputTokens) / 输出 \(outputTokens)",
                secondaryLine: "总计 \(totalTokens) / 缓存 \(cacheHitTokens)"
            )
        }
        return RequestLogTokenSummaryLines(
            primaryLine: "Input \(inputTokens) / Output \(outputTokens)",
            secondaryLine: "Total \(totalTokens) / Cache \(cacheHitTokens)"
        )
    }

    public func menuBarTokenUsageLines(
        inputTokens: String,
        outputTokens: String
    ) -> MenuBarTokenUsageLines {
        if self.resolvedLanguage == .zhHans {
            return MenuBarTokenUsageLines(
                primaryLine: "入 \(inputTokens)",
                secondaryLine: "出 \(outputTokens)"
            )
        }
        return MenuBarTokenUsageLines(
            primaryLine: "In \(inputTokens)",
            secondaryLine: "Out \(outputTokens)"
        )
    }

    public func menuBarTokenUsageToolTip(
        appName: String,
        inputTokens: String,
        outputTokens: String
    ) -> String {
        if self.resolvedLanguage == .zhHans {
            return "\(appName)\n输入 Token \(inputTokens)\n输出 Token \(outputTokens)"
        }
        return "\(appName)\nInput Tokens \(inputTokens)\nOutput Tokens \(outputTokens)"
    }

    public func menuBarTokenUsageAccessibilityText(
        appName: String,
        inputTokens: String,
        outputTokens: String
    ) -> String {
        if self.resolvedLanguage == .zhHans {
            return "\(appName)，输入 Token \(inputTokens)，输出 Token \(outputTokens)"
        }
        return "\(appName), input tokens \(inputTokens), output tokens \(outputTokens)"
    }

    public func usageBalanceText(_ credits: CreditSnapshot?) -> String {
        guard let credits else { return self.text(.statusNoData) }
        if credits.unlimited {
            return self.text(.statusUnlimited)
        }
        return credits.balance?.isEmpty == false ? credits.balance! : self.text(.statusNoData)
    }

    public func accountQuotaBlockedLabel() -> String {
        self.localized(zh: "已超额", en: "Quota Blocked")
    }

    public func accountQuotaResetText(resetAt: String) -> String {
        self.localized(zh: "已超额，恢复时间 \(resetAt)", en: "Over quota until \(resetAt)")
    }

    public func accountUsageResetText(resetAt: String) -> String {
        self.localized(zh: "重置\n\(resetAt)", en: "Resets\n\(resetAt)")
    }

    public func planText(_ planType: String?) -> String {
        guard let planType, !planType.isEmpty else { return self.text(.statusUnknown) }
        switch planType.lowercased() {
        case "free":
            return self.resolvedLanguage == .zhHans ? "免费" : "Free"
        case "plus":
            return self.resolvedLanguage == .zhHans ? "Plus" : "Plus"
        case "pro":
            return self.resolvedLanguage == .zhHans ? "Pro" : "Pro"
        case "team":
            return self.resolvedLanguage == .zhHans ? "团队" : "Team"
        case "api_key", "openai_api_key":
            return self.resolvedLanguage == .zhHans ? "API Key" : "API Key"
        default:
            return planType
        }
    }

    public func successTitle(for context: OperationContext) -> String {
        switch context {
        case .startDaemon:
            return self.text(.successDaemonStarted)
        case .stopDaemon:
            return self.text(.successDaemonStopped)
        case .importCurrentAuth:
            return self.text(.successAuthImported)
        case .importLocalAccountsToRemote:
            return self.text(.successLocalAccountsImportedToRemote)
        case .importJSON:
            return self.text(.successJSONImported)
        case .exportAccounts:
            return self.text(.successBackupExported)
        case .manualAddAccount:
            return self.text(.successManualAPIKeyAccountAdded)
        case .manualUpdateAccount:
            return self.text(.successManualAPIKeyAccountUpdated)
        case .renameAccountLabel:
            return self.text(.successAccountLabelUpdated)
        case .updateAccountManagedProxyNode:
            return self.text(.successAccountManagedProxyNodeUpdated)
        case .clearAccountManagedProxyNodes:
            return self.text(.successAccountManagedProxyNodesCleared)
        case .updateAccountModelRouting:
            return self.text(.successAccountModelRoutingUpdated)
        case .stopAccountCooldown:
            return self.text(.successAccountCooldownStopped)
        case .refreshUsage:
            return self.text(.successUsageRefreshed)
        case .refreshAccountUsage:
            return self.text(.successAccountUsageRefreshed)
        case .rotateProxyKey:
            return self.text(.successProxyKeyRotated)
        case .saveSettings:
            return self.text(.successSettingsSaved)
        case .savePreferences:
            return self.text(.successPreferencesSaved)
        case .enableAccount:
            return self.text(.successAccountEnabled)
        case .disableAccount:
            return self.text(.successAccountDisabled)
        case .removeAccount:
            return self.text(.successAuthorizationRemoved)
        case .reorderAccounts:
            return self.text(.successAccountOrderUpdated)
        case .startOAuth:
            return self.text(.successOAuthStarted)
        case .completeOAuth:
            return self.text(.successOAuthCompleted)
        case .remoteConnectionTest:
            return self.text(.successRemoteConnectionTested)
        case .deployRemote:
            return self.text(.successRemoteDeployed)
        case .deleteRemoteHost:
            return self.text(.successRemoteHostDeleted)
        case .remoteStart:
            return self.text(.successRemoteStarted)
        case .remoteStop:
            return self.text(.successRemoteStopped)
        case .remoteStatus:
            return self.text(.successRemoteStatusLoaded)
        case .remoteLogs:
            return self.text(.successRemoteLogsLoaded)
        case .copyEndpoint:
            return self.text(.successCopiedEndpoint)
        case .copyAPIKey:
            return self.text(.successCopiedAPIKey)
        case .copyClaudeCodeEnv:
            return self.text(.successCopiedClaudeCodeEnv)
        case .copyGeminiCLIEnv:
            return self.text(.successCopiedGeminiCLIEnv)
        case .copyOAuthLink:
            return self.text(.successCopiedOAuthLink)
        case .copyManagedProxyTerminalCommand:
            return self.text(.successCopiedManagedProxyTerminalCommand)
        case .saveRemoteHost:
            return self.text(.successHostSaved)
        case .loadRequestLogs:
            return self.text(.statusReady)
        case .runProxyTest:
            return self.text(.successProxyTestCompleted)
        case .loadProxyTestModels:
            return self.text(.successProxyModelsLoaded)
        case .loadAll, .generic:
            return self.text(.successSettingsSaved)
        }
    }

    public func errorTitle(for detail: String, context: OperationContext) -> String {
        let extracted = Self.extractPrimaryErrorMessage(from: detail)
        if let diagnostic = DecodingDiagnostics.parse(extracted) {
            return self.decodingErrorTitle(for: diagnostic)
        }

        let lower = extracted.lowercased()
        if context == .refreshUsage || context == .refreshAccountUsage || lower.contains("usage") || lower.contains("quota") {
            return self.text(.errorUsageRefreshFailed)
        }
        if context == .loadRequestLogs || lower.contains("request log") || lower.contains("stats/request") {
            return self.text(.errorRequestLogsFailed)
        }
        if context == .deployRemote || lower.contains("systemctl") {
            return self.text(.errorRemoteDeployFailed)
        }
        if context == .remoteConnectionTest || context == .remoteLogs || context == .remoteStatus || context == .remoteStart || context == .remoteStop || lower.contains("ssh") || lower.contains("permission denied") {
            return self.text(.errorRemoteConnectionFailed)
        }
        if context == .startDaemon || context == .stopDaemon || lower.contains("launchctl") || lower.contains("daemon") {
            return self.text(.errorDaemonControlFailed)
        }
        if context == .importCurrentAuth || context == .importLocalAccountsToRemote || context == .importJSON || context == .manualAddAccount || lower.contains("auth.json") || lower.contains("import") {
            return self.text(.errorImportFailed)
        }
        if context == .startOAuth || context == .completeOAuth || lower.contains("oauth") || lower.contains("authorization") || lower.contains("invalid proxy api key") || lower.contains("invalid admin token") {
            return self.text(.errorAuthorizationFailed)
        }
        if context == .saveSettings || context == .saveRemoteHost || context == .deleteRemoteHost || lower.contains("config") || lower.contains("settings") {
            return self.text(.errorConfigurationFailed)
        }
        if context == .enableAccount || context == .disableAccount || context == .removeAccount || context == .manualUpdateAccount || context == .renameAccountLabel || context == .updateAccountManagedProxyNode || context == .clearAccountManagedProxyNodes || context == .updateAccountModelRouting || context == .stopAccountCooldown || context == .reorderAccounts {
            return self.text(.errorAccountManagementFailed)
        }
        if context == .copyEndpoint || context == .copyAPIKey || context == .copyClaudeCodeEnv || context == .copyGeminiCLIEnv || context == .copyOAuthLink || context == .copyManagedProxyTerminalCommand {
            return self.text(.errorCopyFailed)
        }
        if lower.contains("timed out") || lower.contains("could not connect") || lower.contains("network") || lower.contains("offline") || lower.contains("http") {
            return self.text(.errorNetworkIssue)
        }
        if context == .runProxyTest || context == .loadProxyTestModels {
            return self.text(.errorProxyTestFailed)
        }
        return self.text(.errorOperationFailed)
    }

    public func successDetail(for context: OperationContext, rawDetail: String?) -> String? {
        guard let detail = Self.cleanMessage(rawDetail) else { return nil }
        switch context {
        case .startOAuth:
            return self.localized(zh: "本地浏览器回调地址：\(detail)", en: "Local browser callback URL: \(detail)")
        case .completeOAuth:
            return self.localized(zh: "已导入账号：\(detail)", en: "Imported account: \(detail)")
        case .manualAddAccount:
            return self.localized(zh: "已添加账号：\(detail)", en: "Added account: \(detail)")
        case .manualUpdateAccount:
            return self.localized(zh: "已更新账号：\(detail)", en: "Updated account: \(detail)")
        case .renameAccountLabel:
            return self.localized(zh: "已更新账号名称：\(detail)", en: "Updated account name: \(detail)")
        case .updateAccountManagedProxyNode:
            return self.localized(zh: "已更新账号出站节点：\(detail)", en: "Updated account outbound node: \(detail)")
        case .clearAccountManagedProxyNodes:
            let count = max(Int(detail) ?? 0, 0)
            return self.localized(
                zh: "已清空 \(count) 个账号的自定义出站节点",
                en: count == 1
                    ? "Cleared the custom outbound node override for 1 account"
                    : "Cleared custom outbound node overrides for \(count) accounts"
            )
        case .updateAccountModelRouting:
            return self.localized(zh: "已更新账号模型转换：\(detail)", en: "Updated account model routing: \(detail)")
        case .stopAccountCooldown:
            return self.localized(zh: "已停止账号冷却：\(detail)", en: "Stopped account cooldown: \(detail)")
        case .enableAccount:
            return self.localized(zh: "已启用账号：\(detail)", en: "Enabled account: \(detail)")
        case .disableAccount:
            return self.localized(zh: "已停用账号：\(detail)", en: "Disabled account: \(detail)")
        case .removeAccount:
            return self.localized(zh: "已移除本地授权：\(detail)", en: "Removed local authorization: \(detail)")
        case .refreshAccountUsage:
            return self.localized(zh: "已刷新账号：\(detail)", en: "Refreshed account: \(detail)")
        case .reorderAccounts:
            return self.localized(zh: "账号调用顺序已更新", en: "Updated account routing order")
        default:
            return detail
        }
    }

    public func errorDetail(for rawDetail: String?, context: OperationContext) -> String? {
        guard let detail = Self.cleanMessage(rawDetail) else { return nil }
        let extracted = Self.extractPrimaryErrorMessage(from: detail)
        guard !extracted.isEmpty else { return nil }
        if let diagnostic = DecodingDiagnostics.parse(extracted) {
            return self.decodingErrorDetail(for: diagnostic)
        }
        let localized = self.localizedCompositeErrorMessage(from: extracted, context: context)
        return localized.isEmpty ? extracted : localized
    }

    private func localizedCompositeErrorMessage(from detail: String, context: OperationContext) -> String {
        let separator = self.resolvedLanguage == .zhHans ? "；" : "; "
        let parts = detail
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return detail }
        return parts.map { self.localizedErrorSegment($0, context: context) }.joined(separator: separator)
    }

    private func localizedErrorSegment(_ segment: String, context: OperationContext) -> String {
        let direct = self.localizedKnownError(segment, context: context)
        if direct != segment {
            return direct
        }

        guard
            let range = segment.range(of: ": "),
            segment.contains("://") == false
        else {
            return segment
        }

        let prefix = String(segment[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(segment[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !suffix.isEmpty else {
            return segment
        }

        let localizedSuffix = self.localizedKnownError(suffix, context: context)
        if localizedSuffix == suffix {
            return segment
        }
        return "\(prefix): \(localizedSuffix)"
    }

    private func localizedKnownError(_ message: String, context _: OperationContext) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }

        let lower = trimmed.lowercased()

        if lower.contains("unsupported_country_region_territory")
            || lower.contains("country, region, or territory")
            || lower.contains("所在的国家")
        {
            return self.localized(
                zh: "当前网络出口所在地区暂不支持访问 OpenAI，请切换到可用代理或网络后再试。",
                en: "Your current network region cannot access OpenAI. Switch to a supported proxy or network and try again."
            )
        }

        if lower.contains("invalid proxy api key") || lower.contains("missing proxy api key") {
            return self.localized(
                zh: "本地代理 API Key 无效或缺失，请检查接入配置后重试。",
                en: "The local proxy API key is missing or invalid. Check the client connection settings and try again."
            )
        }

        if lower.contains("invalid admin token") || lower.contains("missing admin token") {
            return self.localized(
                zh: "本地管理令牌无效，请刷新本地服务状态后重试。",
                en: "The local admin token is invalid. Refresh the local service state and try again."
            )
        }

        if lower.contains("multiple authentication credentials received")
            || lower.contains("gemini api key")
                && (lower.contains("google ai pro") || lower.contains("oauth"))
            || lower.contains("gemini cli") && (lower.contains("third-party") || lower.contains("第三方"))
            || lower.contains("目前只支持 gemini api key")
        {
            return self.text(.errorManualAccountGoogleGeminiAPIKeyOnly)
        }

        if lower.contains("oauth 授权已过期") || (lower.contains("oauth") && lower.contains("expired")) {
            return self.localized(
                zh: "这次 OAuth 授权已经过期，请重新生成授权链接后再试。",
                en: "This OAuth authorization has expired. Generate a new authorization link and try again."
            )
        }

        if lower.contains("没有进行中的 oauth 登录") || lower.contains("open auth page first") {
            return self.localized(
                zh: "当前没有进行中的 OAuth 授权，请先重新打开授权页面。",
                en: "There is no active OAuth session. Open the authorization page again first."
            )
        }

        if lower.contains("oauth callback 缺少 state") || lower.contains("missing the state parameter") {
            return self.localized(
                zh: "回调链接缺少 `state` 参数，请重新完成浏览器授权。",
                en: "The callback URL is missing the `state` parameter. Complete the browser authorization again."
            )
        }

        if lower.contains("oauth callback 缺少 code") || lower.contains("missing the code parameter") {
            return self.localized(
                zh: "回调链接缺少 `code` 参数，请重新完成浏览器授权。",
                en: "The callback URL is missing the `code` parameter. Complete the browser authorization again."
            )
        }

        if lower.contains("oauth state 不匹配") || lower.contains("state does not match") {
            return self.localized(
                zh: "这条回调链接和当前授权流程不匹配，请重新生成授权链接后再试。",
                en: "This callback URL does not match the current authorization session. Generate a new authorization link and try again."
            )
        }

        if lower.contains("请提供完整的回调链接") || lower.contains("callback url is required") {
            return self.localized(
                zh: "请粘贴浏览器跳转后的完整回调链接。",
                en: "Paste the full callback URL from the browser redirect."
            )
        }

        if lower.contains("回调链接格式无效") || lower.contains("callback url format is invalid") {
            return self.localized(
                zh: "回调链接格式不正确，请确认复制的是完整跳转地址。",
                en: "The callback URL format is invalid. Make sure you copied the full redirect URL."
            )
        }

        if lower.contains("授权失败:") || lower.contains("authorization failed:") || lower.contains("access_denied") || lower.contains("user cancelled") || lower.contains("user canceled") {
            return self.localized(
                zh: "浏览器授权没有完成，请重新登录并确认授权。",
                en: "The browser authorization did not complete. Sign in again and approve access."
            )
        }

        if lower.contains("openai 授权页返回错误") || lower.contains("authapifailure") || lower.contains("request_id=") {
            let summary = self.localized(
                zh: "OpenAI 授权页拒绝了这次浏览器登录请求，请重新生成授权链接后重试。",
                en: "OpenAI rejected this browser sign-in request. Generate a new authorization link and try again."
            )
            let detailPrefix = self.localized(zh: "详情", en: "Details")
            return "\(summary) \(detailPrefix): \(trimmed)"
        }

        if lower.contains("oauth token 交换失败") || lower.contains("换取登录令牌失败") || lower.contains("token exchange failed") {
            return self.localized(
                zh: "向 OpenAI 换取登录令牌失败，请检查网络或代理后重试。",
                en: "OpenAI token exchange failed. Check your network or proxy settings and try again."
            )
        }

        if lower.contains("刷新 token 失败") || lower.contains("refresh token") {
            return self.localized(
                zh: "刷新账号令牌失败，请检查账号状态、网络或代理设置。",
                en: "Refreshing the account token failed. Check the account status and your network or proxy settings."
            )
        }

        if lower.contains("oauth token 返回缺少字段") || lower.contains("missing required fields") {
            return self.localized(
                zh: "官方授权返回的数据不完整，请重新授权后再试。",
                en: "The authorization response from OpenAI is incomplete. Re-authorize and try again."
            )
        }

        if lower.contains("无法从 oauth 登录结果识别") || lower.contains("unable to identify chatgpt_account_id") {
            return self.localized(
                zh: "无法从这次授权结果识别账号信息，请重新登录授权。",
                en: "AI Coding Proxy could not identify the account from this authorization result. Sign in and authorize again."
            )
        }

        if lower.contains("auth.json 缺少 openai_api_key") || lower.contains("missing openai_api_key") {
            return self.localized(
                zh: "导入文件里缺少可用的 OpenAI API Key。",
                en: "The imported file does not contain a usable OpenAI API key."
            )
        }

        if lower.contains("auth.json 缺少 access_token") || lower.contains("missing access_token") {
            return self.localized(
                zh: "导入文件里缺少访问令牌 `access_token`，无法作为登录态使用。",
                en: "The imported file is missing the `access_token`, so it cannot be used as a signed-in session."
            )
        }

        if lower.contains("auth.json 缺少 refresh_token") || lower.contains("missing refresh_token") {
            return self.localized(
                zh: "导入文件里缺少刷新令牌 `refresh_token`，后续无法自动续期。",
                en: "The imported file is missing the `refresh_token`, so it cannot refresh automatically later."
            )
        }

        if lower.contains("无法从 auth.json 识别 account_id") || lower.contains("unable to identify account_id") {
            return self.localized(
                zh: "导入文件里缺少账号标识 `account_id`，请使用完整授权文件重新导入。",
                en: "The imported file is missing the account identifier `account_id`. Re-import a complete authorization file."
            )
        }

        if lower.contains("请至少选择一个 json 文件") || lower.contains("select at least one json file") {
            return self.localized(
                zh: "请至少选择一个可导入的 JSON 文件。",
                en: "Choose at least one JSON file to import."
            )
        }

        if lower.contains("文件内容为空") || lower.contains("file content is empty") {
            return self.localized(
                zh: "所选文件是空的，请换一个有效文件再试。",
                en: "The selected file is empty. Choose a valid file and try again."
            )
        }

        if lower.contains("导入备份缺少 authjson") || lower.contains("missing authjson") {
            return self.localized(
                zh: "备份文件缺少 `authJSON` 字段，无法导入。",
                en: "The backup file is missing the `authJSON` field and cannot be imported."
            )
        }

        if lower.contains("没有可用于代理的账号") || lower.contains("没有可用账号完成请求") || lower.contains("no available account") {
            return self.localized(
                zh: "当前没有可用账号可供代理请求，请先导入或刷新可用账号。",
                en: "There is no available account to serve this request right now. Import or refresh a usable account first."
            )
        }

        if lower.contains("response.failed")
            || lower.contains("upstream stream returned response.failed")
            || lower.contains("upstream stream terminated before response.completed was received")
            || lower.contains("upstream gemini stream returned an error chunk before a final finishreason was received")
            || lower.contains("upstream gemini stream terminated before a final finishreason was received")
            || lower.contains("premature eof")
            || lower.contains("connection reset by peer")
            || lower == "terminated"
            || lower.contains("上游未返回 response.completed")
            || lower.contains("response.completed")
            || lower.contains("did not finish with `finishreason`")
        {
            return self.localized(
                zh: "上游响应没有正常完成，建议稍后重试。",
                en: "The upstream response did not complete normally. Try again in a moment."
            )
        }

        if lower.contains("coding plan is currently only available for coding agents") {
            return self.localized(
                zh: "阿里百炼拒绝了这次请求，并提示当前仅允许 Coding Agents 使用。请确认该账号已选择“阿里百炼 / Qwen Coding Plan” preset；如果已经选择，本地代理已经按兼容模式改走 `chat/completions`，这通常说明当前 Key 或根地址还没有命中阿里认可的 Coding Plan 接入形态。",
                en: "Aliyun rejected the request because this Coding Plan is only available to Coding Agents. Make sure the account uses the Aliyun / Qwen Coding Plan preset. If it already does, AI Coding Proxy has already retried in compatibility mode via `chat/completions`, which usually means the current key or base URL is still not hitting an accepted Coding Plan entrypoint."
            ) + " " + self.localized(zh: "原始错误：", en: "Original error: ") + trimmed
        }

        if lower.contains("chat/completions 缺少 messages") || lower.contains("missing messages") {
            return self.localized(
                zh: "请求里缺少 `messages` 字段，请检查客户端请求格式。",
                en: "The request is missing the `messages` field. Check the client request format."
            )
        }

        if lower.contains("anthropic messages request is missing `messages`") {
            return self.localized(
                zh: "Anthropic 请求里缺少 `messages` 字段，请至少提供一条用户消息。",
                en: "The Anthropic request is missing the `messages` field. Provide at least one user message."
            )
        }

        if lower.contains("unsupported anthropic content block") || lower.contains("unsupported anthropic system block") {
            return self.localized(
                zh: "当前 Anthropic 兼容层暂不支持这个内容块类型，请改用文本或工具调用块后重试。",
                en: "This Anthropic-compatible layer does not support that content block type yet. Use text or tool blocks and try again."
            )
        }

        if lower.contains("unsupported anthropic `tool_choice`")
            || lower.contains("anthropic `tool_choice` must be")
            || lower.contains("tool_choice is missing `name`")
        {
            return self.localized(
                zh: "当前工具选择参数不受支持，请使用 `auto`、`any` 或指定单个工具名。",
                en: "The current tool_choice value is not supported. Use `auto`, `any`, or a specific tool name."
            )
        }

        if lower.contains("invalid value: 'input_text'")
            && lower.contains("'output_text' and 'refusal'")
        {
            return self.localized(
                zh: "上游拒绝了 assistant 历史消息的内容块类型。本地代理已按角色兼容 assistant 文本为 `output_text`；如果仍出现这个错误，请更新到最新构建后重试。",
                en: "The upstream rejected an assistant history content block type. The local proxy now maps assistant text to `output_text`; if you still see this error, update to the latest build and retry."
            )
        }

        if lower.contains("instructions are required") {
            return self.localized(
                zh: "上游要求请求携带 `instructions` 字段，本地代理已尝试自动补齐；如果仍然失败，请重新发起测试。",
                en: "The upstream requires the `instructions` field. The local proxy now auto-fills it; retry the request if it still fails."
            )
        }

        if lower.contains("unsupported parameter:") {
            let parameter = trimmed
                .components(separatedBy: "Unsupported parameter:")
                .last?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'{}"))
                ?? ""

            if parameter.isEmpty == false {
                return self.localized(
                    zh: "当前官方 OAuth 上游不支持参数 `\(parameter)`，本地代理已加入兼容清洗。请重新发起这次请求。",
                    en: "The official OAuth upstream does not support the `\(parameter)` parameter. The local proxy now strips incompatible fields for this upstream. Retry the request."
                )
            }

            return self.localized(
                zh: "当前官方 OAuth 上游不支持这个请求参数，本地代理已加入兼容清洗。请重新发起这次请求。",
                en: "The official OAuth upstream does not support this request parameter. The local proxy now strips incompatible fields for this upstream. Retry the request."
            )
        }

        if lower.contains("model is not supported when using codex with a chatgpt account") {
            return self.localized(
                zh: "当前 Anthropic 映射目标模型不兼容官方 OAuth 上游，本地代理会自动回退到 `gpt-5.5`。请重试，或在代理页调整模型映射规则。",
                en: "The current Anthropic target model is not compatible with the official OAuth upstream. The local proxy falls back to `gpt-5.5` automatically. Retry the request or adjust the mapping in the Proxy page."
            )
        }

        if lower.hasPrefix("不支持的模型 ") || lower.hasPrefix("unsupported model ") {
            let model = trimmed
                .replacingOccurrences(of: "不支持的模型 ", with: "")
                .replacingOccurrences(of: "Unsupported model ", with: "")
            return self.localized(
                zh: "模型 \(model) 暂未接入本地代理，请改用支持的模型后重试。",
                en: "The model \(model) is not supported by the local proxy yet. Choose a supported model and try again."
            )
        }

        if lower.contains("rate limit") || lower.contains("too many requests") || lower.contains("retry after") || lower.contains("限流") {
            return self.localized(
                zh: "请求触发了上游限流，请稍后重试或切换其它账号。",
                en: "The request hit an upstream rate limit. Retry later or switch to another account."
            )
        }

        if lower.contains("quota") || lower.contains("usage_limit") || lower.contains("payment_required") || lower.contains("额度") || lower.contains("credits") {
            return self.localized(
                zh: "当前账号额度不足或已用尽，请切换账号或等待额度恢复。",
                en: "This account is out of quota or credits. Switch accounts or wait for quota to recover."
            )
        }

        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("cannot connect") || lower.contains("could not connect") || lower.contains("network") || lower.contains("offline") || lower.contains("not connected to internet") {
            return self.localized(
                zh: "网络连接失败，请检查当前网络、代理设置和本地服务状态。",
                en: "The network request failed. Check your network, proxy settings, and local service state."
            )
        }

        if lower.contains("daemon process is running, but the health endpoint did not become ready in time")
            || lower.contains("health endpoint did not become ready in time")
        {
            return self.localized(
                zh: "本地服务进程已经启动，但健康检查接口未在预期时间内就绪，请稍后重试或查看本地日志。",
                en: "The local daemon process is running, but the health endpoint did not become ready in time. Try again shortly or review the local logs."
            )
        }

        if lower.contains("daemon exited before passing its health check") {
            return self.localized(
                zh: "本地服务在通过健康检查前就退出了，请查看本地日志后重试。",
                en: "The local daemon exited before passing its health check. Review the local logs and try again."
            )
        }

        if lower.contains("daemon did not pass health check") || lower.contains("health check") {
            return self.localized(
                zh: "本地守护进程启动后未通过健康检查，请查看本地日志后重试。",
                en: "The local daemon did not pass its health check after starting. Review the local logs and try again."
            )
        }

        if lower.contains("keychain read failed") || lower.contains("keychain add failed") || lower.contains("keychain update failed") {
            return self.localized(
                zh: "无法访问 macOS 钥匙串，请允许 AI Coding Proxy 访问钥匙串后再试。",
                en: "AI Coding Proxy could not access the macOS Keychain. Allow Keychain access and try again."
            )
        }

        if lower.contains("sqlite") || lower.contains("database") {
            return self.localized(
                zh: "本地数据库访问失败，请确认应用数据目录可读写后重试。",
                en: "The local database could not be accessed. Make sure the app data directory is readable and writable, then try again."
            )
        }

        if lower.contains("invalid url:") {
            return self.localized(
                zh: "配置里的地址格式不正确，请检查后再试。",
                en: "A configured URL is invalid. Check the address and try again."
            )
        }

        if let diagnostic = DecodingDiagnostics.parse(trimmed) {
            return self.decodingErrorDetail(for: diagnostic)
        }

        if lower.contains("jwt 格式无效") || lower.contains("jwt payload 无法解析") || lower.contains("jwt") {
            return self.localized(
                zh: "登录令牌格式无效，请重新登录授权。",
                en: "The sign-in token format is invalid. Sign in again to refresh the authorization."
            )
        }

        if lower.contains("unable to combine encrypted payload") {
            return self.localized(
                zh: "本地加密存储初始化失败，请重新启动应用后再试。",
                en: "Initializing local encrypted storage failed. Restart the app and try again."
            )
        }

        if lower.contains("could not find service") || lower.contains("last exit code") {
            return self.localized(
                zh: "本地守护进程当前没有正常运行，请查看服务诊断和日志。",
                en: "The local daemon is not running normally. Review the service diagnostics and logs."
            )
        }

        return trimmed
    }

    private func decodingErrorTitle(for diagnostic: DecodingDiagnostics.Parsed) -> String {
        switch diagnostic.endpoint {
        case "/admin/stats/summary":
            return self.localized(zh: "统计数据读取失败", en: "Stats Data Could Not Be Loaded")
        case "/admin/status":
            return self.localized(zh: "服务状态读取失败", en: "Service Status Could Not Be Loaded")
        case "/admin/settings":
            return self.localized(zh: "配置读取失败", en: "Settings Could Not Be Loaded")
        case "/v1/models":
            return self.localized(zh: "模型列表读取失败", en: "Models Could Not Be Loaded")
        default:
            if diagnostic.endpoint.hasPrefix("/admin/accounts") {
                return self.localized(zh: "账号数据读取失败", en: "Account Data Could Not Be Loaded")
            }
            return self.localized(zh: "接口数据解析失败", en: "Interface Response Could Not Be Decoded")
        }
    }

    private func decodingErrorDetail(for diagnostic: DecodingDiagnostics.Parsed) -> String {
        let lines: [String]

        switch diagnostic.failureKind {
        case .missingKey(let key):
            lines = [
                self.localized(
                    zh: "接口返回的数据字段和当前桌面端预期不一致。",
                    en: "The interface response fields do not match what this desktop build expects."
                ),
                self.localized(zh: "接口", en: "Endpoint") + ": \(diagnostic.method) \(diagnostic.endpoint)",
                self.localizedTypeLine(for: diagnostic),
                self.localized(zh: "字段路径", en: "Field Path") + ": \(diagnostic.codingPath ?? "$")",
                self.localized(zh: "问题", en: "Issue") + ": " + self.localized(
                    zh: "缺少字段 `\(key)`",
                    en: "Missing field `\(key)`"
                ),
            ]
        case .missingValue(let type):
            lines = [
                self.localized(
                    zh: "接口返回了空值，桌面端当前无法完成解析。",
                    en: "The interface returned an empty value that this desktop build cannot decode."
                ),
                self.localized(zh: "接口", en: "Endpoint") + ": \(diagnostic.method) \(diagnostic.endpoint)",
                self.localizedTypeLine(for: diagnostic),
                self.localized(zh: "字段路径", en: "Field Path") + ": \(diagnostic.codingPath ?? "$")",
                self.localized(zh: "问题", en: "Issue") + ": " + self.localized(
                    zh: "缺少 `\(type)` 类型的值",
                    en: "Missing a value of type `\(type)`"
                ),
            ]
        case .typeMismatch(let type):
            lines = [
                self.localized(
                    zh: "接口返回的字段类型和当前桌面端预期不一致。",
                    en: "The interface returned a field type that does not match what this desktop build expects."
                ),
                self.localized(zh: "接口", en: "Endpoint") + ": \(diagnostic.method) \(diagnostic.endpoint)",
                self.localizedTypeLine(for: diagnostic),
                self.localized(zh: "字段路径", en: "Field Path") + ": \(diagnostic.codingPath ?? "$")",
                self.localized(zh: "问题", en: "Issue") + ": " + self.localized(
                    zh: "`\(type)` 类型不匹配",
                    en: "`\(type)` type mismatch"
                ),
            ]
        case .dataCorrupted:
            lines = [
                self.localized(
                    zh: "接口返回内容格式损坏，桌面端无法继续解析。",
                    en: "The interface returned corrupted data and the desktop app could not continue decoding it."
                ),
                self.localized(zh: "接口", en: "Endpoint") + ": \(diagnostic.method) \(diagnostic.endpoint)",
                self.localizedTypeLine(for: diagnostic),
                self.localized(zh: "字段路径", en: "Field Path") + ": \(diagnostic.codingPath ?? "$")",
            ]
        case .other(let message):
            lines = [
                self.localized(
                    zh: "接口返回的数据结构和当前桌面端版本不兼容。",
                    en: "The interface response structure is not compatible with this desktop build."
                ),
                self.localized(zh: "接口", en: "Endpoint") + ": \(diagnostic.method) \(diagnostic.endpoint)",
                self.localizedTypeLine(for: diagnostic),
                self.localized(zh: "详情", en: "Details") + ": \(message)",
            ]
        }

        return lines
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    private func localizedTypeLine(for diagnostic: DecodingDiagnostics.Parsed) -> String {
        guard let targetType = diagnostic.targetType, !targetType.isEmpty else {
            return ""
        }
        return self.localized(zh: "对象", en: "Type") + ": \(targetType)"
    }

    private func localized(zh: String, en: String) -> String {
        self.resolvedLanguage == .zhHans ? zh : en
    }

    private static func cleanMessage(_ rawDetail: String?) -> String? {
        guard let rawDetail else { return nil }
        let cleaned = rawDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func extractPrimaryErrorMessage(from raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.first == "{" || cleaned.first == "[" else {
            return cleaned
        }

        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return cleaned
        }

        if let errorObject = object["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if let message = object["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        return cleaned
    }

    private static let catalog: [ResolvedLanguage: [LocalizedTextKey: String]] = [
        .english: [
            .brandName: "AI Coding Proxy",
            .brandSubtitle: "Professional local coding AI gateway",
            .overviewTitle: "Overview",
            .overviewSubtitle: "Runtime health, traffic trends, and recent activity.",
            .accountsTitle: "Accounts",
            .accountsSubtitle: "Manage your imported upstream accounts and usage balance.",
            .proxyTitle: "Proxy",
            .proxySubtitle: "Connection details, runtime routing, and local access settings.",
            .remoteTitle: "Remote",
            .remoteSubtitle: "Deploy and operate the remote proxy service on Linux hosts.",
            .settingsTitle: "Settings",
            .settingsSubtitle: "Desktop preferences and proxy behavior controls.",
            .menuDaemonRunning: "Daemon Running",
            .menuDaemonStopped: "Daemon Stopped",
            .menuNoEndpoint: "No endpoint available",
            .menuOpenMinimalMode: "Open Minimal Mode",
            .menuOpenFullMode: "Open Full Mode",
            .menuOpenDashboard: "Open Dashboard",
            .menuReload: "Reload",
            .menuQuit: "Quit",
            .menuAboutApp: "About AI Coding Proxy",
            .menuSettings: "Settings…",
            .menuHideApp: "Hide AI Coding Proxy",
            .menuHideOthers: "Hide Others",
            .menuShowAll: "Show All",
            .menuEdit: "Edit",
            .menuView: "View",
            .menuUndo: "Undo",
            .menuRedo: "Redo",
            .menuCut: "Cut",
            .menuPaste: "Paste",
            .menuSelectAll: "Select All",
            .commonReload: "Reload",
            .commonCancel: "Cancel",
            .commonDismiss: "Dismiss",
            .commonCopy: "Copy",
            .commonAll: "All",
            .statusRunning: "Running",
            .statusStopped: "Stopped",
            .statusEnabled: "Enabled",
            .statusDisabled: "Disabled",
            .statusOnline: "Online",
            .statusOffline: "Offline",
            .statusChecking: "Checking",
            .statusDeploying: "Deploying",
            .statusRedeploying: "Redeploying",
            .statusStarting: "Starting…",
            .statusStopping: "Stopping…",
            .statusRunningDegraded: "Degraded",
            .statusInstalledNotRunning: "Installed, Not Running",
            .statusCurrent: "Current",
            .statusUnavailable: "Unavailable",
            .statusUnknown: "Unknown",
            .statusRegistered: "Registered",
            .statusNotRegistered: "Not Registered",
            .statusNotInstalled: "Not Installed",
            .statusUnlimited: "Unlimited",
            .statusNoData: "No data",
            .statusLoadingModels: "Loading Models",
            .statusLoadingLogs: "Loading Logs",
            .statusCoolingDown: "Cooling down",
            .statusOAuthAccount: "OAuth",
            .statusAPIKeyAccount: "API Key",
            .statusReady: "Ready",
            .statusSuccess: "Success",
            .statusTesting: "Testing",
            .statusCompleted: "Completed",
            .statusFailed: "Failed",
            .statusCancelled: "Cancelled",
            .statusNotApplicable: "N/A",
            .labelStatus: "Status",
            .labelTime: "Time",
            .labelTimeRange: "Time Range",
            .labelFrom: "From",
            .labelTo: "To",
            .labelSortBy: "Sort By",
            .labelSortDirection: "Direction",
            .labelAccounts: "Accounts",
            .labelRequests: "Requests",
            .labelFailures: "Failures",
            .labelInputTokens: "Input Tokens",
            .labelOutputTokens: "Output Tokens",
            .labelNaturalTokenUsage: "Natural Range Token Usage",
            .labelTotalTokens: "Total Tokens",
            .labelCacheHitTokens: "Cache Hit",
            .labelRateLimits: "Rate Limits",
            .labelQuotaErrors: "Quota Errors",
            .labelEndpoint: "Endpoint",
            .labelOpenAIBaseURL: "OpenAI Base URL",
            .labelAPIKey: "API Key",
            .labelAllowedAccounts: "Allowed Accounts",
            .labelPrimary: "Primary",
            .labelAnthropicBaseURL: "Anthropic Base URL",
            .labelAnthropicAuthToken: "Anthropic Auth Token",
            .labelClaudeCodeEnv: "Claude Code Env",
            .labelGeminiBaseURL: "Gemini Base URL",
            .labelGeminiCLIEnv: "Gemini CLI Env",
            .labelAnthropicDefaultTargetModel: "Default Target Model",
            .labelAnthropicSourceModel: "Source Model",
            .labelAnthropicTargetModel: "Target Model",
            .labelClientSource: "Client Source",
            .labelAccountLabel: "Account Label",
            .labelModel: "Model",
            .labelRequestedModel: "Requested Model",
            .labelActualModel: "Actual Model",
            .labelReasoningEffort: "Reasoning Effort",
            .labelTestAccount: "Test Account",
            .labelInterface: "Interface",
            .labelUpstreamURL: "Upstream URL",
            .labelUpstreamAdapter: "Upstream Interface",
            .labelThinkingCompatibility: "Thinking Compatibility",
            .labelStream: "Stream",
            .labelToolsJSON: "Tools JSON",
            .labelSystemPrompt: "System Prompt",
            .labelUserPrompt: "User Prompt",
            .labelRequestPreview: "Request Preview",
            .labelRawResponse: "Raw Response",
            .labelStreamTranscript: "Stream Transcript",
            .labelLatency: "Latency",
            .labelHTTPStatus: "HTTP Status",
            .labelResponseText: "Response Text",
            .labelActiveLabel: "Active Label",
            .labelActiveAccount: "Active Account",
            .labelLastError: "Last Error",
            .labelErrorSummary: "Error Summary",
            .labelPublicHost: "Public Host",
            .labelPublicPort: "Public Port",
            .labelAdminPort: "Admin Port",
            .labelAutoStart: "Auto Start",
            .labelLabel: "Label",
            .labelHost: "Host",
            .labelSSHUser: "SSH User",
            .labelSSHPort: "SSH Port",
            .labelAuth: "Auth",
            .labelSSHPassword: "SSH Password",
            .labelIdentityFile: "Identity File",
            .labelPrivateKey: "Private Key",
            .labelRemoteDirectory: "Remote Directory",
            .labelScheme: "Scheme",
            .labelUsername: "Username",
            .labelPassword: "Password",
            .labelCloseAction: "Close Action",
            .labelChatGPTBaseURL: "ChatGPT Base URL",
            .labelDaemonBinaryOverride: "Daemon Binary Override",
            .labelStatsRetentionDays: "Stats Retention Days",
            .labelLanguage: "Language",
            .labelTheme: "Theme",
            .labelDisplay: "Display",
            .labelMenuBarTokenUsage: "Menu Bar Token Usage",
            .labelPlan: "Plan",
            .labelEmail: "Email",
            .labelIssue: "Issue",
            .labelFilteredResults: "Results",
            .labelCredits: "Credits",
            .labelProviderPreset: "Provider Preset",
            .labelAccountBaseURL: "Base URL",
            .labelInstalled: "Installed",
            .labelRunning: "Running",
            .labelLaunchctlState: "launchctl State",
            .labelEnabled: "Enabled",
            .labelArchitecture: "Architecture",
            .labelRemoteUser: "Remote User",
            .labelSystemctl: "systemctl",
            .labelSudo: "sudo",
            .labelLocalArtifacts: "Bundled Linux Package",
            .labelReadiness: "Readiness",
            .labelProxySummary: "Proxy Summary",
            .labelCurrentEffectiveProxyMode: "Current Active Mode",
            .labelPendingProxyMode: "Pending Mode",
            .labelStdoutLog: "Stdout Log",
            .labelStderrLog: "Stderr Log",
            .labelRedirectURI: "Redirect URI",
            .labelLastRefreshed: "Last Refreshed",
            .labelOutboundNode: "Outbound Node",
            .labelModelRouting: "Model Routing",
            .sectionRuntime: "Runtime",
            .sectionTraffic: "Traffic",
            .sectionLatestActivity: "Latest Activity",
            .sectionQuickActions: "Quick Actions",
            .sectionOAuthFlow: "OAuth Web Sign-In",
            .sectionAccountPool: "Account Pool",
            .sectionAccessInfo: "Access Info",
            .sectionAPIKeys: "API Keys",
            .sectionAPIKeyUsage: "API Key Usage",
            .sectionAdvanced: "Advanced",
            .sectionAnthropicAccess: "Anthropic / Claude Code",
            .sectionAnthropicModelMapping: "Anthropic Model Mapping",
            .sectionGeminiAccess: "Google Gemini / Gemini CLI",
            .sectionRuntimeSelection: "Runtime Selection",
            .sectionNetworkSettings: "Network Settings",
            .sectionRemoteHost: "Remote Host",
            .sectionRemoteConnection: "Connection",
            .sectionRemoteAuthentication: "Authentication",
            .sectionRemoteRuntimeConfig: "Runtime Config",
            .sectionRemoteVerification: "Deployment Readiness",
            .sectionRemoteOperations: "Deploy and Operate",
            .sectionRemoteStatus: "Remote Status",
            .sectionLogs: "Logs",
            .sectionAppearance: "Appearance",
            .sectionGeneral: "General",
            .sectionOutboundProxy: "Outbound Proxy",
            .sectionBehavior: "Behavior",
            .sectionService: "Service",
            .sectionSavedHosts: "Saved Hosts",
            .sectionServiceDiagnostics: "Service Diagnostics",
            .sectionRequestLogFilters: "Log Filters",
            .sectionRequestLogs: "Request Logs",
            .sectionTestRequest: "Test Request",
            .sectionTestResult: "Test Result",
            .actionStartDaemon: "Start Daemon",
            .actionStopDaemon: "Stop Daemon",
            .actionDaemonAlreadyRunning: "Running",
            .actionDaemonAlreadyStopped: "Stopped",
            .actionImportCurrentAuth: "Import Current Auth",
            .actionOAuthLogin: "OAuth Login",
            .actionImportCurrent: "Import Current",
            .actionImportLocalAccountsToRemote: "Import Local Accounts to Remote",
            .actionImportJSON: "Import JSON",
            .actionExportBackup: "Export Backup",
            .actionManualAddAccount: "Manual Add",
            .actionRefreshUsage: "Refresh Usage",
            .actionRefreshingUsage: "Refreshing",
            .actionAccountCardRefresh: "Refresh",
            .actionAccountCardRefreshing: "Refreshing",
            .actionAccountCardEdit: "Edit",
            .actionAccountCardNode: "Outbound Node",
            .actionAccountCardMore: "More",
            .actionStopAccountCooldown: "Stop Cooldown",
            .actionSaveAccount: "Save Account",
            .actionRotateAPIKey: "Rotate API Key",
            .actionOpenRequestLogs: "Detailed Logs",
            .actionSaveProxySettings: "Save Proxy Settings",
            .actionConfirmProxyModeChange: "Confirm Proxy Mode",
            .actionSaveManualProxy: "Save Manual Proxy",
            .actionSaveGeneralSettings: "Save Settings",
            .actionSaveHost: "Save Host",
            .actionCreateRemoteHost: "New Host",
            .actionDeleteHost: "Delete Host",
            .actionSaveAndContinue: "Save and Continue",
            .actionTestConnection: "Test Connection",
            .actionRetestConnection: "Retest Connection",
            .actionBack: "Back",
            .actionContinue: "Continue",
            .actionDeploy: "Deploy",
            .actionRedeploy: "Redeploy",
            .actionLoadStatus: "Status",
            .actionStart: "Start",
            .actionStop: "Stop",
            .actionLogs: "Logs",
            .actionCopyEndpoint: "Copy Endpoint",
            .actionCopyUpstreamURL: "Copy Upstream URL",
            .actionCopyAPIKey: "Copy API Key",
            .actionCopyClaudeCodeEnv: "Copy Claude Env",
            .actionCopyGeminiCLIEnv: "Copy Gemini Env",
            .actionAddAPIKey: "Add API Key",
            .actionEditAPIKey: "Edit",
            .actionEditAccountName: "Rename",
            .actionEditOutboundNode: "Outbound Node",
            .actionEditModelRouting: "Model Routing",
            .actionRemoveAPIKey: "Remove",
            .actionSetPrimaryAPIKey: "Set as Primary",
            .actionRegenerateAPIKey: "Regenerate",
            .actionEnableAPIKey: "Enable Key",
            .actionDisableAPIKey: "Disable Key",
            .actionSelectAllCompatibleAccounts: "Select All Compatible",
            .actionClearAccountRestriction: "Clear Restriction",
            .actionSelectTimeRange: "Select Range",
            .actionAddAnthropicMapping: "Add Mapping",
            .actionRemoveAnthropicMapping: "Remove",
            .actionCreateFirstHost: "Create First Host",
            .actionApplyNow: "Applies Immediately",
            .actionLoadLocalLogs: "Load Local Logs",
            .actionEnableAccount: "Enable",
            .actionDisableAccount: "Disable",
            .actionRemoveAuthorization: "Remove Authorization",
            .actionManageAccountOrder: "Adjust Usage Order",
            .actionSaveAccountOrder: "Save Order",
            .actionClearAccountManagedProxyNodes: "Clear Outbound Nodes",
            .actionClearFilters: "Clear Filters",
            .actionTestProxy: "Test Proxy",
            .actionOpenHelp: "Help",
            .actionSendTest: "Send Test",
            .actionCancelTest: "Cancel Test",
            .actionPreviousPage: "Previous Page",
            .actionNextPage: "Next Page",
            .actionCopyErrorSummary: "Copy Error Summary",
            .actionQueryRequestLogs: "Query",
            .actionExportRequestLogs: "Export CSV",
            .actionCopyTime: "Copy Time",
            .actionCopyModel: "Copy Model",
            .actionCopyRequestedModel: "Copy Requested Model",
            .actionCopyActualModel: "Copy Actual Model",
            .actionCopyReasoningEffort: "Copy Reasoning Effort",
            .actionCopyAccountLabel: "Copy Account Label",
            .actionCopyRowCSV: "Copy Row CSV",
            .placeholderNoEndpoint: "No public endpoint yet",
            .placeholderNoAccounts: "No accounts imported yet.",
            .placeholderSearchAccounts: "Search label, email, or account ID",
            .placeholderNoMatchingAccounts: "No accounts match the current filters.",
            .placeholderManualAccountLabel: "Optional label",
            .placeholderManualAccountBaseURL: "https://api.openai.com/v1 or https://host/custom-prefix",
            .placeholderAliyunCodingPlanBaseURL: "https://coding.dashscope.aliyuncs.com or https://host/v1",
            .placeholderAnthropicAPICompatibleBaseURL: "https://api.anthropic.com or https://host/v1",
            .placeholderGoogleGeminiCompatibleBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            .placeholderManualAccountAPIKey: "sk-...",
            .placeholderNoRecentRequests: "No request metrics recorded yet.",
            .placeholderNoRemoteStatus: "No remote status loaded yet.",
            .placeholderNoLogs: "No logs loaded yet.",
            .placeholderNoRemoteLogsForHost: "No logs have been loaded for this host yet.",
            .placeholderNoLocalLogs: "No local daemon logs available.",
            .placeholderProxyTestPrompt: "Describe what you want the model to do through the local proxy.",
            .placeholderProxyTestSystem: "Optional system instructions for the test request.",
            .placeholderProxyTestTools: "Optional tools JSON array. Anthropic example: [{\"name\":\"run_command\",\"description\":\"Execute a command\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}]. Gemini example: [{\"functionDeclarations\":[{\"name\":\"run_command\",\"description\":\"Execute a command\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}}]}]",
            .placeholderProxyTestResult: "Run a local proxy test to inspect the model output, HTTP status, usage, and raw response details.",
            .placeholderNoRequestLogs: "No request logs in the current range.",
            .placeholderNoProxyAPIKeys: "No local proxy API keys yet.",
            .placeholderNoProxyAPIKeyUsage: "No API key usage recorded in the selected range.",
            .placeholderProxyAPIKeyNoCompatibleAccounts: "No enabled accounts are compatible with the current data source.",
            .helperAppearanceAppliesImmediately: "Language and theme changes apply immediately and stay local to this desktop app.",
            .helperThemeFollowsSystem: "Follow System uses the current macOS appearance.",
            .helperLanguageFollowsSystem: "Follow System uses your current macOS language preference.",
            .helperThemeOptionSystem: "Match the current macOS appearance.",
            .helperThemeOptionLight: "Use a brighter appearance across the desktop app.",
            .helperThemeOptionDark: "Use a darker appearance across the desktop app.",
            .helperLanguageOptionSystem: "Use the current macOS language preference.",
            .helperLanguageOptionChinese: "Show the desktop app in simplified Chinese.",
            .helperLanguageOptionEnglish: "Show the desktop app in English.",
            .helperMenuBarTokenUsage: "Show today's input and output token counts next to the menu bar icon.",
            .helperQuickActionOAuth: "Open the browser sign-in flow and import the account after authorization.",
            .helperQuickActionImportCurrent: "Read the current local auth and add it to the account pool.",
            .helperQuickActionImportLocalAccountsToRemote: "Sync the current desktop app's local account pool to this remote host and refresh matching remote authorizations.",
            .helperQuickActionImportJSON: "Batch import accounts from a backup JSON file.",
            .helperQuickActionManualAdd: "Save a compatible upstream base URL and API key as a separate account.",
            .helperQuickActionExportBackup: "Export all saved accounts into a backup file.",
            .helperQuickActionTestProxy: "Open the test console to verify the current proxy path without leaving the app.",
            .helperQuickActionRefreshUsage: "Refresh quota and usage state for every imported account.",
            .helperSelectionPolicy: "Drag to define the routing order. Requests try enabled accounts from top to bottom and skip quota-blocked or cooling API key accounts.",
            .helperManualAPIKeyAccount: "Add a compatible API key account with its own upstream base URL and API key. OAuth accounts still use browser authorization.",
            .helperManualAccountGenericOpenAICompatible: "Use the standard OpenAI-compatible flow. Enter the final upstream API prefix exactly as your provider expects, including `/v1` when needed, and Codex Proxy will use it as-is. Choose Responses for providers that support the OpenAI Responses API, or Chat Completions for providers that only expose `/chat/completions`. If you're using Google's official Gemini compatibility root, switch Provider to `Google Gemini Compatible` instead.",
            .helperManualAccountUpstreamAdapter: "Responses is the default. Choose Chat Completions when the upstream provider does not support `/responses`.",
            .helperManualAccountThinkingCompatibility: "Default off. Enable only for providers that require `thinking` and `reasoning_content` to be preserved across tool-call turns; providers that do not support this field should keep it disabled.",
            .helperManualAccountAliyunCodingPlan: "Use Aliyun Bailian / Qwen Coding Plan compatibility mode. Validation and runtime requests switch to an agent-style `chat/completions` path so existing local proxy clients can keep working without changing their own request format.",
            .helperManualAccountAnthropicAPICompatible: "Use Anthropic's native API key flow. Validation first checks `/v1/models`; if the upstream returns `404/405` for that list endpoint, it falls back to a minimal real `你好` probe over `/v1/messages`. Runtime requests use the official `/v1/messages` and `/v1/messages/count_tokens` paths with `x-api-key` authentication.",
            .helperManualAccountGoogleGeminiCompatible: "Use Google's official Gemini OpenAI compatibility root with a Gemini API key from Google AI Studio. This preset is for API-key compatibility traffic, not for the official Gemini CLI route. Validation first checks `/models`; if the upstream returns `404/405` for that list endpoint, it falls back to a minimal real `你好` probe over `chat/completions`. Runtime requests use `chat/completions` compatibility mode.",
            .helperAPIKeyAccountNoStandardUsage: "Connection validated. This account type does not provide standard usage data.",
            .helperAccountLabelRequired: "Enter an account name before saving.",
            .helperManualAccountAPIKeyRequired: "Enter an API key before saving.",
            .helperManualAccountBaseURLInvalid: "Enter a valid root base URL such as https://api.openai.com or https://host/v1.",
            .errorManualAccountGoogleGeminiPresetRequired: "Detected Google's official Gemini OpenAI-compatible root. Switch Provider to `Google Gemini Compatible` instead of `Generic OpenAI Compatible`.",
            .errorManualAccountGoogleGeminiAPIKeyOnly: "Google Gemini Compatible currently supports Gemini API keys only. Google / Gemini sign-in cannot be imported into this compatibility preset. Use a Gemini API key from Google AI Studio instead, or go to Accounts and use `Google / Gemini Login` for the native Google account flow.",
            .helperServiceDiagnostics: "Review LaunchAgent registration, runtime state, local log paths, and the latest startup failure here.",
            .helperAnthropicConnection: "Point Claude Code to the root address. The same Anthropic-routed local API key can also be used by Codex or another OpenAI-compatible client against the OpenAI-compatible base URL when you want requests to stay on the Anthropic account pool.",
            .helperGeminiConnection: "Point Gemini CLI to the proxy root through `GOOGLE_GEMINI_BASE_URL`, and reuse the same local API key through `GEMINI_API_KEY`. Gemini CLI requests now execute only through accounts imported from `Google / Gemini Login`. `Google Gemini Compatible` remains available for API-key compatibility routes, but it is no longer used as the Gemini CLI backend path.",
            .helperOutboundProxyGlobalModeDisabled: "If your local proxy app is already running in global mode, keep Proxy Mode set to `Disabled` here to avoid adding an extra proxy hop.",
            .helperSaveManualProxyDoesNotSwitchMode: "This only saves the manual proxy endpoint. It does not switch the active proxy mode.",
            .helperConfirmProxyModeChangeNeedsManualSave: "Save the manual proxy settings before confirming the mode switch.",
            .helperConfirmProxyModeChangeNeedsSubscription: "Configure subscription proxying in Manage Subscription before confirming the mode switch.",
            .helperProxyAPIKeys: "Create separate local API keys for different users or tools. The primary key is used by the built-in copy actions, environment snippets, and test console.",
            .helperProxyAPIKeyUsage: "Review per-key request volume and token usage across natural day, week, month, or a custom time range.",
            .helperNaturalTokenUsage: "Calculated from local request logs using your local day, Monday-start week, and calendar month ranges.",
            .helperProxyAPIKeyValueRequired: "Enter a non-empty API key value before saving.",
            .helperProxyAPIKeyAtLeastOne: "Keep at least one local proxy API key configured.",
            .helperProxyAPIKeyAtLeastOneEnabled: "Keep at least one API key enabled so clients can still access the proxy.",
            .helperProxyAPIKeyAllowedAccounts: "Leave the selection empty to keep this key unrestricted. When accounts are selected, the key can only route to enabled accounts compatible with the current data source.",
            .helperProxyAPIKeyStaleSelections: "Saved account restrictions below are no longer selectable. They stay attached to this key until you remove them, so saving will not silently widen access.",
            .helperAnthropicModelMapping: "Control how Anthropic / Claude model names map to upstream target models. Unmatched models use the default target model.",
            .helperAnthropicMappingFallback: "Any Anthropic model without an explicit rule falls back to the default target model.",
            .helperAnthropicOAuthModelFallback: "If a mapped target is not accepted by the official OAuth upstream, the proxy automatically falls back to `gpt-5.5`.",
            .helperServiceChecking: "Checking the local daemon status. Service actions will unlock when the current state is confirmed.",
            .helperServiceCanStart: "The local daemon is stopped. You can start it directly.",
            .helperServiceCanStop: "The local daemon is running. Stop it before applying a full restart or maintenance change.",
            .helperServiceDegraded: "The daemon process exists, but the admin interface health check failed. Review diagnostics or logs before restarting.",
            .helperServiceNotInstalled: "LaunchAgent is not installed yet. It will be installed automatically when you start the service.",
            .helperServiceStarting: "The local daemon is starting. Please wait for the health check to complete.",
            .helperServiceStopping: "The local daemon is stopping. Please wait for shutdown to finish.",
            .warningLaunchConfigurationSavedRestartRequired: "Settings were saved, but the current local service was kept running. Stop and start the service manually for launch configuration changes to fully apply.",
            .helperRemoteStatusRequired: "Load the remote status before starting or stopping the remote proxy service.",
            .helperRemoteCanStart: "The remote proxy service is stopped. You can start it directly.",
            .helperRemoteCanStop: "The remote proxy service is running. You can stop it directly.",
            .helperRemoteUnreachable: "The remote host status could not be confirmed. Reload the remote status before performing service actions.",
            .helperRemoteStarting: "The remote proxy service is starting. Wait for the operation to finish.",
            .helperRemoteStopping: "The remote proxy service is stopping. Wait for the operation to finish.",
            .helperRemoteNeedsSavedHost: "Save the current host before moving on to verification.",
            .helperRemoteNeedsVerification: "Run the connection test before remote deploy and service controls unlock.",
            .helperRemoteSystemctlUnavailable: "The remote host does not expose `systemctl`, so the current systemd deploy flow cannot continue.",
            .helperRemoteSudoUnavailable: "The current remote user cannot complete `sudo -v`. Use root or passwordless sudo for deployment.",
            .helperRemoteDirectoryUnavailable: "The configured remote directory is not writable, and its parent directory is not writable either.",
            .helperRemoteDeployUnavailable: "This build cannot deploy to the selected host because it does not include a matching bundled Linux deployment package. You can still load status, inspect logs, start or stop an already deployed service, and open Remote Admin for a running host.",
            .helperRemoteRedeploy: "Push the bundled Linux package and service configuration again to refresh the remote proxy service, binaries, and systemd setup when the installed server is outdated.",
            .helperRemoteOperationsLocked: "Remote operations unlock only after the latest connection test passes. Deploy also requires bundled Linux deployment packages in this build.",
            .oauthFlowDescription: "Authorize in the browser, then auto-import the account or paste the callback URL manually.",
            .oauthLinkLabel: "Authorization Link",
            .oauthCallbackLabel: "Callback URL",
            .oauthCallbackPlaceholder: "Paste the full browser callback URL if automatic import does not finish.",
            .oauthListening: "Listening",
            .oauthOpenBrowser: "Open Browser",
            .oauthParseCallback: "Parse Callback",
            .oauthManualHint: "AI Coding Proxy is already listening on the local callback address. If the browser cannot return automatically, paste the final callback URL here.",
            .oauthAutoImportHint: "Browser callback will be imported automatically when localhost redirection succeeds.",
            .oauthCallbackHint: "Keep the full callback URL, including both the code and state query parameters.",
            .oauthBrowserOpenFailed: "Browser did not open automatically",
            .oauthInvalidLink: "Authorization link is invalid",
            .oauthCallbackMissing: "Callback URL is required",
            .confirmStopDaemonTitle: "Stop the local service?",
            .confirmStopDaemonMessage: "The local LaunchAgent daemon will stop right away. Proxy requests that rely on this local service may fail until you start it again.",
            .confirmStopDaemonAutoStartWarning: "Auto-start is enabled. After the service stops, using Reload or reopening the app may start it again.",
            .confirmStopDaemonAction: "Stop Service",
            .confirmClearAccountManagedProxyNodesTitle: "Clear custom outbound nodes for all accounts?",
            .confirmClearAccountManagedProxyNodesMessage: "This removes every account-level outbound node override, including accounts hidden by the current search or filters. After clearing, all accounts follow the outbound mode from Settings again.",
            .confirmClearAccountManagedProxyNodesAction: "Clear All Overrides",
            .confirmStopAccountCooldownTitle: "Stop this account's cooldown?",
            .confirmStopAccountCooldownAction: "Stop Cooldown",
            .confirmRemoveAuthorizationTitle: "Remove this local authorization?",
            .confirmRemoveAuthorizationMessage: "This only removes the saved authorization from AI Coding Proxy's local account pool. It does not clear your current `~/.codex/auth.json` login state.",
            .confirmImportLocalAccountsToRemoteTitle: "Import local desktop accounts to this remote host?",
            .confirmImportLocalAccountsToRemoteAction: "Import to Remote",
            .confirmDeleteRemoteHostTitle: "Delete this saved remote host?",
            .confirmDeleteRemoteHostAction: "Delete Host",
            .helperNoMatchingAccounts: "Adjust the filters or clear the search to show all imported accounts.",
            .optionFollowSystem: "Follow System",
            .optionLight: "Light",
            .optionDark: "Dark",
            .optionChineseSimplified: "Simplified Chinese",
            .optionEnglish: "English",
            .optionCards: "Cards",
            .optionList: "List",
            .optionDisabled: "Disabled",
            .optionHTTP: "HTTP",
            .optionHTTPS: "HTTPS",
            .optionSOCKS5: "SOCKS5",
            .optionHideToMenuBar: "Hide to Menu Bar",
            .optionQuit: "Quit",
            .optionSSHKeyPath: "SSH Key Path",
            .optionSSHKeyContent: "SSH Key Content",
            .optionPassword: "Password",
            .optionHealthy: "Healthy",
            .optionAnyIssue: "Any Issue",
            .optionRefreshBlocked: "Refresh Blocked",
            .optionUsageIssue: "Usage Issue",
            .optionCustom: "Custom",
            .optionToday: "Today",
            .optionThisWeek: "This Week",
            .optionThisMonth: "This Month",
            .optionLastWeek: "Last Week",
            .optionTwoWeeksAgo: "2 Weeks Ago",
            .optionThreeWeeksAgo: "3 Weeks Ago",
            .optionOther: "Other",
            .optionLast15Minutes: "Last 15 Minutes",
            .optionLast1Hour: "Last 1 Hour",
            .optionLast24Hours: "Last 24 Hours",
            .optionLast7Days: "Last 7 Days",
            .optionAscending: "Ascending",
            .optionDescending: "Descending",
            .optionChatCompletions: "Chat",
            .optionResponses: "Responses",
            .optionUpstreamAdapterChatCompletions: "Chat Completions",
            .optionUpstreamAdapterResponses: "Responses",
            .optionThinkingCompatibilityDisabled: "Disabled",
            .optionThinkingCompatibilityEnabled: "Enabled",
            .optionAnthropicMessages: "Anthropic",
            .optionGeminiGenerateContent: "Gemini",
            .optionAutoSelectByOrder: "Auto Select (By Order)",
            .providerPresetGenericOpenAICompatible: "Generic OpenAI Compatible",
            .providerPresetAliyunQwenCodingPlan: "Aliyun / Qwen Coding Plan",
            .providerPresetAnthropicAPICompatible: "Anthropic API Compatible",
            .providerPresetGoogleGeminiCompatible: "Google Gemini Compatible",
            .remoteWorkflowHostsTitle: "Host Management",
            .remoteWorkflowHostsSubtitle: "Choose a saved host, create a new draft, or remove stale entries before deploying.",
            .remoteWorkflowConfigurationTitle: "Connection Configuration",
            .remoteWorkflowConfigurationSubtitle: "Edit the SSH identity and runtime ports for the currently selected host.",
            .remoteWorkflowVerificationTitle: "Deployment Readiness",
            .remoteWorkflowVerificationSubtitle: "Verify SSH, sudo, systemd, writable target paths, and the bundled Linux deployment package inside the app before deploying.",
            .remoteWorkflowOperationsTitle: "Deploy and Operate",
            .remoteWorkflowOperationsSubtitle: "Deploy or redeploy the bundled Linux package when available, refresh runtime status, and inspect logs for the selected host.",
            .remoteSavedHostsEmpty: "No saved hosts yet. Configure one on the left to begin remote deployment.",
            .remoteLogsHint: "Live operational logs help verify service health after deploy, start, and stop actions.",
            .proxyConnectionHint: "Use these connection details from your local OpenAI-compatible client.",
            .labelRecentFourWeeks: "Recent 4 Weeks",
            .labelDailyTrend: "Daily Trend",
            .labelWeeklyTrend: "Weekly Trend",
            .overviewServiceHint: "A concise health view for your local proxy runtime and recent request distribution.",
            .overviewTrafficHint: "Review local request totals at a glance, compare Today, This Week, and This Month, then inspect the latest four weeks through daily and weekly token trends.",
            .overviewDiagnosticsHint: "Detailed service diagnostics and local log paths remain under Settings > Service.",
            .requestLogsTitle: "Request Detail Logs",
            .requestLogsSubtitle: "Inspect request-level token usage, latency, cache hits, and account routing without storing prompt or response bodies.",
            .requestLogsFilterHint: "Adjust the time range, client source, local API key, account label, and model here. Click Query to apply filters; sorting applies immediately, and Reload fetches the current result set again.",
            .requestLogsPendingFiltersHint: "Filters changed. Click Query to apply them.",
            .requestLogsPendingFiltersCompactHint: "Query to apply filters",
            .requestLogsTableHint: "Only request metadata is stored locally. API keys stay encrypted at rest, table previews are masked, and full values remain copyable for debugging.",
            .requestLogsEmptyHint: "Try expanding the time range or clearing client source, API key, account label, and model filters to see more history.",
            .proxyTestTitle: "Test Console",
            .proxyTestSubtitle: "Call the current local `/v1` proxy with the active API key and inspect the result in a focused debugging console.",
            .proxyTestHealthHint: "The console first verifies local daemon health and then loads the desktop model catalog. Sending stays disabled when the local proxy is unavailable.",
            .proxyTestRequestHint: "Use structured fields to compose the request while keeping a read-only JSON preview for verification.",
            .proxyTestResultHint: "Review the assistant output, usage, latency, HTTP status, and raw response details from the same local proxy path your client uses.",
            .proxyTestFallbackModels: "The desktop model catalog could not be loaded. Falling back to the built-in endpoint model families.",
            .proxyTestMissingOpenAIDataSourceAPIKey: "There is no enabled local API key for the OpenAI data source, so this account cannot be pinned for testing.",
            .proxyTestMissingAnthropicDataSourceAPIKey: "There is no enabled local API key for the Anthropic data source, so this account cannot be pinned for testing.",
            .proxyTestMissingGeminiDataSourceAPIKey: "There is no enabled local API key for the Gemini data source, so this account cannot be pinned for testing.",
            .proxyTestMissingAnthropicOAuthCompatibleAPIKey: "There is no enabled local API key compatible with Anthropic authorized accounts, so this account cannot be pinned for testing.",
            .proxyTestSelectedAccountOutsideAPIKeyAllowlist: "Enabled local API keys exist for this protocol, but the selected account is outside their allowed account range, so it cannot be pinned for testing.",
            .helpWindowTitle: "Usage Guide",
            .onboardingWindowTitle: "Getting Started",
            .helpWindowSubtitle: "Learn the first-run setup, every page in the app, and the supporting tool windows from one dedicated reference.",
            .aboutWindowSubtitle: "A polished local desktop workbench for managing coding AI accounts, client access, and remote deployment in one place.",
            .aboutOverviewTitle: "What This App Does",
            .aboutOverviewBody: "AI Coding Proxy turns your Mac into a structured local coding AI gateway. It helps you unify imported upstream accounts, expose stable client endpoints, inspect runtime status, and manage local and remote proxy services from one desktop console.",
            .aboutCapabilityAccounts: "Manage imported upstream accounts and keep quota, health, and routing readiness visible.",
            .aboutCapabilityAccess: "Expose stable local client access details for OpenAI-compatible, Anthropic, and Gemini toolchains.",
            .aboutCapabilityRemote: "Deploy and operate the remote proxy service on Linux hosts when you need a managed runtime outside your Mac.",
            .aboutDeveloperTitle: "Developer",
            .aboutDeveloperBody: "Built and maintained by the developer below. Use the contact email for collaboration or feedback.",
            .errorOperationFailed: "Operation failed",
            .errorNetworkIssue: "Network request failed",
            .errorAuthorizationFailed: "Authorization failed",
            .errorImportFailed: "Import failed",
            .errorUsageRefreshFailed: "Usage refresh failed",
            .errorRemoteConnectionFailed: "Remote connection failed",
            .errorRemoteDeployFailed: "Remote deployment failed",
            .errorDaemonControlFailed: "Daemon control failed",
            .errorConfigurationFailed: "Configuration update failed",
            .errorAccountManagementFailed: "Account update failed",
            .errorCopyFailed: "Copy failed",
            .errorRequestLogsFailed: "Request logs failed to load",
            .errorRequestLogsExportFailed: "Request log export failed",
            .errorProxyTestFailed: "Proxy test failed",
            .errorProxyAPIKeyFailed: "API key update failed",
            .errorProxyAPIKeyUsageFailed: "API key usage failed to load",
            .successDaemonStarted: "Daemon started",
            .successDaemonStopped: "Daemon stopped",
            .successAuthImported: "Current auth imported",
            .successLocalAccountsImportedToRemote: "Local accounts imported to remote",
            .successJSONImported: "JSON accounts imported",
            .successBackupExported: "Backup exported",
            .successManualAPIKeyAccountAdded: "API key account added",
            .successManualAPIKeyAccountUpdated: "API key account updated",
            .successAccountLabelUpdated: "Account name updated",
            .successAccountManagedProxyNodeUpdated: "Account outbound node updated",
            .successAccountManagedProxyNodesCleared: "Account outbound nodes cleared",
            .successAccountModelRoutingUpdated: "Account model routing updated",
            .successAccountCooldownStopped: "Account cooldown stopped",
            .successUsageRefreshed: "Usage refreshed",
            .successAccountUsageRefreshed: "Account usage refreshed",
            .successProxyKeyRotated: "API key rotated",
            .successSettingsSaved: "Settings saved",
            .successPreferencesSaved: "Appearance preferences saved",
            .successOAuthStarted: "OAuth flow opened in browser",
            .successOAuthCompleted: "OAuth account imported",
            .successRemoteConnectionTested: "Remote connection verified",
            .successRemoteDeployed: "Remote proxy service deployed",
            .successRemoteHostDeleted: "Remote host removed",
            .successRemoteStarted: "Remote proxy service started",
            .successRemoteStopped: "Remote proxy service stopped",
            .successRemoteStatusLoaded: "Remote status loaded",
            .successRemoteLogsLoaded: "Remote logs loaded",
            .successCopiedEndpoint: "Endpoint copied",
            .successCopiedUpstreamURL: "Upstream URL copied",
            .successCopiedAPIKey: "API key copied",
            .successCopiedClaudeCodeEnv: "Claude Code environment copied",
            .successCopiedGeminiCLIEnv: "Gemini CLI environment copied",
            .successCopiedOAuthLink: "Authorization link copied",
            .successCopiedManagedProxyTerminalCommand: "Terminal proxy command copied",
            .successCopiedErrorSummary: "Error summary copied",
            .successCopiedTime: "Time copied",
            .successCopiedModel: "Model copied",
            .successCopiedRequestedModel: "Requested model copied",
            .successCopiedActualModel: "Actual model copied",
            .successCopiedReasoningEffort: "Reasoning effort copied",
            .successCopiedAccountLabel: "Account label copied",
            .successCopiedRowCSV: "CSV row copied",
            .successRequestLogsExported: "Request logs exported",
            .successHostSaved: "Remote host saved",
            .successAccountEnabled: "Account enabled",
            .successAccountDisabled: "Account disabled",
            .successAuthorizationRemoved: "Authorization removed",
            .successAccountOrderUpdated: "Account order updated",
            .successProxyTestCompleted: "Proxy test completed",
            .successProxyModelsLoaded: "Proxy model list loaded",
            .successProxyAPIKeyAdded: "API key added",
            .successProxyAPIKeyUpdated: "API key updated",
            .successProxyAPIKeyRemoved: "API key removed",
            .successProxyAPIKeyRegenerated: "API key regenerated",
            .successProxyAPIKeyPrimaryChanged: "Primary API key changed",
        ],
        .zhHans: [
            .brandName: "AI Coding Proxy",
            .brandSubtitle: "专业的本地编程 AI 代理工作台",
            .overviewTitle: "总览",
            .overviewSubtitle: "查看运行健康、流量趋势和最近活动。",
            .accountsTitle: "账号",
            .accountsSubtitle: "管理已导入的上游账号与额度状态。",
            .proxyTitle: "代理",
            .proxySubtitle: "查看接入信息、运行路由和本地访问设置。",
            .remoteTitle: "远程",
            .remoteSubtitle: "将远程代理服务部署到 Linux 主机并运维。",
            .settingsTitle: "设置",
            .settingsSubtitle: "调整桌面偏好与代理行为。",
            .menuDaemonRunning: "服务运行中",
            .menuDaemonStopped: "服务未运行",
            .menuNoEndpoint: "暂无可用地址",
            .menuOpenMinimalMode: "打开极简模式",
            .menuOpenFullMode: "打开全功能模式",
            .menuOpenDashboard: "打开控制台",
            .menuReload: "刷新",
            .menuQuit: "退出",
            .menuAboutApp: "关于 AI Coding Proxy",
            .menuSettings: "设置…",
            .menuHideApp: "隐藏 AI Coding Proxy",
            .menuHideOthers: "隐藏其他",
            .menuShowAll: "全部显示",
            .menuEdit: "编辑",
            .menuView: "显示",
            .menuUndo: "撤销",
            .menuRedo: "重做",
            .menuCut: "剪切",
            .menuPaste: "粘贴",
            .menuSelectAll: "全选",
            .commonReload: "刷新",
            .commonCancel: "取消",
            .commonDismiss: "关闭",
            .commonCopy: "复制",
            .commonAll: "全部",
            .statusRunning: "运行中",
            .statusStopped: "已停止",
            .statusEnabled: "已启用",
            .statusDisabled: "已停用",
            .statusOnline: "在线",
            .statusOffline: "离线",
            .statusChecking: "检查中",
            .statusDeploying: "部署中",
            .statusRedeploying: "重新部署中",
            .statusStarting: "启动中…",
            .statusStopping: "停止中…",
            .statusRunningDegraded: "运行异常",
            .statusInstalledNotRunning: "已安装，未运行",
            .statusCurrent: "当前",
            .statusUnavailable: "不可用",
            .statusUnknown: "未知",
            .statusRegistered: "已注册",
            .statusNotRegistered: "未注册",
            .statusNotInstalled: "未安装",
            .statusUnlimited: "不限量",
            .statusNoData: "暂无数据",
            .statusLoadingModels: "加载模型中",
            .statusLoadingLogs: "加载日志中",
            .statusCoolingDown: "冷却中",
            .statusOAuthAccount: "OAuth",
            .statusAPIKeyAccount: "API Key",
            .statusReady: "就绪",
            .statusSuccess: "成功",
            .statusTesting: "测试中",
            .statusCompleted: "已完成",
            .statusFailed: "失败",
            .statusCancelled: "已取消",
            .statusNotApplicable: "N/A",
            .labelStatus: "状态",
            .labelTime: "时间",
            .labelTimeRange: "时间范围",
            .labelFrom: "开始时间",
            .labelTo: "结束时间",
            .labelSortBy: "排序字段",
            .labelSortDirection: "排序方向",
            .labelAccounts: "账号数",
            .labelRequests: "请求数",
            .labelFailures: "失败数",
            .labelInputTokens: "输入 Tokens",
            .labelOutputTokens: "输出 Tokens",
            .labelNaturalTokenUsage: "自然时间范围 Token 用量",
            .labelTotalTokens: "总 Tokens",
            .labelCacheHitTokens: "缓存命中",
            .labelRateLimits: "限流次数",
            .labelQuotaErrors: "额度错误",
            .labelEndpoint: "接入地址",
            .labelOpenAIBaseURL: "OpenAI 兼容根地址",
            .labelAPIKey: "API Key",
            .labelAllowedAccounts: "允许账号",
            .labelPrimary: "默认",
            .labelAnthropicBaseURL: "Anthropic 根地址",
            .labelAnthropicAuthToken: "Anthropic 鉴权令牌",
            .labelClaudeCodeEnv: "Claude Code 环境变量",
            .labelGeminiBaseURL: "Gemini 根地址",
            .labelGeminiCLIEnv: "Gemini CLI 环境变量",
            .labelAnthropicDefaultTargetModel: "默认目标模型",
            .labelAnthropicSourceModel: "源模型",
            .labelAnthropicTargetModel: "目标模型",
            .labelClientSource: "客户端来源",
            .labelAccountLabel: "账号标签",
            .labelModel: "模型",
            .labelRequestedModel: "请求模型",
            .labelActualModel: "真实访问模型",
            .labelReasoningEffort: "思维等级",
            .labelTestAccount: "测试账号",
            .labelInterface: "接口",
            .labelUpstreamURL: "上游地址",
            .labelUpstreamAdapter: "上游接入方式",
            .labelThinkingCompatibility: "Thinking 兼容",
            .labelStream: "流式",
            .labelToolsJSON: "Tools JSON",
            .labelSystemPrompt: "System Prompt",
            .labelUserPrompt: "用户提示词",
            .labelRequestPreview: "请求预览",
            .labelRawResponse: "原始响应",
            .labelStreamTranscript: "流式日志",
            .labelLatency: "耗时",
            .labelHTTPStatus: "HTTP 状态",
            .labelResponseText: "响应文本",
            .labelActiveLabel: "活跃标签",
            .labelActiveAccount: "活跃账号",
            .labelLastError: "最近错误",
            .labelErrorSummary: "错误摘要",
            .labelPublicHost: "公开 Host",
            .labelPublicPort: "公开端口",
            .labelAdminPort: "管理端口",
            .labelAutoStart: "自动启动",
            .labelLabel: "名称",
            .labelHost: "主机",
            .labelSSHUser: "SSH 用户",
            .labelSSHPort: "SSH 端口",
            .labelAuth: "认证方式",
            .labelSSHPassword: "SSH 密码",
            .labelIdentityFile: "密钥文件",
            .labelPrivateKey: "私钥内容",
            .labelRemoteDirectory: "远程目录",
            .labelScheme: "协议",
            .labelUsername: "用户名",
            .labelPassword: "密码",
            .labelCloseAction: "关闭行为",
            .labelChatGPTBaseURL: "ChatGPT Base URL",
            .labelDaemonBinaryOverride: "守护进程路径覆盖",
            .labelStatsRetentionDays: "统计保留天数",
            .labelLanguage: "语言",
            .labelTheme: "主题",
            .labelDisplay: "显示",
            .labelMenuBarTokenUsage: "菜单栏 Token 用量",
            .labelPlan: "套餐",
            .labelEmail: "邮箱",
            .labelIssue: "异常",
            .labelFilteredResults: "结果",
            .labelCredits: "Credits",
            .labelProviderPreset: "厂商预设",
            .labelAccountBaseURL: "根地址",
            .labelInstalled: "已安装",
            .labelRunning: "运行状态",
            .labelLaunchctlState: "launchctl 状态",
            .labelEnabled: "已启用",
            .labelArchitecture: "架构",
            .labelRemoteUser: "远程用户",
            .labelSystemctl: "systemctl",
            .labelSudo: "sudo",
            .labelLocalArtifacts: "应用内置部署包",
            .labelReadiness: "就绪情况",
            .labelProxySummary: "代理摘要",
            .labelCurrentEffectiveProxyMode: "当前已生效模式",
            .labelPendingProxyMode: "待切换模式",
            .labelStdoutLog: "标准输出日志",
            .labelStderrLog: "错误日志",
            .labelRedirectURI: "回调地址",
            .labelLastRefreshed: "最近刷新",
            .labelOutboundNode: "出站节点",
            .labelModelRouting: "模型转换",
            .sectionRuntime: "运行概览",
            .sectionTraffic: "流量统计",
            .sectionLatestActivity: "最近活动",
            .sectionQuickActions: "快捷操作",
            .sectionOAuthFlow: "OAuth 网页授权",
            .sectionAccountPool: "账号池",
            .sectionAccessInfo: "接入信息",
            .sectionAPIKeys: "API Keys",
            .sectionAPIKeyUsage: "Key 用量",
            .sectionAdvanced: "高级设置",
            .sectionAnthropicAccess: "Anthropic / Claude Code",
            .sectionAnthropicModelMapping: "Anthropic 模型映射",
            .sectionGeminiAccess: "Google Gemini / Gemini CLI",
            .sectionRuntimeSelection: "运行选择",
            .sectionNetworkSettings: "网络设置",
            .sectionRemoteHost: "远程主机",
            .sectionRemoteConnection: "连接信息",
            .sectionRemoteAuthentication: "认证方式",
            .sectionRemoteRuntimeConfig: "运行参数",
            .sectionRemoteVerification: "部署前验证",
            .sectionRemoteOperations: "部署与运维",
            .sectionRemoteStatus: "远程状态",
            .sectionLogs: "日志",
            .sectionAppearance: "外观",
            .sectionGeneral: "通用",
            .sectionOutboundProxy: "出站代理",
            .sectionBehavior: "行为",
            .sectionService: "服务",
            .sectionSavedHosts: "已保存主机",
            .sectionServiceDiagnostics: "服务诊断",
            .sectionRequestLogFilters: "日志筛选",
            .sectionRequestLogs: "请求明细",
            .sectionTestRequest: "测试请求",
            .sectionTestResult: "测试结果",
            .actionStartDaemon: "启动服务",
            .actionStopDaemon: "停止服务",
            .actionDaemonAlreadyRunning: "已运行",
            .actionDaemonAlreadyStopped: "已停止",
            .actionImportCurrentAuth: "导入当前授权",
            .actionOAuthLogin: "OAuth 登录",
            .actionImportCurrent: "导入当前",
            .actionImportLocalAccountsToRemote: "导入本地账号到远端",
            .actionImportJSON: "导入 JSON",
            .actionExportBackup: "导出备份",
            .actionManualAddAccount: "手动添加",
            .actionRefreshUsage: "刷新用量",
            .actionRefreshingUsage: "刷新中",
            .actionAccountCardRefresh: "刷新",
            .actionAccountCardRefreshing: "刷新中",
            .actionAccountCardEdit: "编辑",
            .actionAccountCardNode: "出站节点",
            .actionAccountCardMore: "更多",
            .actionStopAccountCooldown: "停止冷却",
            .actionSaveAccount: "保存账号",
            .actionRotateAPIKey: "轮换 API Key",
            .actionOpenRequestLogs: "查看详细日志",
            .actionSaveProxySettings: "保存代理设置",
            .actionConfirmProxyModeChange: "确认切换模式",
            .actionSaveManualProxy: "保存手工代理",
            .actionSaveGeneralSettings: "保存设置",
            .actionSaveHost: "保存主机",
            .actionCreateRemoteHost: "新建主机",
            .actionDeleteHost: "删除主机",
            .actionSaveAndContinue: "保存并继续",
            .actionTestConnection: "测试连接",
            .actionRetestConnection: "重新测试",
            .actionBack: "返回",
            .actionContinue: "继续",
            .actionDeploy: "部署",
            .actionRedeploy: "重新部署",
            .actionLoadStatus: "状态",
            .actionStart: "启动",
            .actionStop: "停止",
            .actionLogs: "日志",
            .actionCopyEndpoint: "复制地址",
            .actionCopyUpstreamURL: "复制上游地址",
            .actionCopyAPIKey: "复制 API Key",
            .actionCopyClaudeCodeEnv: "复制 Claude 环境变量",
            .actionCopyGeminiCLIEnv: "复制 Gemini 环境变量",
            .actionAddAPIKey: "新增 API Key",
            .actionEditAPIKey: "编辑",
            .actionEditAccountName: "编辑名称",
            .actionEditOutboundNode: "出站节点",
            .actionEditModelRouting: "模型转换",
            .actionRemoveAPIKey: "删除",
            .actionSetPrimaryAPIKey: "设为默认",
            .actionRegenerateAPIKey: "重新生成",
            .actionEnableAPIKey: "启用 Key",
            .actionDisableAPIKey: "停用 Key",
            .actionSelectAllCompatibleAccounts: "全选兼容账号",
            .actionClearAccountRestriction: "清空限制",
            .actionSelectTimeRange: "选择时间范围",
            .actionAddAnthropicMapping: "新增映射",
            .actionRemoveAnthropicMapping: "删除",
            .actionCreateFirstHost: "创建首个主机",
            .actionApplyNow: "立即生效",
            .actionLoadLocalLogs: "加载本地日志",
            .actionEnableAccount: "启用",
            .actionDisableAccount: "停用",
            .actionRemoveAuthorization: "移除授权",
            .actionManageAccountOrder: "调整使用顺序",
            .actionSaveAccountOrder: "保存顺序",
            .actionClearAccountManagedProxyNodes: "清空出站节点",
            .actionClearFilters: "清空筛选",
            .actionTestProxy: "测试代理",
            .actionOpenHelp: "帮助",
            .actionSendTest: "发送测试",
            .actionCancelTest: "取消测试",
            .actionPreviousPage: "上一页",
            .actionNextPage: "下一页",
            .actionCopyErrorSummary: "复制错误摘要",
            .actionQueryRequestLogs: "查询",
            .actionExportRequestLogs: "导出 CSV",
            .actionCopyTime: "复制时间",
            .actionCopyModel: "复制模型",
            .actionCopyRequestedModel: "复制请求模型",
            .actionCopyActualModel: "复制真实访问模型",
            .actionCopyReasoningEffort: "复制思维等级",
            .actionCopyAccountLabel: "复制账号标签",
            .actionCopyRowCSV: "复制 CSV 行",
            .placeholderNoEndpoint: "暂未生成公开接入地址",
            .placeholderNoAccounts: "还没有导入任何账号。",
            .placeholderSearchAccounts: "搜索名称、邮箱或账号 ID",
            .placeholderNoMatchingAccounts: "当前筛选条件下没有匹配的账号。",
            .placeholderManualAccountLabel: "可选标签",
            .placeholderManualAccountBaseURL: "https://api.openai.com/v1 或 https://host/custom-prefix",
            .placeholderAliyunCodingPlanBaseURL: "https://coding.dashscope.aliyuncs.com 或 https://host/v1",
            .placeholderAnthropicAPICompatibleBaseURL: "https://api.anthropic.com 或 https://host/v1",
            .placeholderGoogleGeminiCompatibleBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            .placeholderManualAccountAPIKey: "输入 API Key",
            .placeholderNoRecentRequests: "还没有记录到请求统计。",
            .placeholderNoRemoteStatus: "还没有加载远程状态。",
            .placeholderNoLogs: "还没有加载日志。",
            .placeholderNoRemoteLogsForHost: "当前主机还没有加载过日志。",
            .placeholderNoLocalLogs: "暂无本地守护进程日志。",
            .placeholderProxyTestPrompt: "输入一段测试提示词，验证本地代理链路和返回效果。",
            .placeholderProxyTestSystem: "可选的系统指令，用于补充这次测试请求的行为约束。",
            .placeholderProxyTestTools: "可选的 tools JSON 数组。Anthropic 示例：[{\"name\":\"run_command\",\"description\":\"执行命令\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}]。Gemini 示例：[{\"functionDeclarations\":[{\"name\":\"run_command\",\"description\":\"执行命令\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}}]}]",
            .placeholderProxyTestResult: "发起一次本地代理测试后，这里会展示模型输出、HTTP 状态、用量和原始响应细节。",
            .placeholderNoRequestLogs: "当前时间范围内还没有请求明细。",
            .placeholderNoProxyAPIKeys: "当前还没有本地代理 API Key。",
            .placeholderNoProxyAPIKeyUsage: "所选时间范围内还没有 API Key 用量记录。",
            .placeholderProxyAPIKeyNoCompatibleAccounts: "当前数据源下没有可选的启用账号。",
            .helperAppearanceAppliesImmediately: "语言和主题切换会立即生效，并且只保存在本机桌面应用中。",
            .helperThemeFollowsSystem: "跟随系统会使用当前 macOS 的外观设置。",
            .helperLanguageFollowsSystem: "跟随系统会使用当前 macOS 的语言偏好。",
            .helperThemeOptionSystem: "跟随当前 macOS 外观。",
            .helperThemeOptionLight: "让整个桌面应用使用更明亮的界面外观。",
            .helperThemeOptionDark: "让整个桌面应用使用更深色的界面外观。",
            .helperLanguageOptionSystem: "使用当前 macOS 语言偏好。",
            .helperLanguageOptionChinese: "桌面应用界面显示为简体中文。",
            .helperLanguageOptionEnglish: "桌面应用界面显示为英文。",
            .helperMenuBarTokenUsage: "在菜单栏图标右侧显示今日输入和输出 token 数。",
            .helperQuickActionOAuth: "打开浏览器完成登录授权，成功后立即导入账号。",
            .helperQuickActionImportCurrent: "读取当前本地授权，并把它加入账号池。",
            .helperQuickActionImportLocalAccountsToRemote: "把当前桌面端本地账号池同步到这台远端主机，并刷新远端相同账号的授权信息。",
            .helperQuickActionImportJSON: "从备份 JSON 文件中批量导入账号。",
            .helperQuickActionManualAdd: "手动保存兼容上游根地址和 API Key，作为独立账号接入。",
            .helperQuickActionExportBackup: "把当前保存的全部账号导出成备份文件。",
            .helperQuickActionTestProxy: "直接打开测试控制台，在应用内验证当前代理链路是否正常。",
            .helperQuickActionRefreshUsage: "刷新所有已导入账号的额度和用量状态。",
            .helperSelectionPolicy: "拖拽定义账号调用顺序。请求会按顺序依次尝试已启用账号，并自动跳过额度阻塞或冷却中的 API Key 账号。",
            .helperManualAPIKeyAccount: "手动添加兼容 API Key 账号，并为该账号单独保存上游根地址。OAuth 账号仍只支持浏览器授权登录。",
            .helperManualAccountGenericOpenAICompatible: "使用标准 OpenAI 兼容模式。请直接填写上游要求的最终 API 前缀；如果对方要求带 `/v1`，这里就保留 `/v1`，后续会按你填写的前缀原样请求。支持 Responses API 的厂商选 Responses；只提供 `/chat/completions` 的厂商选 Chat Completions。如果你填的是 Google 官方 Gemini OpenAI 兼容根地址，请改选 `Google Gemini Compatible`。",
            .helperManualAccountUpstreamAdapter: "默认使用 Responses。如果上游厂商不支持 `/responses`，请选择 Chat Completions。",
            .helperManualAccountThinkingCompatibility: "默认关闭。仅当上游要求发送 `thinking`，并要求在工具调用多轮里回传 `reasoning_content` 时开启；不支持该字段的兼容厂商请保持关闭。",
            .helperManualAccountAliyunCodingPlan: "使用阿里百炼 / Qwen Coding Plan 兼容模式。校验和运行时都会改走更接近 Coding Agent 的 `chat/completions` 链路，让现有本地代理客户端在不改请求格式的前提下尽量保持可用。",
            .helperManualAccountAnthropicAPICompatible: "使用 Anthropic 原生 API Key 模式。连通性校验会先尝试 `/v1/models`；如果上游对该模型列表接口返回 `404/405`，会自动回退到一条最小真实 `你好` 的 `/v1/messages` 探针。运行时使用官方 `/v1/messages` 和 `/v1/messages/count_tokens` 链路，并通过 `x-api-key` 鉴权。",
            .helperManualAccountGoogleGeminiCompatible: "使用 Google 官方 Gemini OpenAI 兼容根地址，并填写 Google AI Studio 生成的 Gemini API key。这个 preset 只用于 API key 兼容流量，不再作为官方 Gemini CLI 的后端路径。连通性校验会先尝试 `/models`；如果上游对该模型列表接口返回 `404/405`，会自动回退到一条最小真实 `你好` 的 `chat/completions` 探针。运行时改走 `chat/completions` 兼容链路。",
            .helperAPIKeyAccountNoStandardUsage: "连接已校验成功，这类账号暂不提供标准用量数据。",
            .helperAccountLabelRequired: "请先填写名称。",
            .helperManualAccountAPIKeyRequired: "请先填写 API Key。",
            .helperManualAccountBaseURLInvalid: "请输入合法的根地址，例如 https://api.openai.com 或 https://host/v1。",
            .errorManualAccountGoogleGeminiPresetRequired: "检测到 Google Gemini OpenAI-compatible 根地址，请将 Provider 切换为 `Google Gemini Compatible`，不要使用 `Generic OpenAI Compatible`。",
            .errorManualAccountGoogleGeminiAPIKeyOnly: "Google Gemini Compatible 目前只支持 Gemini API key。Google / Gemini 登录态不能作为这个兼容 preset 的账号导入。请改用 Google AI Studio 生成的 Gemini API key，或者到账号页使用新的 `Google / Gemini Login` 原生登录。",
            .helperServiceDiagnostics: "在这里查看 LaunchAgent 注册情况、运行状态、本地日志路径和最近一次启动失败原因。",
            .helperAnthropicConnection: "Claude Code 只需要使用根地址接入；如果你希望 Codex 或其它 OpenAI-compatible 客户端也固定走 Anthropic 账号池，也可以在 OpenAI 兼容 Base URL 上复用这把 Anthropic 路由的本地 API Key。",
            .helperGeminiConnection: "Gemini CLI 通过 `GOOGLE_GEMINI_BASE_URL` 指向代理根地址，并通过 `GEMINI_API_KEY` 复用同一份本地 API Key。Gemini CLI 请求现在只会通过账号页 `Google / Gemini Login` 导入的账号执行。`Google Gemini Compatible` 仍可用于 API key 兼容路由，但不再作为 Gemini CLI 的后端路径。",
            .helperOutboundProxyGlobalModeDisabled: "如果你本机运行的代理软件已经开启全局代理，这里的代理模式应选择 `关闭`，避免请求再次经过一层代理。",
            .helperSaveManualProxyDoesNotSwitchMode: "这只会保存手工代理地址，不会切换当前生效的代理模式。",
            .helperConfirmProxyModeChangeNeedsManualSave: "请先保存手工代理后再确认切换。",
            .helperConfirmProxyModeChangeNeedsSubscription: "请先配置订阅代理后再确认切换。",
            .helperProxyAPIKeys: "为不同用户或工具分别创建本地 API Key。默认 Key 会用于页面复制、环境变量片段和测试控制台。",
            .helperProxyAPIKeyUsage: "按自然日、自然周、自然月或自定义时间范围查看每个 API Key 的请求量和 token 用量。",
            .helperNaturalTokenUsage: "基于本地请求日志按本地自然日、周一开始的自然周和自然月实时聚合。",
            .helperProxyAPIKeyValueRequired: "保存前请先填写非空的 API Key。",
            .helperProxyAPIKeyAtLeastOne: "至少保留一个本地代理 API Key。",
            .helperProxyAPIKeyAtLeastOneEnabled: "至少保留一个启用中的 API Key，客户端才能继续访问代理。",
            .helperProxyAPIKeyAllowedAccounts: "留空表示不限制，这个 Key 会继续使用当前数据源下全部兼容且启用的账号。只要勾选了账号，这个 Key 就只能路由到这些兼容账号。",
            .helperProxyAPIKeyStaleSelections: "下面这些已保存的账号限制现在已经不再可选。系统会继续保留它们，直到你手动移除，避免保存时无意中放宽访问范围。",
            .helperAnthropicModelMapping: "在这里控制 Anthropic / Claude 模型名如何映射到上游目标模型。没有命中的模型会使用默认目标模型。",
            .helperAnthropicMappingFallback: "未单独配置的 Anthropic 模型都会回退到默认目标模型。",
            .helperAnthropicOAuthModelFallback: "如果映射后的目标模型不被官方 OAuth 上游接受，代理会自动回退到 `gpt-5.5`。",
            .helperServiceChecking: "正在检查本地服务状态，确认完成后会自动恢复可操作按钮。",
            .helperServiceCanStart: "服务当前未运行，可以直接启动。",
            .helperServiceCanStop: "服务当前正在运行，如需重启或维护可先停止。",
            .helperServiceDegraded: "服务进程仍在运行，但接口健康检查失败，请优先查看诊断信息或日志。",
            .helperServiceNotInstalled: "尚未安装 LaunchAgent，点击启动服务时会自动完成安装。",
            .helperServiceStarting: "本地服务正在启动，请等待健康检查完成。",
            .helperServiceStopping: "本地服务正在停止，请等待关闭完成。",
            .warningLaunchConfigurationSavedRestartRequired: "设置已保存，但当前运行中的本地服务保持不变；请手动先停止再重新启动服务，启动参数类变更才会完全生效。",
            .helperRemoteStatusRequired: "请先加载远程状态，再执行启动或停止操作。",
            .helperRemoteCanStart: "远程服务当前未运行，可以直接启动。",
            .helperRemoteCanStop: "远程服务当前正在运行，可以直接停止。",
            .helperRemoteUnreachable: "暂时无法确认远程服务状态，请先重新加载状态后再操作。",
            .helperRemoteStarting: "远程服务正在启动，请等待本次操作完成。",
            .helperRemoteStopping: "远程服务正在停止，请等待本次操作完成。",
            .helperRemoteNeedsSavedHost: "请先保存当前主机，再进入验证步骤。",
            .helperRemoteNeedsVerification: "请先完成连接测试，远程部署和服务控制才会解锁。",
            .helperRemoteSystemctlUnavailable: "远程主机没有可用的 `systemctl`，当前 systemd 部署流程无法继续。",
            .helperRemoteSudoUnavailable: "当前远程用户无法完成 `sudo -v`。部署前请切换为 root 或配置免密 sudo。",
            .helperRemoteDirectoryUnavailable: "配置的远程目录不可写，并且它的父目录也不可写。",
            .helperRemoteDeployUnavailable: "当前构建缺少与所选主机匹配的内置 Linux 部署包，所以不能执行远程部署。你仍可加载状态、查看日志、启动或停止已部署服务，并在服务运行时打开远端管理台。",
            .helperRemoteRedeploy: "会重新下发应用内置的 Linux 包和服务配置，用来刷新远程代理服务、二进制以及 systemd 配置，适合远端服务版本偏旧时使用。",
            .helperRemoteOperationsLocked: "只有最近一次连接测试通过后，远端运维操作才会解锁；执行部署还需要当前构建携带应用内置 Linux 部署包。",
            .oauthFlowDescription: "通过浏览器完成授权，成功后自动导入账号；如果本地回调没有完成，也可以手动粘贴回调链接。",
            .oauthLinkLabel: "授权链接",
            .oauthCallbackLabel: "回调链接",
            .oauthCallbackPlaceholder: "如果没有自动导入，请粘贴浏览器最终跳转的完整回调链接。",
            .oauthListening: "监听中",
            .oauthOpenBrowser: "打开浏览器",
            .oauthParseCallback: "解析回调",
            .oauthManualHint: "AI Coding Proxy 已经在本地监听回调地址。如果浏览器没有自动返回完成，直接把最终回调链接粘贴到这里即可。",
            .oauthAutoImportHint: "浏览器成功跳回 localhost 后会自动完成导入。",
            .oauthCallbackHint: "请保留完整回调链接，必须包含 code 和 state 两个查询参数。",
            .oauthBrowserOpenFailed: "浏览器没有自动打开",
            .oauthInvalidLink: "授权链接无效",
            .oauthCallbackMissing: "请先粘贴回调链接",
            .confirmStopDaemonTitle: "确认停止本地服务？",
            .confirmStopDaemonMessage: "本地 LaunchAgent 守护进程会立即停止。依赖这条本地服务链路的代理请求会在你重新启动前暂时不可用。",
            .confirmStopDaemonAutoStartWarning: "当前已开启自动启动。服务停止后，执行 Reload 或重新打开应用时，服务仍可能再次启动。",
            .confirmStopDaemonAction: "停止服务",
            .confirmClearAccountManagedProxyNodesTitle: "确认清空全部账号的自定义出站节点？",
            .confirmClearAccountManagedProxyNodesMessage: "这个操作会清空所有账号已保存的自定义出站节点，包括当前搜索或筛选没有显示出来的账号。清空后，全部账号都会重新跟随设置页的全局出站模式。",
            .confirmClearAccountManagedProxyNodesAction: "全部清空",
            .confirmStopAccountCooldownTitle: "确认停止这个账号的冷却？",
            .confirmStopAccountCooldownAction: "停止冷却",
            .confirmRemoveAuthorizationTitle: "确认移除这条本地授权？",
            .confirmRemoveAuthorizationMessage: "这只会删除 AI Coding Proxy 账号池里保存的本地授权记录，不会清除当前 `~/.codex/auth.json` 登录态。",
            .confirmImportLocalAccountsToRemoteTitle: "确认把本地账号导入到这台远端主机？",
            .confirmImportLocalAccountsToRemoteAction: "导入到远端",
            .confirmDeleteRemoteHostTitle: "确认删除这条远程主机配置？",
            .confirmDeleteRemoteHostAction: "删除主机",
            .helperNoMatchingAccounts: "调整筛选条件，或清空搜索与筛选后查看全部已导入账号。",
            .optionFollowSystem: "跟随系统",
            .optionLight: "浅色",
            .optionDark: "深色",
            .optionChineseSimplified: "简体中文",
            .optionEnglish: "English",
            .optionCards: "卡片",
            .optionList: "列表",
            .optionDisabled: "关闭",
            .optionHTTP: "HTTP",
            .optionHTTPS: "HTTPS",
            .optionSOCKS5: "SOCKS5",
            .optionHideToMenuBar: "隐藏到状态栏",
            .optionQuit: "退出应用",
            .optionSSHKeyPath: "密钥文件路径",
            .optionSSHKeyContent: "粘贴私钥内容",
            .optionPassword: "密码",
            .optionHealthy: "正常",
            .optionAnyIssue: "任意异常",
            .optionRefreshBlocked: "刷新受阻",
            .optionUsageIssue: "用量异常",
            .optionCustom: "自定义",
            .optionToday: "今天",
            .optionThisWeek: "本周",
            .optionThisMonth: "本月",
            .optionLastWeek: "上周",
            .optionTwoWeeksAgo: "2 周前",
            .optionThreeWeeksAgo: "3 周前",
            .optionOther: "其他或未知",
            .optionLast15Minutes: "最近 15 分钟",
            .optionLast1Hour: "最近 1 小时",
            .optionLast24Hours: "最近 24 小时",
            .optionLast7Days: "最近 7 天",
            .optionAscending: "升序",
            .optionDescending: "降序",
            .optionChatCompletions: "Chat",
            .optionResponses: "Responses",
            .optionUpstreamAdapterChatCompletions: "Chat Completions",
            .optionUpstreamAdapterResponses: "Responses",
            .optionThinkingCompatibilityDisabled: "关闭",
            .optionThinkingCompatibilityEnabled: "开启",
            .optionAnthropicMessages: "Anthropic",
            .optionGeminiGenerateContent: "Gemini",
            .optionAutoSelectByOrder: "自动选择（按排序）",
            .providerPresetGenericOpenAICompatible: "通用 OpenAI 兼容",
            .providerPresetAliyunQwenCodingPlan: "阿里百炼 / Qwen Coding Plan",
            .providerPresetAnthropicAPICompatible: "Anthropic API 兼容",
            .providerPresetGoogleGeminiCompatible: "Google Gemini 兼容",
            .remoteWorkflowHostsTitle: "主机管理",
            .remoteWorkflowHostsSubtitle: "先选择已保存主机，或新建、清理远程主机草稿，再进入后续部署流程。",
            .remoteWorkflowConfigurationTitle: "连接配置",
            .remoteWorkflowConfigurationSubtitle: "为当前选中的主机整理 SSH 身份信息和运行端口。",
            .remoteWorkflowVerificationTitle: "部署前验证",
            .remoteWorkflowVerificationSubtitle: "部署前确认 SSH、sudo、systemd、目录权限和应用内置的 Linux 部署包都已经就绪。",
            .remoteWorkflowOperationsTitle: "部署与运维",
            .remoteWorkflowOperationsSubtitle: "在可用时部署或重新部署应用内置 Linux 包，并针对当前主机刷新运行状态、查看远端日志。",
            .remoteSavedHostsEmpty: "还没有保存远程主机，请先在左侧填写配置。",
            .remoteLogsHint: "部署、启动、停止后可通过这里快速确认服务是否健康。",
            .proxyConnectionHint: "将以下接入信息用于本地 OpenAI 兼容客户端。",
            .labelRecentFourWeeks: "最近 4 周",
            .labelDailyTrend: "按日趋势",
            .labelWeeklyTrend: "按周趋势",
            .overviewServiceHint: "用更专业的视图快速掌握本地代理运行状态和最近请求分布。",
            .overviewTrafficHint: "先看本地请求汇总，再对比今天、本周和本月的 Token 用量，并结合最近 4 周的按日、按周趋势判断流量变化。",
            .overviewDiagnosticsHint: "更详细的服务诊断和本地日志路径请到 设置 > 服务 查看。",
            .requestLogsTitle: "请求详细日志",
            .requestLogsSubtitle: "查看请求级别的 tokens、耗时、缓存命中和账号路由，不保存 prompt 或响应正文。",
            .requestLogsFilterHint: "在这里调整时间范围、客户端来源、本地 API Key、账号标签和模型。修改筛选后点击查询应用，排序会立即生效，点击刷新可重新获取当前结果。",
            .requestLogsPendingFiltersHint: "筛选条件已变更，点击查询后更新结果。",
            .requestLogsPendingFiltersCompactHint: "点击查询应用筛选",
            .requestLogsTableHint: "这里仅保存请求元数据。API Key 以密文落盘，表格默认脱敏展示，调试时仍可复制完整值。",
            .requestLogsEmptyHint: "可以尝试扩大时间范围，或清空客户端来源、API Key、账号标签、模型筛选条件后再查看。",
            .proxyTestTitle: "测试控制台",
            .proxyTestSubtitle: "使用当前本地代理地址和 API Key 直接访问 `/v1` 接口，快速验证效果并查看调试细节。",
            .proxyTestHealthHint: "控制台会先检查本地服务健康状态，再加载桌面端模型目录。本地代理不可用时会禁用发送。",
            .proxyTestRequestHint: "通过结构化字段填写请求，同时保留只读 JSON 预览，方便核对实际发送内容。",
            .proxyTestResultHint: "这里会展示和真实客户端同一路径返回的文本结果、用量、耗时、HTTP 状态和原始响应。",
            .proxyTestFallbackModels: "无法读取桌面端模型目录，已回退为内置接口模型族列表。",
            .proxyTestMissingOpenAIDataSourceAPIKey: "当前没有启用的 OpenAI 数据源本地 API Key，无法锁定测试这个账号。",
            .proxyTestMissingAnthropicDataSourceAPIKey: "当前没有启用的 Anthropic 数据源本地 API Key，无法锁定测试这个账号。",
            .proxyTestMissingGeminiDataSourceAPIKey: "当前没有启用的 Gemini 数据源本地 API Key，无法锁定测试这个账号。",
            .proxyTestMissingAnthropicOAuthCompatibleAPIKey: "当前没有可用于测试 Anthropic 授权账号的启用本地 API Key，无法锁定测试这个账号。",
            .proxyTestSelectedAccountOutsideAPIKeyAllowlist: "当前虽然有启用的兼容本地 API Key，但这个账号不在它们允许使用的账号范围内，无法锁定测试。",
            .helpWindowTitle: "使用帮助",
            .onboardingWindowTitle: "新手引导",
            .helpWindowSubtitle: "在独立窗口中查看首次上手步骤、全部页面说明，以及常用辅助窗口的使用方法。",
            .aboutWindowSubtitle: "这是一个聚合账号池、客户端接入、运行诊断与远程部署管理能力的本地桌面工作台。",
            .aboutOverviewTitle: "这个软件是做什么的",
            .aboutOverviewBody: "AI Coding Proxy 会把你的 Mac 变成一个结构化的本地编程 AI 网关。它帮助你统一导入上游账号、生成稳定的客户端接入地址、查看运行状态，并在同一个桌面控制台里管理本地与远程代理服务。",
            .aboutCapabilityAccounts: "集中管理导入的上游账号，并持续查看额度、健康状态和路由就绪情况。",
            .aboutCapabilityAccess: "为 OpenAI 兼容、Anthropic 与 Gemini 工具链提供稳定的本地接入信息。",
            .aboutCapabilityRemote: "在需要脱离本机运行时，把远程代理服务部署并运维到 Linux 主机。",
            .aboutDeveloperTitle: "开发者",
            .aboutDeveloperBody: "由下方开发者持续设计与维护，可通过联系邮箱进行协作或反馈。",
            .errorOperationFailed: "操作失败",
            .errorNetworkIssue: "网络请求失败",
            .errorAuthorizationFailed: "授权失败",
            .errorImportFailed: "导入失败",
            .errorUsageRefreshFailed: "用量刷新失败",
            .errorRemoteConnectionFailed: "远程连接失败",
            .errorRemoteDeployFailed: "远程部署失败",
            .errorDaemonControlFailed: "服务控制失败",
            .errorConfigurationFailed: "配置更新失败",
            .errorAccountManagementFailed: "账号管理失败",
            .errorCopyFailed: "复制失败",
            .errorRequestLogsFailed: "请求日志加载失败",
            .errorRequestLogsExportFailed: "请求日志导出失败",
            .errorProxyTestFailed: "代理测试失败",
            .errorProxyAPIKeyFailed: "API Key 更新失败",
            .errorProxyAPIKeyUsageFailed: "API Key 用量加载失败",
            .successDaemonStarted: "服务已启动",
            .successDaemonStopped: "服务已停止",
            .successAuthImported: "当前授权已导入",
            .successLocalAccountsImportedToRemote: "本地账号已导入到远端",
            .successJSONImported: "JSON 账号已导入",
            .successBackupExported: "备份已导出",
            .successManualAPIKeyAccountAdded: "API Key 账号已添加",
            .successManualAPIKeyAccountUpdated: "API Key 账号已更新",
            .successAccountLabelUpdated: "账号名称已更新",
            .successAccountManagedProxyNodeUpdated: "账号出站节点已更新",
            .successAccountManagedProxyNodesCleared: "账号出站节点已清空",
            .successAccountModelRoutingUpdated: "账号模型转换已更新",
            .successAccountCooldownStopped: "账号冷却已停止",
            .successUsageRefreshed: "用量已刷新",
            .successAccountUsageRefreshed: "账号用量已刷新",
            .successProxyKeyRotated: "API Key 已轮换",
            .successSettingsSaved: "设置已保存",
            .successPreferencesSaved: "外观偏好已保存",
            .successOAuthStarted: "已在浏览器中打开 OAuth 流程",
            .successOAuthCompleted: "OAuth 账号已导入",
            .successRemoteConnectionTested: "远程连接已验证",
            .successRemoteDeployed: "远程代理服务已部署",
            .successRemoteHostDeleted: "远程主机已删除",
            .successRemoteStarted: "远程代理服务已启动",
            .successRemoteStopped: "远程代理服务已停止",
            .successRemoteStatusLoaded: "远程状态已加载",
            .successRemoteLogsLoaded: "远程日志已加载",
            .successCopiedEndpoint: "接入地址已复制",
            .successCopiedUpstreamURL: "上游地址已复制",
            .successCopiedAPIKey: "API Key 已复制",
            .successCopiedClaudeCodeEnv: "Claude Code 环境变量已复制",
            .successCopiedGeminiCLIEnv: "Gemini CLI 环境变量已复制",
            .successCopiedOAuthLink: "授权链接已复制",
            .successCopiedManagedProxyTerminalCommand: "终端代理命令已复制",
            .successCopiedErrorSummary: "错误摘要已复制",
            .successCopiedTime: "时间已复制",
            .successCopiedModel: "模型已复制",
            .successCopiedRequestedModel: "请求模型已复制",
            .successCopiedActualModel: "真实访问模型已复制",
            .successCopiedReasoningEffort: "思维等级已复制",
            .successCopiedAccountLabel: "账号标签已复制",
            .successCopiedRowCSV: "CSV 行已复制",
            .successRequestLogsExported: "请求日志已导出",
            .successHostSaved: "远程主机已保存",
            .successAccountEnabled: "账号已启用",
            .successAccountDisabled: "账号已停用",
            .successAuthorizationRemoved: "本地授权已移除",
            .successAccountOrderUpdated: "账号顺序已更新",
            .successProxyTestCompleted: "代理测试已完成",
            .successProxyModelsLoaded: "模型列表已加载",
            .successProxyAPIKeyAdded: "API Key 已添加",
            .successProxyAPIKeyUpdated: "API Key 已更新",
            .successProxyAPIKeyRemoved: "API Key 已删除",
            .successProxyAPIKeyRegenerated: "API Key 已重新生成",
            .successProxyAPIKeyPrimaryChanged: "默认 API Key 已切换",
        ],
    ]
}
