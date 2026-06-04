#if os(macOS)
import Combine
import CodexProxyCore
import XCTest
@testable import CodexProxyDesktop

@MainActor
private final class ClientConfigManagerWindowControllerSpy: ClientConfigManagerWindowControlling {
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
private final class CodexProjectRoutesWindowControllerSpy: CodexProjectRoutesWindowControlling {
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
final class ClientConfigManagementTests: XCTestCase {
    func testOpenAndDismissClientConfigManagerWindow() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let presenter = ClientConfigManagerWindowControllerSpy()
        let model = DesktopAppModel(
            clientConfigFileService: context.service,
            clientConfigManagerWindowFactory: { _ in presenter }
        )
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]

        model.openClientConfigManagerWindow()
        await Self.waitForCondition {
            model.clientConfigManagerInspections.isEmpty == false
        }

        XCTAssertTrue(model.isClientConfigManagerPresented)
        XCTAssertEqual(presenter.showWindowCallCount, 1)
        XCTAssertEqual(model.clientConfigManagerSelectedProxyAPIKeyRecord()?.id, "primary")

        model.dismissClientConfigManagerWindow()

        XCTAssertFalse(model.isClientConfigManagerPresented)
        XCTAssertEqual(presenter.closeWindowCallCount, 1)
    }

