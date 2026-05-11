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