    func testOpenAndDismissCodexProjectRoutesWindow() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let presenter = CodexProjectRoutesWindowControllerSpy()
        let model = DesktopAppModel(
            clientConfigFileService: context.service,
            codexProjectRoutesWindowFactory: { _ in presenter }
        )
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]

        model.openCodexProjectRoutesWindow()
        await Self.waitForCondition {
            model.clientConfigManagerInspections[.codex] != nil
        }

        XCTAssertTrue(model.isCodexProjectRoutesPresented)
        XCTAssertEqual(presenter.showWindowCallCount, 1)

        model.openCodexProjectRoutesWindow()
        XCTAssertEqual(presenter.showWindowCallCount, 2)

        model.dismissCodexProjectRoutesWindow()

        XCTAssertFalse(model.isCodexProjectRoutesPresented)
        XCTAssertEqual(presenter.closeWindowCallCount, 1)
    }

    func testClientConfigManagerAvailableProxyAPIKeysOnlyIncludesEnabledKeys() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [
            Self.proxyKey(id: "enabled", label: "Enabled", key: "sk-local-enabled"),
            ProxyAPIKeyRecord(id: "disabled", label: "Disabled", key: "sk-local-disabled", dataSource: .all, enabled: false, createdAt: 2),
        ]

        XCTAssertEqual(model.clientConfigManagerAvailableProxyAPIKeys.map(\.id), ["enabled"])
    }

    func testClientConfigManagerCannotApplyWithoutEnabledKey() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [
            ProxyAPIKeyRecord(id: "disabled", label: "Disabled", key: "sk-local-disabled", dataSource: .all, enabled: false, createdAt: 2),
        ]

        XCTAssertFalse(model.clientConfigManagerCanApplyCurrentSelection)
        XCTAssertNotNil(model.clientConfigManagerApplyUnavailableReason)
        XCTAssertTrue(model.clientConfigManagerCurrentSelectionStatusText.contains("API Key"))

        model.preferences.languageMode = .zhHans
        XCTAssertTrue(model.clientConfigManagerApplyUnavailableReason?.contains("代理页") == true)
    }

    func testClientConfigManagerApplyButtonTitleIncludesTarget() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.preferences.languageMode = .english
        model.clientConfigManagerTarget = .claudeCode

        XCTAssertEqual(model.clientConfigManagerApplyButtonTitle(), "Write To Claude Code")

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(model.clientConfigManagerApplyButtonTitle(), "写入到 Claude Code")
    }

    func testClientConfigManagerUtilityButtonTitlesDescribeActions() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)

        model.preferences.languageMode = .english
        XCTAssertEqual(model.clientConfigManagerRevealFilesButtonTitle, "Reveal Config Files")
        XCTAssertEqual(model.clientConfigManagerViewBackupsButtonTitle, "View Restorable Backups")
        XCTAssertEqual(model.clientConfigManagerRefreshStatusButtonTitle, "Refresh Config Status")

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(model.clientConfigManagerRevealFilesButtonTitle, "打开配置文件位置")
        XCTAssertEqual(model.clientConfigManagerViewBackupsButtonTitle, "查看可回退备份")
        XCTAssertEqual(model.clientConfigManagerRefreshStatusButtonTitle, "重新检测配置状态")
    }

    func testClientConfigManagerEntryTitleClarifiesLocalClientConfiguration() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)

        model.preferences.languageMode = .english
        XCTAssertEqual(model.actionOpenClientConfigManager, "Codex/Claude Config Manager")

        model.preferences.languageMode = .zhHans
        XCTAssertEqual(model.actionOpenClientConfigManager, "Codex/Claude 配置管理")
    }

    func testClientConfigBackupDrawerPresentationState() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)

        XCTAssertFalse(model.isClientConfigBackupDrawerPresented)

        model.presentClientConfigBackupDrawer()

        XCTAssertTrue(model.isClientConfigBackupDrawerPresented)

        model.dismissClientConfigBackupDrawer()

        XCTAssertFalse(model.isClientConfigBackupDrawerPresented)
    }

    func testApplyClientConfigManagerSelectionPublishesSuccess() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        let key = Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")
        model.settings.proxyAPIKeys = [key]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()

        XCTAssertGreaterThan(model.clientConfigManagerPreviewRevision, 0)
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.clientConfigManagerApplySuccessTitle(for: .codex))
        XCTAssertEqual(model.banners.first?.detail, model.clientConfigManagerApplySuccessDetail(for: .codex, proxyAPIKey: key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.homeDirectory.appendingPathComponent(".codex/auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.homeDirectory.appendingPathComponent(".codex/config.toml").path))
    }

    func testRestoreClientConfigBackupPublishesSuccess() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()
        let backup = try XCTUnwrap(context.service.listBackups(target: .codex).first)

        model.clearBanner()
        await model.restoreClientConfigBackup(backup)

        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(model.banners.first?.title, model.clientConfigManagerRestoreSuccessTitle(for: .codex))
        XCTAssertEqual(model.banners.first?.detail, model.clientConfigManagerRestoreSuccessDetail(for: backup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.homeDirectory.appendingPathComponent(".codex/auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.homeDirectory.appendingPathComponent(".codex/config.toml").path))
    }

    func testClientConfigManagerInspectionFailureUsesReadFailedStatusText() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        try Self.write("{not-json", to: context.homeDirectory.appendingPathComponent(".claude/settings.json"))

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.preferences.languageMode = .english
        model.clientConfigManagerTarget = .claudeCode

        await model.refreshClientConfigManagerState(showLoading: true)

        let inspection = model.clientConfigManagerInspection(for: .claudeCode)
        XCTAssertNotNil(inspection.errorMessage)
        XCTAssertEqual(model.clientConfigManagerCurrentKeyStatusText(for: inspection), "Read Failed")
    }

    func testOpenClientConfigManagerLoadsPreviews() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let presenter = ClientConfigManagerWindowControllerSpy()
        let model = DesktopAppModel(
            clientConfigFileService: context.service,
            clientConfigManagerWindowFactory: { _ in presenter }
        )
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        model.openClientConfigManagerWindow()
        await Self.waitForCondition {
            model.clientConfigManagerCurrentPreviews[.codex] != nil
                && model.clientConfigManagerProposedPreviews[.codex] != nil
        }

        XCTAssertEqual(presenter.showWindowCallCount, 1)
        XCTAssertEqual(model.clientConfigManagerCurrentPreviews[.codex]?.files.count, 2)
        XCTAssertTrue(model.clientConfigManagerProposedPreviews[.codex]?.files.first?.content.contains("sk-local-primary") == true)
    }

    func testRefreshClientConfigManagerStatePublishesLoadingAndLoadedOnly() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        var publishCount = 0
        let cancellable = model.objectWillChange.sink {
            publishCount += 1
        }

        await model.refreshClientConfigManagerState(showLoading: true, target: .codex)

        XCTAssertLessThanOrEqual(publishCount, 2)
        XCTAssertNotNil(model.clientConfigManagerInspections[.codex])
        XCTAssertNotNil(model.clientConfigManagerCurrentPreviews[.codex])
        XCTAssertNotNil(model.clientConfigManagerProposedPreviews[.codex])
        XCTAssertTrue(model.clientConfigManagerState.loadedTargets.contains(.codex))
        withExtendedLifetime(cancellable) {}
    }

    func testClientConfigPageLazilyLoadsOnlyCurrentTargetThenSelectedTarget() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]

        model.selectedPage = .clientConfig
        await Self.waitForCondition {
            model.clientConfigManagerState.loadedTargets.contains(.codex)
        }

        XCTAssertEqual(model.clientConfigManagerState.loadedTargets, [.codex])
        XCTAssertNil(model.clientConfigManagerCurrentPreviews[.claudeCode])
        XCTAssertNil(model.clientConfigManagerCurrentPreviews[.gemini])

        model.clientConfigManagerSelectTarget(.gemini)
        await Self.waitForCondition {
            model.clientConfigManagerState.loadedTargets.contains(.gemini)
        }

        XCTAssertEqual(model.clientConfigManagerState.loadedTargets, [.codex, .gemini])
        XCTAssertNotNil(model.clientConfigManagerCurrentPreviews[.gemini])
        XCTAssertNil(model.clientConfigManagerCurrentPreviews[.claudeCode])
    }

    func testClientConfigBackupsLoadOnlyWhenDrawerIsOpened() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let proxyKey = Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")
        _ = try context.service.applyConfiguration(
            target: .codex,
            proxyAPIKey: proxyKey,
            endpoints: ClientConfigEndpointBundle(
                openAIBaseURL: "http://127.0.0.1:8080/v1",
                anthropicBaseURL: "http://127.0.0.1:8080/anthropic",
                geminiBaseURL: "http://127.0.0.1:8080/gemini"
            )
        )

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [proxyKey]
        await model.refreshClientConfigManagerState(showLoading: true, target: .codex)

        XCTAssertTrue(model.clientConfigManagerBackups.isEmpty)
        XCTAssertTrue(model.clientConfigManagerState.loadedBackupTargets.isEmpty)

        model.presentClientConfigBackupDrawer()
        await Self.waitForCondition {
            model.clientConfigManagerState.loadedBackupTargets.contains(.codex)
        }

        XCTAssertEqual(model.clientConfigManagerBackups.filter { $0.target == .codex }.count, 1)
    }

    func testSelectingProxyAPIKeyRefreshesProposedPreview() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [
            Self.proxyKey(id: "first", label: "First", key: "sk-local-first"),
            Self.proxyKey(id: "second", label: "Second", key: "sk-local-second"),
        ]
        model.clientConfigManagerTarget = .codex

        await model.refreshClientConfigManagerState(showLoading: true)
        model.clientConfigManagerSelectProxyAPIKey("second")
        await Self.waitForCondition {
            model.clientConfigManagerProposedPreviews[.codex]?.files.first?.content.contains("sk-local-second") == true
        }

        XCTAssertTrue(model.clientConfigManagerProposedPreviews[.codex]?.files.first?.content.contains("sk-local-second") == true)
    }

    func testRefreshBuildsDerivedPreviewCacheAndAdvancesRevision() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        XCTAssertEqual(model.clientConfigManagerPreviewRevision, 0)
        XCTAssertTrue(model.clientConfigManagerDerivedPreviewStates.isEmpty)
        XCTAssertTrue(model.clientConfigManagerChangeSummaryCounts.isEmpty)

        await model.refreshClientConfigManagerState(showLoading: true)

        XCTAssertGreaterThan(model.clientConfigManagerPreviewRevision, 0)
        XCTAssertFalse(model.clientConfigManagerDerivedPreviewStates.isEmpty)
        XCTAssertEqual(model.clientConfigManagerVisibleFilePresentations.count, 2)
        XCTAssertEqual(model.clientConfigManagerChangedFileCount, 2)
        XCTAssertEqual(model.clientConfigManagerChangeSummaryCounts[.codex]?.changedFileCount, model.clientConfigManagerChangedFileCount)
    }

    func testSelectingProxyAPIKeyAdvancesPreviewRevision() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [
            Self.proxyKey(id: "first", label: "First", key: "sk-local-first"),
            Self.proxyKey(id: "second", label: "Second", key: "sk-local-second"),
        ]
        model.clientConfigManagerTarget = .codex

        await model.refreshClientConfigManagerState(showLoading: true)
        let revisionAfterRefresh = model.clientConfigManagerPreviewRevision

        model.clientConfigManagerSelectProxyAPIKey("second")
        await Self.waitForCondition {
            model.clientConfigManagerProposedPreviews[.codex]?.files.first?.content.contains("sk-local-second") == true
        }

        XCTAssertGreaterThan(model.clientConfigManagerPreviewRevision, revisionAfterRefresh)
        XCTAssertTrue(model.clientConfigManagerProposedPreviews[.codex]?.files.first?.content.contains("sk-local-second") == true)
        XCTAssertFalse(model.clientConfigManagerDerivedPreviewStates.isEmpty)
    }

    func testCodexProjectRouteDraftUsesEnabledLocalKeyAndCanBeDismissed() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [
            Self.proxyKey(id: "enabled", label: "Enabled", key: "sk-local-enabled"),
            ProxyAPIKeyRecord(id: "disabled", label: "Disabled", key: "sk-local-disabled", dataSource: .all, enabled: false, createdAt: 2),
        ]

        model.presentNewCodexProjectRoute()

        XCTAssertEqual(model.codexProjectRouteDraft?.proxyAPIKeyID, "enabled")
        XCTAssertEqual(model.codexProjectRouteDraft?.client, .codex)
        XCTAssertEqual(model.codexProjectRouteDraft?.claudeSettingsScope, .local)
        XCTAssertFalse(model.canSaveCodexProjectRouteDraft)

        model.codexProjectRouteDraft?.projectPath = context.root.appendingPathComponent("project").path
        model.codexProjectRouteDraft?.routeModel = "cp-route-heavy-work"
        model.codexProjectRouteDraft?.targetModel = "deepseek-reasoner"

        XCTAssertTrue(model.canSaveCodexProjectRouteDraft)

        model.updateCodexProjectRouteDraftClient(.claudeCode)
        XCTAssertEqual(model.codexProjectRouteDraft?.client, .claudeCode)
        XCTAssertEqual(model.codexProjectRouteDraft?.targetModel, "deepseek-reasoner")
        model.regenerateCodexProjectRouteModel()
        XCTAssertTrue(model.codexProjectRouteDraft?.routeModel.hasPrefix("claude-cp-route-") == true)

        model.dismissCodexProjectRouteDraft()

        XCTAssertNil(model.codexProjectRouteDraft)
    }

    func testSaveNewCodexProjectRouteDraftWritesProjectConfigAndModelCatalog() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectDirectory = context.root.appendingPathComponent("new-codex-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let configURL = projectDirectory.appendingPathComponent(".codex/config.toml")
        let catalogURL = projectDirectory.appendingPathComponent(".codex/codex-proxy-model-catalog.json")

        let model = Self.makeProjectRouteModel(context: context)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "local-heavy", label: "Heavy", key: "sk-local-heavy")]
        model.presentNewCodexProjectRoute()
        model.codexProjectRouteDraft?.label = "Heavy Project"
        model.codexProjectRouteDraft?.projectPath = projectDirectory.path
        model.codexProjectRouteDraft?.routeModel = "cp-route-heavy-work"
        model.codexProjectRouteDraft?.targetModel = "deepseek-reasoner"

        await model.saveCodexProjectRouteDraft()

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"cp-route-heavy-work\""))
        XCTAssertTrue(content.contains("model_catalog_json = \"\(catalogURL.path)\""))
        let catalogObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let models = try XCTUnwrap(catalogObject["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["slug"] as? String, "cp-route-heavy-work")
        XCTAssertNil(model.codexProjectRouteDraft)
        XCTAssertEqual(model.settings.codexProjectRoutes.map(\.routeModel), ["cp-route-heavy-work"])
        XCTAssertEqual(context.service.listBackups(target: .codex).first?.files.map(\.path), [configURL.path, catalogURL.path])
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertTrue(
            model.banners.first?.title.contains("项目路由已保存并写入项目配置") == true
                || model.banners.first?.title.contains("Project Route Saved And Written") == true
        )
    }

    func testSaveNewClaudeProjectRouteDraftWritesSelectedSettingsScope() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectDirectory = context.root.appendingPathComponent("new-claude-project", isDirectory: true)
        let settingsURL = projectDirectory.appendingPathComponent(".claude/settings.local.json")
        try Self.write(#"{"env":{"FOO":"bar"}}"#, to: settingsURL)

        let model = Self.makeProjectRouteModel(context: context)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "local-claude", label: "Claude", key: "sk-local-claude")]
        model.presentNewCodexProjectRoute()
        model.codexProjectRouteDraft?.client = .claudeCode
        model.codexProjectRouteDraft?.claudeSettingsScope = .local
        model.codexProjectRouteDraft?.label = "Claude Project"
        model.codexProjectRouteDraft?.projectPath = projectDirectory.path
        model.regenerateCodexProjectRouteModel()
        model.codexProjectRouteDraft?.targetModel = "claude-sonnet-4-5"
        let routeModel = try XCTUnwrap(model.codexProjectRouteDraft?.routeModel)
        XCTAssertTrue(routeModel.hasPrefix("claude-cp-route-claude-project-"), routeModel)

        await model.saveCodexProjectRouteDraft()

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let env = try XCTUnwrap(object["env"] as? [String: Any])
        XCTAssertEqual(object["model"] as? String, routeModel)
        XCTAssertEqual(env["FOO"] as? String, "bar")
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_MODEL_OPTION"] as? String, routeModel)
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"] as? String, "项目路由：Claude Project")
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"] as? String, "由 Codex Proxy 项目路由转发到绑定账号")
        XCTAssertNil(model.codexProjectRouteDraft)
        XCTAssertEqual(model.settings.codexProjectRoutes.map(\.routeModel), [routeModel])
        XCTAssertEqual(context.service.listBackups(target: .claudeCode).first?.files.map(\.path), [settingsURL.path])
    }

    func testSaveEditedProjectRouteDraftDoesNotAutoWriteProjectConfig() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectDirectory = context.root.appendingPathComponent("edit-project", isDirectory: true)
        let configURL = projectDirectory.appendingPathComponent(".codex/config.toml")
        try Self.write("model = \"cp-route-old\"\napproval_policy = \"never\"\n", to: configURL)
        let originalRule = CodexProjectRouteRule(
            id: "route-edit",
            label: "Edit Project",
            projectPath: projectDirectory.path,
            routeModel: "cp-route-old",
            targetModel: "deepseek-chat",
            proxyAPIKeyID: "local-edit",
            enabled: true,
            createdAt: 1
        )

        let model = Self.makeProjectRouteModel(context: context)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "local-edit", label: "Edit", key: "sk-local-edit")]
        model.settings.codexProjectRoutes = [originalRule]
        model.presentEditCodexProjectRoute(originalRule)
        model.codexProjectRouteDraft?.routeModel = "cp-route-new"
        model.codexProjectRouteDraft?.targetModel = "deepseek-reasoner"

        await model.saveCodexProjectRouteDraft()

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"cp-route-old\""))
        XCTAssertFalse(content.contains("cp-route-new"))
        XCTAssertNil(model.codexProjectRouteDraft)
        XCTAssertEqual(model.settings.codexProjectRoutes.map(\.routeModel), ["cp-route-new"])
    }

    func testSaveNewProjectRouteKeepsDraftWhenProjectConfigWriteFails() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectPathFile = context.root.appendingPathComponent("not-a-directory")
        try Self.write("file", to: projectPathFile)

        let model = Self.makeProjectRouteModel(context: context)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "local-bad", label: "Bad", key: "sk-local-bad")]
        model.presentNewCodexProjectRoute()
        model.codexProjectRouteDraft?.label = "Bad Project"
        model.codexProjectRouteDraft?.projectPath = projectPathFile.path
        model.codexProjectRouteDraft?.routeModel = "cp-route-bad"
        model.codexProjectRouteDraft?.targetModel = "deepseek-reasoner"

        await model.saveCodexProjectRouteDraft()

        XCTAssertNotNil(model.codexProjectRouteDraft)
        XCTAssertEqual(model.settings.codexProjectRoutes.map(\.routeModel), ["cp-route-bad"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectPathFile.appendingPathComponent(".codex/config.toml").path))
        XCTAssertEqual(model.banners.first?.tone, .error)
    }

    func testApplyCodexProjectRouteToProjectWritesProjectConfigAndModelCatalog() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectDirectory = context.root.appendingPathComponent("heavy-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true
        )
        let configURL = projectDirectory.appendingPathComponent(".codex/config.toml")
        let catalogURL = projectDirectory.appendingPathComponent(".codex/codex-proxy-model-catalog.json")
        try Self.write("model = \"old-model\"\napproval_policy = \"never\"\n", to: configURL)

        let model = DesktopAppModel(clientConfigFileService: context.service)
        let rule = CodexProjectRouteRule(
            id: "route-heavy",
            label: "Heavy Project",
            projectPath: projectDirectory.path,
            routeModel: "cp-route-heavy-work",
            targetModel: "deepseek-reasoner",
            proxyAPIKeyID: "local-heavy",
            enabled: true,
            createdAt: 1
        )

        await model.applyCodexProjectRouteToProject(rule)

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"cp-route-heavy-work\""))
        XCTAssertTrue(content.contains("model_catalog_json = \"\(catalogURL.path)\""))
        XCTAssertTrue(content.contains("approval_policy = \"never\""))
        let catalogObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let models = try XCTUnwrap(catalogObject["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["slug"] as? String, "cp-route-heavy-work")
        XCTAssertEqual(models.first?["display_name"] as? String, "Heavy Project")
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(context.service.listBackups(target: .codex).first?.files.map(\.path), [configURL.path, catalogURL.path])
    }

    func testApplyClaudeProjectRouteToProjectWritesSelectedSettingsScope() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectDirectory = context.root.appendingPathComponent("claude-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
        let settingsURL = projectDirectory.appendingPathComponent(".claude/settings.local.json")
        try Self.write(#"{"model":"old","env":{"FOO":"bar"}}"#, to: settingsURL)

        let model = DesktopAppModel(clientConfigFileService: context.service)
        let rule = CodexProjectRouteRule(
            id: "route-claude",
            client: .claudeCode,
            claudeSettingsScope: .local,
            label: "Claude Project",
            projectPath: projectDirectory.path,
            routeModel: "cp-route-claude-work",
            targetModel: "claude-sonnet-4-5",
            proxyAPIKeyID: "local-claude",
            enabled: true,
            createdAt: 1
        )

        await model.applyCodexProjectRouteToProject(rule)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let env = try XCTUnwrap(object["env"] as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "cp-route-claude-work")
        XCTAssertEqual(env["FOO"] as? String, "bar")
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(context.service.listBackups(target: .claudeCode).first?.files.map(\.path), [settingsURL.path])
    }

    func testClearCodexProjectRouteFromProjectRemovesProjectModelAndManagedCatalog() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectDirectory = context.root.appendingPathComponent("heavy-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true
        )
        let configURL = projectDirectory.appendingPathComponent(".codex/config.toml")
        let catalogURL = projectDirectory.appendingPathComponent(".codex/codex-proxy-model-catalog.json")
        try Self.write(
            "model = \"cp-route-heavy-work\"\nmodel_catalog_json = \"\(catalogURL.path)\"\napproval_policy = \"never\"\n",
            to: configURL
        )
        try Self.write(#"{"models":[{"slug":"cp-route-heavy-work"}]}"#, to: catalogURL)

        let model = DesktopAppModel(clientConfigFileService: context.service)
        let rule = CodexProjectRouteRule(
            id: "route-heavy",
            label: "Heavy Project",
            projectPath: projectDirectory.path,
            routeModel: "cp-route-heavy-work",
            targetModel: "deepseek-reasoner",
            proxyAPIKeyID: "local-heavy",
            enabled: true,
            createdAt: 1
        )

        await model.clearCodexProjectRouteFromProject(rule)

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(content.contains("model = \"cp-route-heavy-work\""))
        XCTAssertFalse(content.contains("model_catalog_json"))
        XCTAssertTrue(content.contains("approval_policy = \"never\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(context.service.listBackups(target: .codex).first?.files.map(\.path), [configURL.path, catalogURL.path])
    }

    func testClearClaudeProjectRouteFromProjectRemovesOnlyProjectModel() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectDirectory = context.root.appendingPathComponent("claude-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
        let settingsURL = projectDirectory.appendingPathComponent(".claude/settings.json")
        try Self.write(#"{"model":"cp-route-claude-work","env":{"FOO":"bar"}}"#, to: settingsURL)

        let model = DesktopAppModel(clientConfigFileService: context.service)
        let rule = CodexProjectRouteRule(
            id: "route-claude",
            client: .claudeCode,
            claudeSettingsScope: .shared,
            label: "Claude Project",
            projectPath: projectDirectory.path,
            routeModel: "cp-route-claude-work",
            targetModel: "claude-sonnet-4-5",
            proxyAPIKeyID: "local-claude",
            enabled: true,
            createdAt: 1
        )

        await model.clearCodexProjectRouteFromProject(rule)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let env = try XCTUnwrap(object["env"] as? [String: Any])
        XCTAssertNil(object["model"])
        XCTAssertEqual(env["FOO"] as? String, "bar")
        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertEqual(context.service.listBackups(target: .claudeCode).first?.files.map(\.path), [settingsURL.path])
    }

    func testClientConfigManagerFileChangeKinds() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [
            Self.proxyKey(id: "first", label: "First", key: "sk-local-first"),
            Self.proxyKey(id: "second", label: "Second", key: "sk-local-second"),
        ]
        model.clientConfigManagerTarget = .codex
        let authPath = context.homeDirectory.appendingPathComponent(".codex/auth.json").path

        await model.refreshClientConfigManagerState(showLoading: true)

        XCTAssertEqual(model.clientConfigManagerFileChangeKind(target: .codex, path: authPath), .willCreate)

        await model.applyClientConfigManagerSelection()

        XCTAssertEqual(model.clientConfigManagerFileChangeKind(target: .codex, path: authPath), .unchanged)

        model.clientConfigManagerSelectProxyAPIKey("second")
        await Self.waitForCondition {
            model.clientConfigManagerFileChangeKind(target: .codex, path: authPath) == .willUpdate
        }

        XCTAssertEqual(model.clientConfigManagerFileChangeKind(target: .codex, path: authPath), .willUpdate)
    }

    func testClientConfigManagerFileChangeKindUsesReadFailedForInvalidCurrentFile() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let settingsURL = context.homeDirectory.appendingPathComponent(".claude/settings.json")
        try Self.write("{not-json", to: settingsURL)

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .claudeCode

        await model.refreshClientConfigManagerState(showLoading: true)

        XCTAssertEqual(model.clientConfigManagerFileChangeKind(target: .claudeCode, path: settingsURL.path), .readFailed)
    }

    func testOpenClientConfigBackupViewerShowsDetailDrawer() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()
        let backup = try XCTUnwrap(context.service.listBackups(target: .codex).first)

        model.openClientConfigBackupViewer(backup)
        await Self.waitForCondition {
            model.clientConfigManagerBackupDetail?.record.id == backup.id
        }

        XCTAssertTrue(model.isClientConfigBackupDrawerPresented)
        XCTAssertEqual(model.clientConfigBackupDrawerMode, .detail)
        XCTAssertEqual(model.clientConfigManagerBackupDetail?.record.id, backup.id)
    }

    func testReturningToBackupListKeepsDrawerOpenAndClearsDetail() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()
        let backup = try XCTUnwrap(context.service.listBackups(target: .codex).first)
        model.openClientConfigBackupViewer(backup)

        model.returnToClientConfigBackupList()

        XCTAssertTrue(model.isClientConfigBackupDrawerPresented)
        XCTAssertEqual(model.clientConfigBackupDrawerMode, .list)
        XCTAssertNil(model.clientConfigManagerBackupDetail)
    }

    func testClosingBackupDrawerClearsDetailAndResetsMode() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()
        let backup = try XCTUnwrap(context.service.listBackups(target: .codex).first)
        model.openClientConfigBackupViewer(backup)

        model.dismissClientConfigBackupDrawer()

        XCTAssertFalse(model.isClientConfigBackupDrawerPresented)
        XCTAssertEqual(model.clientConfigBackupDrawerMode, .list)
        XCTAssertNil(model.clientConfigManagerBackupDetail)
    }

    func testRestoreClientConfigBackupRefreshesPreviews() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()
        let backup = try XCTUnwrap(context.service.listBackups(target: .codex).first)
        let revisionAfterApply = model.clientConfigManagerPreviewRevision
        await model.restoreClientConfigBackup(backup)

        XCTAssertGreaterThan(model.clientConfigManagerPreviewRevision, revisionAfterApply)
        XCTAssertEqual(model.clientConfigManagerCurrentPreviews[.codex]?.files.map(\.exists), [false, false])
        XCTAssertEqual(model.clientConfigManagerBackups.filter { $0.target == .codex }.count, 2)
    }

    func testRequestingRestoreWaitsForConfirmationBeforeRestoring() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()
        let backup = try XCTUnwrap(context.service.listBackups(target: .codex).first)

        model.requestClientConfigBackupRestore(backup)

        XCTAssertEqual(model.clientConfigManagerPendingRestoreBackup?.id, backup.id)
        XCTAssertTrue(model.isClientConfigManagerRestoreConfirmationPresented)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.homeDirectory.appendingPathComponent(".codex/auth.json").path))
        XCTAssertTrue(model.banners.contains { $0.title == model.clientConfigManagerRestoreSuccessTitle(for: .codex) } == false)

        await model.confirmClientConfigBackupRestore()

        XCTAssertNil(model.clientConfigManagerPendingRestoreBackup)
        XCTAssertFalse(model.isClientConfigManagerRestoreConfirmationPresented)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.homeDirectory.appendingPathComponent(".codex/auth.json").path))
        XCTAssertEqual(model.banners.first?.title, model.clientConfigManagerRestoreSuccessTitle(for: .codex))
    }

    func testCancellingPendingRestoreLeavesFilesUntouched() async throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let model = DesktopAppModel(clientConfigFileService: context.service)
        model.settings.proxyAPIKeys = [Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-primary")]
        model.clientConfigManagerTarget = .codex

        await model.applyClientConfigManagerSelection()
        let backup = try XCTUnwrap(context.service.listBackups(target: .codex).first)

        model.requestClientConfigBackupRestore(backup)
        model.cancelClientConfigBackupRestore()

        XCTAssertNil(model.clientConfigManagerPendingRestoreBackup)
        XCTAssertFalse(model.isClientConfigManagerRestoreConfirmationPresented)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.homeDirectory.appendingPathComponent(".codex/auth.json").path))
    }
}

private extension ClientConfigManagementTests {
    struct TestContext {
        let root: URL
        let homeDirectory: URL
        let dataDirectory: URL
        let service: ClientConfigFileService

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    static func makeContext() throws -> TestContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        return TestContext(
            root: root,
            homeDirectory: homeDirectory,
            dataDirectory: dataDirectory,
            service: ClientConfigFileService(dataDirectory: dataDirectory, homeDirectoryURL: homeDirectory)
        )
    }

    static func makeProjectRouteModel(context: TestContext) -> DesktopAppModel {
        let admin = AdminAPIClient(
            saveSettingsHandler: { $0 },
            proxyAPIKeyUsageHandler: { _ in ProxyAPIKeyUsageReport(from: 0, to: 0) }
        )
        let daemon = LocalDaemonController(
            applyLaunchConfigurationHandler: { _, _ in .appliedNow },
            statusHandler: {
                LocalServiceStatus(
                    installed: false,
                    running: false,
                    launchctlState: "not-loaded",
                    stdoutPath: "",
                    stderrPath: "",
                    lastErrorSummary: nil
                )
            }
        )
        return DesktopAppModel(
            admin: admin,
            daemon: daemon,
            clientConfigFileService: context.service
        )
    }

    static func proxyKey(id: String, label: String, key: String) -> ProxyAPIKeyRecord {
        ProxyAPIKeyRecord(
            id: id,
            label: label,
            key: key,
            dataSource: .all,
            enabled: true,
            createdAt: 1
        )
    }

    static func write(_ text: String, to url: URL) throws {
        try Helpers.writeFile(url, data: Data(text.utf8))
    }

    static func waitForCondition(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }
}
#endif
