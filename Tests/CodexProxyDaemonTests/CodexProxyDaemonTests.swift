import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Security
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import XCTest
@testable import CodexProxyCore
@testable import CodexProxyDaemon

private let testGeminiOAuthClientID = "codex-proxy-test-client-id"
private let testGeminiOAuthClientSecret = "codex-proxy-test-client-secret"

final class CodexProxyDaemonTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Self.setGeminiOAuthTestCredentials()
    }

    func testBootstrapSeedsDefaultProxyAPIKeyWithAllDataSource() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        XCTAssertEqual(harness.config.proxyAPIKeys.count, 1)
        XCTAssertEqual(harness.config.primaryProxyAPIKeyRecord?.dataSource, .all)
    }

    func testBootstrapMirrorsAdminAndPrimaryProxySecretsFromBootstrapConfig() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let bootstrapConfig = AppConfig(
            proxyAPIKey: "sk-bootstrap-primary",
            proxyAPIKeys: [
                ProxyAPIKeyRecord(
                    id: "bootstrap-primary",
                    label: "Bootstrap Primary",
                    key: "sk-bootstrap-primary",
                    dataSource: .all,
                    enabled: true,
                    createdAt: 1
                ),
            ],
            primaryProxyAPIKeyID: "bootstrap-primary",
            adminToken: "adm-bootstrap-token"
        ).normalizedModelRoutingConfig()
        try Helpers.writeFile(
            Paths.bootstrapSettingsURL(in: dataDirectory),
            data: try Helpers.encodeJSON(bootstrapConfig, pretty: true)
        )

        let controller = try Self.makeController(dataDirectory: dataDirectory, manageManagedProxyRuntime: false)
        try await controller.bootstrap()

        let saved = try await controller.loadConfig()
        let mirroredAdminToken = try String(contentsOf: Paths.adminTokenURL(in: dataDirectory), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mirroredProxyKey = try String(contentsOf: Paths.proxyAPIKeyURL(in: dataDirectory), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(saved.adminToken, "adm-bootstrap-token")
        XCTAssertEqual(saved.primaryProxyAPIKeyRecord?.key, "sk-bootstrap-primary")
        XCTAssertEqual(mirroredAdminToken, "adm-bootstrap-token")
        XCTAssertEqual(mirroredProxyKey, "sk-bootstrap-primary")
    }

    func testSaveConfigMirrorsAdminAndPrimaryProxySecrets() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var updated = harness.config
        updated.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "updated-primary",
                label: "Updated Primary",
                key: "sk-updated-primary",
                dataSource: .all,
                enabled: true,
                createdAt: 1
            ),
        ]
        updated.primaryProxyAPIKeyID = "updated-primary"
        updated.proxyAPIKey = "sk-updated-primary"
        updated.adminToken = "adm-updated-token"

        let saved = try await harness.controller.saveConfig(updated)
        let mirroredAdminToken = try String(contentsOf: Paths.adminTokenURL(in: harness.dataDirectory), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mirroredProxyKey = try String(contentsOf: Paths.proxyAPIKeyURL(in: harness.dataDirectory), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(saved.adminToken, "adm-updated-token")
        XCTAssertEqual(saved.primaryProxyAPIKeyRecord?.key, "sk-updated-primary")
        XCTAssertEqual(mirroredAdminToken, "adm-updated-token")
        XCTAssertEqual(mirroredProxyKey, "sk-updated-primary")
    }

    func testAuthenticateProxyAPIKeyCarriesAllowedAccountKeys() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "restricted-primary",
                label: "Restricted Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .all,
                allowedAccountKeys: ["acct-openai", "acct-anthropic"],
                enabled: true,
                createdAt: 1
            ),
        ]
        config.primaryProxyAPIKeyID = "restricted-primary"
        _ = try await harness.controller.saveConfig(config)

        let context = try await harness.controller.authenticateProxyAPIKey(harness.config.proxyAPIKey)

        XCTAssertEqual(context.dataSource, .all)
        XCTAssertEqual(context.allowedAccountKeys, ["acct-openai", "acct-anthropic"])
    }

    func testBootstrapAddsAnthropicAccessProxyKeyForExistingAnthropicAccounts() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let store = try SQLiteStore(dataDirectory: dataDirectory, secretStore: secretStore)
        let accountService = AccountService(store: store, secretStore: secretStore)
        let primaryProxyKey = "sk-openai-primary"
        try store.saveConfig(
            AppConfig(
                proxyAPIKey: primaryProxyKey,
                proxyAPIKeys: [
                    ProxyAPIKeyRecord(
                        id: "primary-openai",
                        label: "OpenAI Primary",
                        key: primaryProxyKey,
                        dataSource: .openAI,
                        enabled: true,
                        createdAt: 1
                    ),
                ],
                primaryProxyAPIKeyID: "primary-openai"
            ).normalizedModelRoutingConfig()
        )

        let secretRef = try secretStore.saveAnthropicOAuthSecret(
            AnthropicOAuthSecretBundle(
                accessToken: "anthropic-access",
                refreshToken: "anthropic-refresh",
                expiresAt: Helpers.now() + 3_600
            )
        )
        _ = try await accountService.importAuthJSONAccounts(
            items: [
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(secretRef: secretRef, baseURL: "https://api.anthropic.com"),
                    label: "Anthropic OAuth"
                ),
            ],
            config: AppConfig(
                proxyAPIKey: primaryProxyKey,
                proxyAPIKeys: [
                    ProxyAPIKeyRecord(
                        id: "primary-openai",
                        label: "OpenAI Primary",
                        key: primaryProxyKey,
                        dataSource: .openAI,
                        enabled: true,
                        createdAt: 1
                    ),
                ],
                primaryProxyAPIKeyID: "primary-openai"
            )
        )

        let controller = try Self.makeController(dataDirectory: dataDirectory, manageManagedProxyRuntime: false)
        try await controller.bootstrap()

        let config = try await controller.loadConfig()
        XCTAssertEqual(config.primaryProxyAPIKeyID, "primary-openai")
        XCTAssertEqual(config.proxyAPIKeys.count, 2)
        let anthropicAccess = try XCTUnwrap(config.proxyAPIKeys.first(where: { $0.dataSource == .anthropic }))
        XCTAssertEqual(anthropicAccess.label, AppConfig.defaultAnthropicAccessProxyAPIKeyLabel)
        XCTAssertTrue(anthropicAccess.enabled)
        XCTAssertNotEqual(anthropicAccess.id, config.primaryProxyAPIKeyID)
    }

    func testImportAnthropicAccountAutoAddsAnthropicAccessProxyKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "primary-openai",
                label: "OpenAI Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .openAI,
                enabled: true,
                createdAt: 1
            ),
        ]
        config.primaryProxyAPIKeyID = "primary-openai"
        _ = try await harness.controller.saveConfig(config)

        let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
            AnthropicOAuthSecretBundle(
                accessToken: "anthropic-access",
                refreshToken: "anthropic-refresh",
                expiresAt: Helpers.now() + 3_600
            )
        )
        _ = try await harness.controller.importAuthJSONAccounts([
            .init(
                source: "anthropic-auth.json",
                content: Self.anthropicOAuthAuthJSON(secretRef: secretRef, baseURL: "https://api.anthropic.com"),
                label: "Anthropic OAuth"
            ),
        ])

        let updated = try await harness.controller.loadConfig()
        XCTAssertEqual(updated.proxyAPIKeys.count, 2)
        let anthropicAccess = try XCTUnwrap(updated.proxyAPIKeys.first(where: { $0.dataSource == .anthropic }))
        XCTAssertEqual(anthropicAccess.label, AppConfig.defaultAnthropicAccessProxyAPIKeyLabel)
        XCTAssertTrue(anthropicAccess.enabled)
    }

    func testImportAnthropicAccountDoesNotDuplicateExistingEnabledAnthropicAccessProxyKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "primary-openai",
                label: "OpenAI Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .openAI,
                enabled: true,
                createdAt: 1
            ),
            ProxyAPIKeyRecord(
                id: "existing-anthropic",
                label: "Existing Anthropic Access",
                key: "sk-existing-anthropic",
                dataSource: .anthropic,
                enabled: true,
                createdAt: 2
            ),
        ]
        config.primaryProxyAPIKeyID = "primary-openai"
        _ = try await harness.controller.saveConfig(config)

        let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
            AnthropicOAuthSecretBundle(
                accessToken: "anthropic-access",
                refreshToken: "anthropic-refresh",
                expiresAt: Helpers.now() + 3_600
            )
        )
        _ = try await harness.controller.importAuthJSONAccounts([
            .init(
                source: "anthropic-auth.json",
                content: Self.anthropicOAuthAuthJSON(secretRef: secretRef, baseURL: "https://api.anthropic.com"),
                label: "Anthropic OAuth"
            ),
        ])

        let updated = try await harness.controller.loadConfig()
        let anthropicKeys = updated.proxyAPIKeys.filter { $0.dataSource == .anthropic }
        XCTAssertEqual(anthropicKeys.count, 1)
        XCTAssertEqual(anthropicKeys.first?.id, "existing-anthropic")
        XCTAssertEqual(anthropicKeys.first?.key, "sk-existing-anthropic")
    }

    func testImportAnthropicAccountDoesNotAutoEnableDisabledAnthropicAccessProxyKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "primary-openai",
                label: "OpenAI Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .openAI,
                enabled: true,
                createdAt: 1
            ),
            ProxyAPIKeyRecord(
                id: "disabled-anthropic",
                label: "Disabled Anthropic Access",
                key: "sk-disabled-anthropic",
                dataSource: .anthropic,
                enabled: false,
                createdAt: 2
            ),
        ]
        config.primaryProxyAPIKeyID = "primary-openai"
        _ = try await harness.controller.saveConfig(config)

        let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
            AnthropicOAuthSecretBundle(
                accessToken: "anthropic-access",
                refreshToken: "anthropic-refresh",
                expiresAt: Helpers.now() + 3_600
            )
        )
        _ = try await harness.controller.importAuthJSONAccounts([
            .init(
                source: "anthropic-auth.json",
                content: Self.anthropicOAuthAuthJSON(secretRef: secretRef, baseURL: "https://api.anthropic.com"),
                label: "Anthropic OAuth"
            ),
        ])

        let updated = try await harness.controller.loadConfig()
        let anthropicKeys = updated.proxyAPIKeys.filter { $0.dataSource == .anthropic }
        XCTAssertEqual(anthropicKeys.count, 1)
        XCTAssertEqual(anthropicKeys.first?.id, "disabled-anthropic")
        XCTAssertEqual(anthropicKeys.first?.enabled, false)
        XCTAssertFalse(updated.proxyAPIKeys.contains(where: { $0.enabled && ($0.dataSource == .anthropic || $0.dataSource == .all) }))
    }

    func testHealthAndAdminStatusRoutes() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        try await harness.service.makePublicApplication().test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                XCTAssertTrue(body.contains("\"status\":\"ok\""))
                XCTAssertTrue(body.contains("\"service\":\"codex-proxyd\""))
                XCTAssertTrue(body.contains(#""version":"\#(RuntimeInfo.displayVersion)""#))
            }
        }

        try await harness.service.makeAdminApplication().test(.router) { client in
            try await client.execute(
                uri: "/admin/status",
                method: .get,
                headers: Self.bearerHeaders(harness.config.adminToken)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                XCTAssertTrue(body.contains("\"daemon_version\""))
                XCTAssertTrue(body.contains(#""daemon_version":"\#(RuntimeInfo.displayVersion)""#))
                XCTAssertTrue(body.contains("\"admin_base_url\""))
                XCTAssertTrue(body.contains("\"proxy_test_admin_transport_mode\":\"full\""))
            }
        }
    }

    func testVersionOutputUsesDisplayAndReleaseVersions() {
        XCTAssertEqual(CodexProxyDaemonMain.versionOutput(for: ["--version"]), RuntimeInfo.displayVersion)
        XCTAssertEqual(CodexProxyDaemonMain.versionOutput(for: ["--release-version"]), RuntimeInfo.releaseVersion)
        XCTAssertNil(CodexProxyDaemonMain.versionOutput(for: []))
    }

    func testManagedProxySnapshotReturnsSavedSubscriptionConfigWithoutRuntimeManagement() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false
        )
        try await controller.bootstrap()

        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        _ = try await controller.saveConfig(config)

        let snapshot = try await controller.saveManagedProxyConfig(
            .init(subscriptionURL: "https://example.com/subscription")
        )

        XCTAssertEqual(snapshot.mode, .subscription)
        XCTAssertTrue(snapshot.subscriptionConfigured)
        XCTAssertEqual(snapshot.subscriptionURL, "https://example.com/subscription")
        XCTAssertEqual(snapshot.runtimeState, .stopped)
        XCTAssertFalse(snapshot.controllerReachable)
        XCTAssertTrue(snapshot.lastError?.contains("本地服务未运行") == true)
    }

    func testClearingManagedProxySubscriptionDisablesSubscriptionMode() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false
        )
        try await controller.bootstrap()

        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        _ = try await controller.saveConfig(config)
        _ = try await controller.saveManagedProxyConfig(
            .init(subscriptionURL: "https://example.com/subscription")
        )

        let snapshot = try await controller.saveManagedProxyConfig(.init(subscriptionURL: nil))
        let updatedConfig = try await controller.loadConfig()

        XCTAssertEqual(updatedConfig.outboundProxyMode, .disabled)
        XCTAssertFalse(updatedConfig.managedProxySummary.subscriptionConfigured)
        XCTAssertFalse(snapshot.subscriptionConfigured)
        XCTAssertNil(snapshot.subscriptionURL)
        XCTAssertNil(try controller.secretStore.mihomoSubscriptionURL())
    }

    func testSavingManagedProxyConfigRejectsInvalidSubscriptionURL() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false
        )
        try await controller.bootstrap()

        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        _ = try await controller.saveConfig(config)

        do {
            _ = try await controller.saveManagedProxyConfig(.init(subscriptionURL: "ftp://example.com/subscription"))
            XCTFail("Expected invalid subscription URL to be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP"))
        }

        let updatedConfig = try await controller.loadConfig()
        XCTAssertFalse(updatedConfig.managedProxySummary.subscriptionConfigured)
        XCTAssertNil(try controller.secretStore.mihomoSubscriptionURL())
    }

    func testSavingManagedProxyHealthcheckConfigPersistsOnlyTargetAndHotUpdatesRuntime() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(secretStore: secretStore)
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )
        try await controller.bootstrap()

        var config = try await controller.loadConfig()
        config.outboundProxyMode = .manual
        config.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(config)
        _ = try await controller.saveManagedProxyConfig(
            .init(subscriptionURL: "https://example.com/subscription")
        )
        let reconcileCountBefore = await runtime.snapshotReconciledNodeNameSets().count

        let snapshot = try await controller.saveManagedProxyHealthcheckConfig(
            .init(healthcheckURL: "https://latency.example.com/generate_204")
        )
        let updatedConfig = try await controller.loadConfig()
        let reconcileCountAfter = await runtime.snapshotReconciledNodeNameSets().count

        XCTAssertEqual(updatedConfig.outboundProxyMode, .manual)
        XCTAssertEqual(updatedConfig.managedProxySummary.healthcheckURL, "https://latency.example.com/generate_204")
        XCTAssertEqual(updatedConfig.managedProxySummary.selectedNodeName, "Tokyo")
        XCTAssertEqual(try controller.secretStore.mihomoSubscriptionURL(), "https://example.com/subscription")
        XCTAssertEqual(snapshot.healthcheckURL, "https://latency.example.com/generate_204")
        XCTAssertEqual(snapshot.subscriptionURL, "https://example.com/subscription")
        XCTAssertEqual(snapshot.pinnedNodeName, "Tokyo")
        XCTAssertGreaterThan(reconcileCountAfter, reconcileCountBefore)
    }

    func testSavingBlankManagedProxyHealthcheckConfigRestoresDefaultURL() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false
        )
        try await controller.bootstrap()

        _ = try await controller.saveManagedProxyHealthcheckConfig(
            .init(healthcheckURL: "https://latency.example.com/generate_204")
        )
        let snapshot = try await controller.saveManagedProxyHealthcheckConfig(.init(healthcheckURL: "   "))
        let updatedConfig = try await controller.loadConfig()

        XCTAssertEqual(updatedConfig.managedProxySummary.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertEqual(snapshot.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
    }

    func testManagedProxySnapshotMigratesLegacyGoogleHealthcheckURLWithoutManualResave() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false
        )
        try await controller.bootstrap()

        var rawConfig = AppConfig()
        rawConfig.outboundProxyMode = .manual
        rawConfig.managedProxySummary.subscriptionConfigured = true
        rawConfig.managedProxySummary.healthcheckURL = "https://www.google.com/generate_204"
        try controller.store.saveConfig(rawConfig)

        let loadedConfig = try await controller.loadConfig()
        let snapshot = try await controller.managedProxySnapshot()

        XCTAssertEqual(loadedConfig.managedProxySummary.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
        XCTAssertEqual(snapshot.healthcheckURL, ManagedProxyConfigSummary.defaultHealthcheckURL)
    }

    func testSavingManagedProxyHealthcheckConfigRejectsInvalidURL() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: false
        )
        try await controller.bootstrap()

        do {
            _ = try await controller.saveManagedProxyHealthcheckConfig(
                .init(healthcheckURL: "ftp://invalid.example.com/healthcheck")
            )
            XCTFail("Expected invalid healthcheck URL to be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP"))
        }
    }

    func testManagedProxySnapshotKeepsRuntimeReadyOutsideSubscriptionMode() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(secretStore: secretStore)
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )
        try await controller.bootstrap()

        var config = try await controller.loadConfig()
        config.outboundProxyMode = .manual
        _ = try await controller.saveConfig(config)

        let snapshot = try await controller.saveManagedProxyConfig(
            .init(subscriptionURL: "https://example.com/subscription")
        )

        XCTAssertEqual(snapshot.mode, .manual)
        XCTAssertTrue(snapshot.subscriptionConfigured)
        XCTAssertEqual(snapshot.runtimeState, .running)
        XCTAssertTrue(snapshot.controllerReachable)
        XCTAssertEqual(snapshot.currentNodeName, "Tokyo")
        XCTAssertEqual(
            snapshot.listeners,
            [ManagedProxyListener(kind: .mixedPort, listenHost: "127.0.0.1", port: ManagedProxyRuntime.defaultMixedPort, nodeName: "Tokyo")]
        )
    }

    func testClearingManagedProxySubscriptionStopsRuntimeOutsideSubscriptionMode() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(secretStore: secretStore)
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )
        try await controller.bootstrap()

        var config = try await controller.loadConfig()
        config.outboundProxyMode = .manual
        _ = try await controller.saveConfig(config)
        _ = try await controller.saveManagedProxyConfig(
            .init(subscriptionURL: "https://example.com/subscription")
        )

        let snapshot = try await controller.saveManagedProxyConfig(.init(subscriptionURL: nil))

        XCTAssertEqual(snapshot.mode, .manual)
        XCTAssertFalse(snapshot.subscriptionConfigured)
        XCTAssertEqual(snapshot.runtimeState, .stopped)
        XCTAssertFalse(snapshot.controllerReachable)
        XCTAssertTrue(snapshot.listeners.isEmpty)
    }

    func testManagedProxyCurrentNodeRouteSwitchesCurrentWithoutChangingPinnedDefault() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )
        let service = DaemonHTTPService(controller: controller, publicHost: "127.0.0.1", publicPort: 8787, adminPort: 8788)

        try await controller.bootstrap()
        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        let savedConfig = try await controller.saveConfig(config)

        let response = await service.handle(
            Self.makeAdminRequest(
                method: "POST",
                path: "/admin/proxy/subscription/current-node",
                body: #"{"name":"Seoul"}"#,
                adminToken: savedConfig.adminToken
            ),
            kind: .admin
        )
        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

        let snapshot = try Helpers.readJSON(ManagedProxySnapshot.self, from: body)
        let updatedConfig = try await controller.loadConfig()
        let selectedNodeNames = await runtime.snapshotSelectedNodeNames()

        XCTAssertEqual(snapshot.currentNodeName, "Seoul")
        XCTAssertEqual(snapshot.pinnedNodeName, "Tokyo")
        XCTAssertEqual(updatedConfig.managedProxySummary.selectedNodeName, "Tokyo")
        XCTAssertEqual(selectedNodeNames, ["Seoul"])
    }

    func testManagedProxyPinnedNodeRoutePersistsPinnedDefaultWithoutSwitchingCurrent() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )
        let service = DaemonHTTPService(controller: controller, publicHost: "127.0.0.1", publicPort: 8787, adminPort: 8788)

        try await controller.bootstrap()
        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        let savedConfig = try await controller.saveConfig(config)

        let response = await service.handle(
            Self.makeAdminRequest(
                method: "PATCH",
                path: "/admin/proxy/subscription/pinned-node",
                body: #"{"name":"Seoul"}"#,
                adminToken: savedConfig.adminToken
            ),
            kind: .admin
        )
        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

        let snapshot = try Helpers.readJSON(ManagedProxySnapshot.self, from: body)
        let updatedConfig = try await controller.loadConfig()
        let selectedNodeNames = await runtime.snapshotSelectedNodeNames()

        XCTAssertEqual(snapshot.currentNodeName, "Tokyo")
        XCTAssertEqual(snapshot.pinnedNodeName, "Seoul")
        XCTAssertEqual(updatedConfig.managedProxySummary.selectedNodeName, "Seoul")
        XCTAssertTrue(selectedNodeNames.isEmpty)
    }

    #if os(macOS)
    func testSavingManagedProxyConfigSucceedsWhenControllerSecretKeychainReadFails() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let keychain = TestKeychainAdapter(
            readStatusByAccount: ["mihomo-controller-secret": errSecAuthFailed],
            addStatusByAccount: ["mihomo-controller-secret": errSecAuthFailed]
        )
        let secretStore = SecretStore(
            dataDirectory: dataDirectory,
            keychainAdapter: keychain,
            keychainEnabledOverride: true
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: ManagedProxyRuntimeStub(secretStore: secretStore)
        )
        try await controller.bootstrap()

        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        _ = try await controller.saveConfig(config)

        let snapshot = try await controller.saveManagedProxyConfig(
            .init(subscriptionURL: "https://example.com/subscription")
        )
        let persistedSecret = try String(
            contentsOf: Paths.mihomoControllerSecretURL(in: dataDirectory),
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(snapshot.mode, .subscription)
        XCTAssertTrue(snapshot.subscriptionConfigured)
        XCTAssertEqual(snapshot.subscriptionURL, "https://example.com/subscription")
        XCTAssertEqual(snapshot.runtimeState, .running)
        XCTAssertTrue(snapshot.controllerReachable)
        XCTAssertEqual(snapshot.currentNodeName, "Tokyo")
        XCTAssertFalse(persistedSecret.isEmpty)
        XCTAssertTrue(keychain.readAttempts().contains("mihomo-controller-secret"))
    }
    #endif

    func testModelsRouteRequiresProxyKeyAndReturnsModels() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        try await harness.service.makePublicApplication().test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }

            try await client.execute(
                uri: "/v1/models",
                method: .get,
                headers: Self.proxyHeaders(harness.config.proxyAPIKey)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                XCTAssertTrue(body.contains("\"object\":\"list\""))
                XCTAssertTrue(body.contains("gpt-5.5"))
            }
        }
    }

    func testAdminProxyTestModelsRouteReturnsSeparatedFamilies() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        try await harness.service.makeAdminApplication().test(.router) { client in
            try await client.execute(
                uri: "/admin/proxy-test/models",
                method: .get,
                headers: Self.bearerHeaders(harness.config.adminToken)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                let catalog = try Helpers.readJSON(ProxyTestModelCatalog.self, from: Data(body.utf8))

                XCTAssertEqual(catalog.chatCompletions.family, .gpt)
                XCTAssertEqual(catalog.responses.family, .gpt)
                XCTAssertEqual(catalog.anthropicMessages.family, .anthropic)
                XCTAssertEqual(catalog.chatCompletions.models, ProxyTranscoder.supportedModels)
                XCTAssertTrue(catalog.anthropicMessages.models.contains("claude-sonnet-4-6"))
                XCTAssertFalse(catalog.anthropicMessages.models.contains("gpt-5.4"))
            }
        }
    }

    func testAdminProxyTestModelsRouteUsesPinnedAccountDiscoveredModels() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            listedModels: ["gpt-5.5"]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Dynamic OpenAI",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dynamic-models",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()
            let encodedAccountKey = try XCTUnwrap(
                added.accountKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            )

            try await harness.service.makeAdminApplication().test(.router) { client in
                try await client.execute(
                    uri: "/admin/proxy-test/models?selected_account_key=\(encodedAccountKey)",
                    method: .get,
                    headers: Self.bearerHeaders(harness.config.adminToken)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let body = Self.string(from: response.body)
                    let catalog = try Helpers.readJSON(ProxyTestModelCatalog.self, from: Data(body.utf8))

                    XCTAssertEqual(catalog.chatCompletions.models, ["gpt-5.5"])
                    XCTAssertEqual(catalog.responses.models, ["gpt-5.5"])
                    XCTAssertEqual(catalog.chatCompletions.defaultModel, "gpt-5.5")
                    XCTAssertEqual(catalog.responses.defaultModel, "gpt-5.5")
                    XCTAssertEqual(
                        catalog.anthropicMessages.models,
                        ProxyTestModelCatalog.defaultCatalog.anthropicMessages.models
                    )
                }
            }

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits - baseline.modelsHits, 1)
        }
    }

    func testGenericManualAPIKeyRootBaseURLDoesNotAppendV1ForRuntimeRequest() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            routePrefix: "",
            listedModels: ["gpt-5.4"]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "DeepSeek Root",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-deepseek-root",
                    enabled: true
                )
            )
            XCTAssertNil(added.usageError)
            XCTAssertEqual(added.upstreamBaseURL, baseURL)

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"gpt-5.4","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: added.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains(#""object":"chat.completion""#))

            let snapshot = await probe.snapshot()
            XCTAssertGreaterThanOrEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.responsesHits, 2)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer sk-deepseek-root")

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first(where: { $0.accountKey == added.accountKey }))
            XCTAssertEqual(entry.endpoint, "/v1/chat/completions")
            XCTAssertEqual(entry.upstreamURL, "\(baseURL)/responses")
            XCTAssertFalse(entry.upstreamURL?.contains("/v1/") == true)
        }
    }

    func testGenericManualAPIKeyChatCompletionsAdapterUsesChatUpstreamWithoutV1() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            routePrefix: "",
            listedModels: ["gpt-5.4"],
            responsesAvailable: false
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Chat Only Generic",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    baseURLMode: .exactAPIPrefix,
                    upstreamAdapter: .chatCompletions,
                    apiKey: "sk-chat-only",
                    enabled: true
                )
            )
            XCTAssertNil(added.usageError)
            let refreshed = try await harness.controller.refreshAccountUsage(id: added.id)
            XCTAssertNil(refreshed.usageError)

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"gpt-5.4","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: added.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains(#""object":"chat.completion""#))

            let snapshot = await probe.snapshot()
            XCTAssertGreaterThanOrEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.responsesHits, 0)
            XCTAssertEqual(snapshot.chatHits, 3)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer sk-chat-only")

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first(where: { $0.accountKey == added.accountKey }))
            XCTAssertEqual(entry.endpoint, "/v1/chat/completions")
            XCTAssertEqual(entry.upstreamURL, "\(baseURL)/chat/completions")
            XCTAssertFalse(entry.upstreamURL?.contains("/v1/") == true)
        }
    }

    func testGenericChatCompletionsDoesNotRestoreDeepSeekReasoningCache() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            routePrefix: "",
            listedModels: ["deepseek-chat"],
            chatCompletionsReasoningContent: "cached generic thinking",
            requireReasoningContentForAssistantToolCallHistory: true,
            responsesAvailable: false,
            toolTurnMode: true
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Generic Chat",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    baseURLMode: .exactAPIPrefix,
                    upstreamAdapter: .chatCompletions,
                    apiKey: "sk-generic-chat",
                    enabled: true
                )
            )

            let headers = [
                ProxyHeaderName.testAccountKey: added.accountKey,
                "conversation_id": "generic-reasoning-session",
            ]
            _ = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"deepseek-chat","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )
            let firstSnapshot = await probe.snapshot()
            let firstBody = try XCTUnwrap(firstSnapshot.chatRequestBodies.last)
            XCTAssertFalse(firstBody.contains(#""thinking""#), firstBody)

            let second = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"""
                    {"model":"deepseek-chat","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_cli_tool_turn_1","type":"function","function":{"name":"run_command","arguments":"{\"command\":\"ls\"}"}}]},{"role":"tool","tool_call_id":"call_cli_tool_turn_1","content":"file.txt"},{"role":"user","content":"continue"}],"stream":false}
                    """#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )

            let secondBody = try await Self.data(from: second.body)
            XCTAssertFalse((200..<300).contains(second.statusCode), Self.string(from: secondBody))
            let snapshot = await probe.snapshot()
            let followUpBody = try XCTUnwrap(snapshot.chatRequestBodies.last)
            XCTAssertFalse(followUpBody.contains(#""reasoning_content":"cached generic thinking""#), followUpBody)
            XCTAssertFalse(followUpBody.contains(#""thinking""#), followUpBody)
        }
    }

    func testGenericChatCompletionsThinkingCompatibilityRestoresCachedToolCallReasoning() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            routePrefix: "",
            listedModels: ["deepseek-chat"],
            chatCompletionsReasoningContent: "cached generic thinking",
            requireReasoningContentForAssistantToolCallHistory: true,
            responsesAvailable: false,
            toolTurnMode: true
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Generic Chat Thinking",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    baseURLMode: .exactAPIPrefix,
                    upstreamAdapter: .chatCompletions,
                    upstreamThinkingCompatibility: .enabled,
                    apiKey: "sk-generic-chat-thinking",
                    enabled: true
                )
            )

            let headers = [
                ProxyHeaderName.testAccountKey: added.accountKey,
                "conversation_id": "generic-reasoning-session-enabled",
            ]
            let first = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"deepseek-chat","messages":[{"role":"user","content":"hello"}],"stream":false,"logprobs":true,"top_logprobs":2}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )
            let firstResponseBody = try await Self.data(from: first.body)
            XCTAssertEqual(first.statusCode, 200, Self.string(from: firstResponseBody))

            let firstSnapshot = await probe.snapshot()
            let firstBody = try XCTUnwrap(firstSnapshot.chatRequestBodies.last)
            let firstPayload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(firstBody.utf8)) as? [String: Any]
            )
            XCTAssertEqual((firstPayload["thinking"] as? [String: String])?["type"], "enabled")
            XCTAssertNil(firstPayload["logprobs"])
            XCTAssertNil(firstPayload["top_logprobs"])

            let second = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"""
                    {"model":"deepseek-chat","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_cli_tool_turn_1","type":"function","function":{"name":"run_command","arguments":"{\"command\":\"ls\"}"}}]},{"role":"tool","tool_call_id":"call_cli_tool_turn_1","content":"file.txt"},{"role":"user","content":"continue"}],"stream":false}
                    """#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )

            let secondBody = try await Self.data(from: second.body)
            XCTAssertEqual(second.statusCode, 200, Self.string(from: secondBody))
            let snapshot = await probe.snapshot()
            let followUpBody = try XCTUnwrap(snapshot.chatRequestBodies.last)
            XCTAssertTrue(followUpBody.contains(#""reasoning_content":"cached generic thinking""#), followUpBody)
        }
    }

    func testGenericChatCompletionsThinkingCompatibilityStoresStreamingToolCallReasoning() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            routePrefix: "",
            listedModels: ["deepseek-chat"],
            chatCompletionsReasoningContent: "cached stream thinking",
            requireReasoningContentForAssistantToolCallHistory: true,
            responsesAvailable: false,
            toolTurnMode: true
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Generic Chat Thinking Stream",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    baseURLMode: .exactAPIPrefix,
                    upstreamAdapter: .chatCompletions,
                    upstreamThinkingCompatibility: .enabled,
                    apiKey: "sk-generic-chat-thinking-stream",
                    enabled: true
                )
            )

            let headers = [
                ProxyHeaderName.testAccountKey: added.accountKey,
                "conversation_id": "generic-reasoning-session-stream",
            ]
            let first = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"deepseek-chat","messages":[{"role":"user","content":"hello"}],"stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )
            let firstBody = try await Self.data(from: first.body)
            XCTAssertEqual(first.statusCode, 200, Self.string(from: firstBody))

            let second = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"""
                    {"model":"deepseek-chat","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_cli_tool_turn_1","type":"function","function":{"name":"run_command","arguments":"{\"command\":\"ls\"}"}}]},{"role":"tool","tool_call_id":"call_cli_tool_turn_1","content":"file.txt"},{"role":"user","content":"continue"}],"stream":false}
                    """#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )

            let secondBody = try await Self.data(from: second.body)
            XCTAssertEqual(second.statusCode, 200, Self.string(from: secondBody))
            let snapshot = await probe.snapshot()
            let followUpBody = try XCTUnwrap(snapshot.chatRequestBodies.last)
            XCTAssertTrue(followUpBody.contains(#""reasoning_content":"cached stream thinking""#), followUpBody)
        }
    }

    func testGenericChatCompletionsThinkingCompatibilityFailsLocallyWhenCacheMissing() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            routePrefix: "",
            listedModels: ["deepseek-chat"],
            requireReasoningContentForAssistantToolCallHistory: true,
            responsesAvailable: false,
            toolTurnMode: true
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Generic Chat Thinking Missing Cache",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    baseURLMode: .exactAPIPrefix,
                    upstreamAdapter: .chatCompletions,
                    upstreamThinkingCompatibility: .enabled,
                    apiKey: "sk-generic-chat-thinking-missing",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"""
                    {"model":"deepseek-chat","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_cli_tool_turn_1","type":"function","function":{"name":"run_command","arguments":"{\"command\":\"ls\"}"}}]},{"role":"tool","tool_call_id":"call_cli_tool_turn_1","content":"file.txt"},{"role":"user","content":"continue"}],"stream":false}
                    """#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        ProxyHeaderName.testAccountKey: added.accountKey,
                        "conversation_id": "generic-reasoning-session-missing-cache",
                    ]
                ),
                kind: .publicAPI
            )

            let body = try await Self.data(from: response.body)
            XCTAssertFalse((200..<300).contains(response.statusCode), Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("Thinking compatibility is enabled"), Self.string(from: body))
            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits, baseline.chatHits)
        }
    }

    func testGenericManualAPIKeyDefaultResponsesAdapterRecordsUsageErrorForChatOnlyUpstream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            routePrefix: "",
            listedModels: ["gpt-5.4"],
            responsesAvailable: false
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Default Responses Generic",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-default-responses",
                    enabled: true
                )
            )
            XCTAssertTrue(added.usageError?.contains("responses") == true, added.usageError ?? "")

            let snapshot = await probe.snapshot()
            XCTAssertGreaterThanOrEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.responsesHits, 1)
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testAdminProxyTestModelsRouteWithoutPinnedAccountStaysCuratedEvenWithDynamicAccounts() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            listedModels: ["gpt-5.5"]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Dynamic OpenAI",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dynamic-models",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            try await harness.service.makeAdminApplication().test(.router) { client in
                try await client.execute(
                    uri: "/admin/proxy-test/models",
                    method: .get,
                    headers: Self.bearerHeaders(harness.config.adminToken)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let body = Self.string(from: response.body)
                    let catalog = try Helpers.readJSON(ProxyTestModelCatalog.self, from: Data(body.utf8))
                    XCTAssertEqual(catalog, .defaultCatalog)
                }
            }

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, baseline.modelsHits)
        }
    }

    func testModelsRouteReturnsDynamicModelsForRoutableAccounts() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            listedModels: ["gpt-5.5"]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Dynamic OpenAI",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dynamic-models",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            try await harness.service.makePublicApplication().test(.router) { client in
                try await client.execute(
                    uri: "/v1/models",
                    method: .get,
                    headers: Self.proxyHeaders(harness.config.proxyAPIKey)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let body = Self.string(from: response.body)
                    let listedModels = try Self.listedModelIDs(from: Data(body.utf8))
                    XCTAssertEqual(listedModels, ["gpt-5.5"])
                }
            }

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits - baseline.modelsHits, 1)
        }
    }

    func testModelsRouteHonorsPinnedSelectedAccountHeader() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let firstProbe = GenericOpenAICompatibilityProbe()
        let secondProbe = GenericOpenAICompatibilityProbe()
        let firstUpstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: firstProbe,
            listedModels: ["gpt-5.5"]
        )
        let secondUpstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: secondProbe,
            listedModels: ["gpt-5.6"]
        )
        try await firstUpstream.test(.ahc()) { firstClient in
            try await secondUpstream.test(.ahc()) { secondClient in
                let firstAccount = try await harness.controller.manualAddAPIKeyAccount(
                    ManualAPIKeyAccountInput(
                        label: "First Dynamic OpenAI",
                        providerPreset: .genericOpenAICompatible,
                        baseURL: "http://localhost:\(firstClient.port ?? 0)/v1",
                        apiKey: "sk-dynamic-first",
                        enabled: true
                    )
                )
                let firstBaseline = await firstProbe.snapshot()
                _ = try await harness.controller.manualAddAPIKeyAccount(
                    ManualAPIKeyAccountInput(
                        label: "Second Dynamic OpenAI",
                        providerPreset: .genericOpenAICompatible,
                        baseURL: "http://localhost:\(secondClient.port ?? 0)/v1",
                        apiKey: "sk-dynamic-second",
                        enabled: true
                    )
                )
                let secondBaseline = await secondProbe.snapshot()

                try await harness.service.makePublicApplication().test(.router) { client in
                    try await client.execute(
                    uri: "/v1/models",
                    method: .get,
                    headers: {
                        var headers = Self.proxyHeaders(harness.config.proxyAPIKey)
                        headers.append(.init(name: .init(ProxyHeaderName.testAccountKey)!, value: firstAccount.accountKey))
                        return headers
                    }()
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let body = Self.string(from: response.body)
                    let listedModels = try Self.listedModelIDs(from: Data(body.utf8))
                    XCTAssertEqual(listedModels, ["gpt-5.5"])
                }

                let firstSnapshot = await firstProbe.snapshot()
                let secondSnapshot = await secondProbe.snapshot()
                XCTAssertEqual(firstSnapshot.modelsHits - firstBaseline.modelsHits, 1)
                XCTAssertEqual(secondSnapshot.modelsHits - secondBaseline.modelsHits, 0)
            }
        }
    }
    }

    func testModelsRouteCachesDiscoveredModelsWithinTTL() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            listedModels: ["gpt-5.5"]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Dynamic OpenAI",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dynamic-models",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            try await harness.service.makePublicApplication().test(.router) { client in
                for _ in 0..<2 {
                    try await client.execute(
                        uri: "/v1/models",
                        method: .get,
                        headers: Self.proxyHeaders(harness.config.proxyAPIKey)
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }
            }

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits - baseline.modelsHits, 1)
        }
    }

    func testModelsRouteFallsBackToCuratedModelsWhenProbeFailsUnpinned() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            modelsStatus: .internalServerError
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Failing Dynamic OpenAI",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dynamic-models",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            try await harness.service.makePublicApplication().test(.router) { client in
                try await client.execute(
                    uri: "/v1/models",
                    method: .get,
                    headers: Self.proxyHeaders(harness.config.proxyAPIKey)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let body = Self.string(from: response.body)
                    let listedModels = try Self.listedModelIDs(from: Data(body.utf8))
                    XCTAssertTrue(listedModels.contains("gpt-5.4"))
                }
            }

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits - baseline.modelsHits, 1)
        }
    }

    func testAdminOAuthPrepareReturnsOfficialPreparedLogin() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }
        defer {
            Task {
                if let listener = await harness.controller.runtimeState.takeOAuthCallbackListener() {
                    await listener.stop()
                }
                await harness.controller.runtimeState.setPendingOAuthLogin(nil)
            }
        }

        try await harness.service.makeAdminApplication().test(.router) { client in
            try await client.execute(
                uri: "/admin/oauth/prepare",
                method: .post,
                headers: Self.bearerHeaders(harness.config.adminToken)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                let prepared = try Helpers.readJSON(PreparedOAuthLogin.self, from: Data(body.utf8))
                XCTAssertEqual(prepared.redirectURI, "http://localhost:1455/auth/callback")

                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems: [URLQueryItem] = components.queryItems ?? []
                let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

                XCTAssertEqual(items["client_id"], AuthService.defaultOAuthClientID)
                XCTAssertEqual(items["redirect_uri"], prepared.redirectURI)
            }
        }
    }

    func testAdminOAuthPrepareFallsBackWhenDefaultPortBusy() async throws {
        let occupied = try OAuthCallbackListener.bind(preferredPort: AuthService.defaultOAuthRedirectPort)
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        try await harness.service.makeAdminApplication().test(.router) { client in
            try await client.execute(
                uri: "/admin/oauth/prepare",
                method: .post,
                headers: Self.bearerHeaders(harness.config.adminToken)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                let prepared = try Helpers.readJSON(PreparedOAuthLogin.self, from: Data(body.utf8))

                XCTAssertNotEqual(prepared.redirectURI, "http://localhost:1455/auth/callback")
                XCTAssertTrue(prepared.redirectURI.hasPrefix("http://localhost:"))
                XCTAssertTrue(prepared.redirectURI.hasSuffix("/auth/callback"))

                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems: [URLQueryItem] = components.queryItems ?? []
                let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(items["redirect_uri"], prepared.redirectURI)
            }
        }

        if let listener = await harness.controller.runtimeState.takeOAuthCallbackListener() {
            await listener.stop()
        }
        await harness.controller.runtimeState.setPendingOAuthLogin(nil)
        await occupied.stop()
    }

    func testAdminAnthropicOAuthPrepareRouteReturnsAnthropicPreparedLogin() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }
        defer {
            Task {
                if let listener = await harness.controller.runtimeState.takeOAuthCallbackListener() {
                    await listener.stop()
                }
                await harness.controller.runtimeState.setPendingOAuthLogin(nil)
            }
        }

        try await harness.service.makeAdminApplication().test(.router) { client in
            try await client.execute(
                uri: "/admin/oauth/anthropic/prepare",
                method: .post,
                headers: Self.bearerHeaders(harness.config.adminToken)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                let prepared = try Helpers.readJSON(PreparedOAuthLogin.self, from: Data(body.utf8))

                XCTAssertEqual(prepared.providerFamily, .anthropic)
                XCTAssertTrue(prepared.redirectURI.hasPrefix("http://localhost:"))
                XCTAssertTrue(prepared.redirectURI.hasSuffix(AuthService.anthropicOAuthCallbackPath))
                XCTAssertTrue(prepared.authURL.contains(AnthropicAuthService.defaultClaudeAIAuthorizeURL))
            }
        }
    }

    func testAnthropicOAuthBrowserCallbackImportsAccountOnStandardRedirectPath() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            try await Self.withAnthropicOAuthEnvironment(baseURL: "http://localhost:\(upstreamClient.port ?? 0)") {
                let prepared = try await harness.controller.prepareOAuthLogin(providerFamily: .anthropic)
                XCTAssertTrue(prepared.redirectURI.hasSuffix(AuthService.anthropicOAuthCallbackPath))

                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let state = try XCTUnwrap(queryItems["state"])

                let (statusCode, html) = try await Self.fetchLocalHTML(
                    from: "\(prepared.redirectURI)?code=browser-success&state=\(state)",
                    acceptLanguage: "zh-CN,zh;q=0.9"
                )

                XCTAssertEqual(statusCode, 200)
                XCTAssertTrue(html.contains("授权完成"))
                XCTAssertTrue(html.contains("OAuth"))

                let accounts = try await harness.controller.listAccounts()
                let imported = try XCTUnwrap(accounts.first(where: { $0.providerFamily == .anthropic }))
                XCTAssertEqual(imported.authMode, .anthropicSubscriptionOAuth)
                XCTAssertEqual(imported.label, "claude@example.com")
                let pendingAfterImport = await harness.controller.runtimeState.pendingOAuthLogin
                XCTAssertNil(pendingAfterImport)
            }
        }
    }

    func testAnthropicOAuthManualRetryKeepsPendingSessionAfterFailure() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            try await Self.withAnthropicOAuthEnvironment(baseURL: "http://localhost:\(upstreamClient.port ?? 0)") {
                let prepared = try await harness.controller.prepareOAuthLogin(providerFamily: .anthropic)
                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let state = try XCTUnwrap(queryItems["state"])

                do {
                    _ = try await harness.controller.completeOAuthCallback(
                        providerFamily: .anthropic,
                        url: "\(prepared.redirectURI)?code=bad-code&state=\(state)"
                    )
                    XCTFail("Expected first completion attempt to fail")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Anthropic OAuth token 交换失败"))
                }

                let pendingAfterFailure = await harness.controller.runtimeState.pendingOAuthLogin
                XCTAssertEqual(pendingAfterFailure?.state, state)

                let imported = try await harness.controller.completeOAuthCallback(
                    providerFamily: .anthropic,
                    url: "\(prepared.redirectURI)?code=retry-success&state=\(state)"
                )

                XCTAssertEqual(imported.authMode, .anthropicSubscriptionOAuth)
                XCTAssertEqual(imported.label, "claude@example.com")
                let pendingAfterRetry = await harness.controller.runtimeState.pendingOAuthLogin
                XCTAssertNil(pendingAfterRetry)
            }
        }
    }

    func testAnthropicOAuthRefreshUsesJSONRequestFormatAndUpdatesSecretBundle() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access-stale",
                    refreshToken: "anthropic-refresh-seed",
                    expiresAt: Helpers.now() - 60,
                    tokenType: "Bearer",
                    scope: "user:profile user:inference"
                )
            )
            let authJSON = Self.anthropicOAuthAuthJSON(
                secretRef: secretRef,
                baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
            )

            try await Self.withAnthropicOAuthEnvironment(baseURL: "http://localhost:\(upstreamClient.port ?? 0)") {
                let refreshed = try await AnthropicAuthService.refreshAnthropicAuth(
                    authJSON,
                    config: AppConfig(),
                    secretStore: harness.controller.secretStore
                )
                let extracted = try AuthService.extractAuth(from: refreshed, secretStore: harness.controller.secretStore)
                let bundle = try harness.controller.secretStore.loadAnthropicOAuthSecret(ref: secretRef)

                XCTAssertEqual(extracted.accessToken, "anthropic-access-refresh-anthropic-refresh-seed")
                XCTAssertEqual(bundle.accessToken, "anthropic-access-refresh-anthropic-refresh-seed")
                XCTAssertEqual(bundle.refreshToken, "anthropic-refresh-rotated-anthropic-refresh-seed")
                XCTAssertEqual(bundle.scope, "user:profile user:inference")
            }
        }
    }

    func testResponsesProxyPinnedAnthropicOAuthScopeErrorReturnsReloginGuidance() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access-missing-scope",
                    refreshToken: "anthropic-refresh-seed",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: "org:create_api_key user:profile"
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        scope: "org:create_api_key user:profile",
                        oauthRequestedScope: nil,
                        oauthAuthorizeURL: nil,
                        oauthLoginSource: nil
                    ),
                    label: "Anthropic OAuth"
                )
            ])
            let accounts = try await harness.controller.listAccounts()
            let account = try XCTUnwrap(accounts.first(where: { $0.authMode == .anthropicSubscriptionOAuth }))

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: account.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(text.contains(AnthropicAuthService.reauthorizationRequiredMessage))
            XCTAssertFalse(text.contains("does not meet scope requirement"))
        }
    }

    func testAnthropicOAuthPrepareReplacesPreviousPendingSession() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }
        defer {
            Task {
                if let listener = await harness.controller.runtimeState.takeOAuthCallbackListener() {
                    await listener.stop()
                }
                await harness.controller.runtimeState.setPendingOAuthLogin(nil)
            }
        }

        let first = try await harness.controller.prepareOAuthLogin(providerFamily: .anthropic)
        let firstComponents = try XCTUnwrap(URLComponents(string: first.authURL))
        let firstItems = Dictionary(uniqueKeysWithValues: (firstComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let firstState = try XCTUnwrap(firstItems["state"])

        _ = try await harness.controller.prepareOAuthLogin(providerFamily: .anthropic)

        do {
            _ = try await harness.controller.completeOAuthCallback(
                providerFamily: .anthropic,
                url: "\(first.redirectURI)?code=stale-code&state=\(firstState)"
            )
            XCTFail("Expected stale callback to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Anthropic OAuth state 不匹配"))
        }
    }

    func testAdminGeminiOAuthPrepareRouteReturnsGeminiPreparedLogin() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }
        defer {
            Task {
                if let listener = await harness.controller.runtimeState.takeOAuthCallbackListener() {
                    await listener.stop()
                }
                await harness.controller.runtimeState.setPendingOAuthLogin(nil)
            }
        }

        try await harness.service.makeAdminApplication().test(.router) { client in
            try await client.execute(
                uri: "/admin/oauth/gemini/prepare",
                method: .post,
                headers: Self.bearerHeaders(harness.config.adminToken)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = Self.string(from: response.body)
                let prepared = try Helpers.readJSON(PreparedOAuthLogin.self, from: Data(body.utf8))

                XCTAssertEqual(prepared.providerFamily, .gemini)
                XCTAssertTrue(prepared.redirectURI.hasPrefix("http://localhost:"))
                XCTAssertTrue(prepared.redirectURI.hasSuffix(AuthService.geminiOAuthCallbackPath))

                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(queryItems["client_id"], GeminiAuthService.defaultOAuthClientID)
                XCTAssertEqual(queryItems["scope"], GeminiAuthService.defaultOAuthScopes)
                XCTAssertEqual(queryItems["redirect_uri"], prepared.redirectURI)
                XCTAssertEqual(queryItems["code_challenge_method"], "S256")
                XCTAssertEqual(queryItems["access_type"], "offline")
                XCTAssertEqual(queryItems["prompt"], "consent")
                XCTAssertFalse((queryItems["state"] ?? "").isEmpty)
            }
        }
    }

    func testGeminiOAuthBrowserCallbackAutoOnboardsPersonalTier() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(
            probe: probe,
            loadCodeAssistResponses: [
                """
                {
                  "allowedTiers": [
                    {
                      "id": "personal_free",
                      "name": "Personal Free",
                      "isDefault": true,
                      "userDefinedCloudaicompanionProject": false
                    }
                  ]
                }
                """,
                """
                {
                  "currentTier": {
                    "id": "personal_free",
                    "name": "Personal Free",
                    "userDefinedCloudaicompanionProject": false
                  },
                  "allowedTiers": [
                    {
                      "id": "personal_free",
                      "name": "Personal Free",
                      "isDefault": true,
                      "userDefinedCloudaicompanionProject": false
                    }
                  ],
                  "cloudaicompanionProject": "gemini-personal-project"
                }
                """
            ],
            onboardResponse: #"{"name":"operations/onboard-personal-free"}"#,
            operationResponses: [
                #"{"name":"operations/onboard-personal-free","done":true,"response":{"cloudaicompanionProject":{"id":"gemini-personal-project"}}}"#
            ]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            try await Self.withGeminiOAuthEnvironment(baseURL: "http://localhost:\(upstreamClient.port ?? 0)") {
                let prepared = try await harness.controller.prepareOAuthLogin(providerFamily: .gemini)
                let components = try XCTUnwrap(URLComponents(string: prepared.authURL))
                let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let state = try XCTUnwrap(queryItems["state"])

                let imported = try await harness.controller.completeOAuthCallback(
                    providerFamily: .gemini,
                    url: "\(prepared.redirectURI)?code=browser-success&state=\(state)"
                )

                XCTAssertEqual(imported.authMode, .geminiOAuth)
                XCTAssertEqual(imported.planType, "free")
                XCTAssertEqual(imported.label, "gemini@example.com")
                XCTAssertEqual(imported.email, "gemini@example.com")

                let accounts = try await harness.controller.listAccounts()
                let stored = try XCTUnwrap(accounts.first(where: { $0.id == imported.id }))
                XCTAssertEqual(stored.planType, "free")

                let snapshot = await probe.snapshot()
                XCTAssertEqual(snapshot.loadCodeAssistHits, 2)
                XCTAssertEqual(snapshot.onboardUserHits, 1)
                XCTAssertEqual(snapshot.operationPollHits, 1)
            }
        }
    }

    func testGeminiOAuthPublicGenerateContentAndCountTokensUseNativeGeminiUpstream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let generate = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-native",
                    ]
                ),
                kind: .publicAPI
            )
            let generateBody = try await Self.data(from: generate.body)
            let generateText = Self.string(from: generateBody)
            XCTAssertEqual(generate.statusCode, 200, generateText)
            XCTAssertTrue(generateText.contains("Google AI Pro Route"), generateText)
            XCTAssertTrue(generateText.contains(#""totalTokenCount""#), generateText)

            let count = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:countTokens",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Count me"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-native",
                    ]
                ),
                kind: .publicAPI
            )
            let countBody = try await Self.data(from: count.body)
            let countText = Self.string(from: countBody)
            XCTAssertEqual(count.statusCode, 200, countText)
            XCTAssertTrue(countText.contains(#""totalTokens":11"#), countText)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.generateHits, 1)
            XCTAssertEqual(snapshot.countTokensHits, 1)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer gemini-access-live")
            XCTAssertEqual(snapshot.loadCodeAssistHits, 0)
            XCTAssertTrue(snapshot.generateBodies.first?.contains(#""project":"gemini-project""#) == true)
            XCTAssertTrue(snapshot.generateBodies.first?.contains(#""request""#) == true)
            XCTAssertTrue(snapshot.countTokenBodies.first?.contains(#""contents""#) == true)
        }
    }

    func testGeminiOAuthPublicGenerateContentPropagatesStructuredValidationRequiredError() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(
            probe: probe,
            generateContentStatus: 403,
            generateContentBody: Self.mockGeminiValidationRequiredError()
        )
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-validation",
                    ]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any], Self.string(from: body))
            let error = try XCTUnwrap(payload["error"] as? [String: Any], Self.string(from: body))
            let details = try XCTUnwrap(error["details"] as? [[String: Any]], Self.string(from: body))
            let metadata = try XCTUnwrap(details.first?["metadata"] as? [String: Any], Self.string(from: body))

            XCTAssertEqual(response.statusCode, 403, Self.string(from: body))
            XCTAssertEqual(error["status"] as? String, "PERMISSION_DENIED")
            XCTAssertEqual(error["message"] as? String, "Verify your account to continue.")
            XCTAssertEqual(details.first?["reason"] as? String, "VALIDATION_REQUIRED")
            XCTAssertEqual(metadata["validation_error_message"] as? String, "Verify your account to continue.")

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertTrue(entry.errorSummary?.contains("403 PERMISSION_DENIED") == true)
            XCTAssertTrue(entry.errorSummary?.contains("VALIDATION_REQUIRED") == true)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.generateHits, 1)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer gemini-access-live")
        }
    }

    func testGeminiOAuthPublicStreamGenerateContentHandshakePropagatesStructuredValidationRequiredError() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(
            probe: probe,
            streamGenerateContentStatus: 403,
            streamGenerateContentBody: Self.mockGeminiValidationRequiredError()
        )
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:streamGenerateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-validation-stream",
                    ]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any], Self.string(from: body))
            let error = try XCTUnwrap(payload["error"] as? [String: Any], Self.string(from: body))
            let details = try XCTUnwrap(error["details"] as? [[String: Any]], Self.string(from: body))

            XCTAssertEqual(response.statusCode, 403, Self.string(from: body))
            XCTAssertEqual(error["status"] as? String, "PERMISSION_DENIED")
            XCTAssertEqual(details.first?["reason"] as? String, "VALIDATION_REQUIRED")

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertTrue(entry.errorSummary?.contains("403 PERMISSION_DENIED") == true)
            XCTAssertTrue(entry.errorSummary?.contains("VALIDATION_REQUIRED") == true)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.streamGenerateHits, 1)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer gemini-access-live")
        }
    }

    func testGeminiOAuthPublicStreamGenerateContentPreservesStructuredErrorChunk() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(
            probe: probe,
            streamGenerateContentChunks: [
                "data: {\"response\":{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Partial output\"}]}}],\"modelVersion\":\"gemini-2.5-flash\"}}\n\n",
                "data: \(Self.compactJSONString(Self.mockGeminiValidationRequiredError()))\n\n",
            ]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:streamGenerateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-validation-stream-chunk",
                    ]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)
            let events = ProxyTranscoder.decodeSSE(body)
            let errorPayload = try XCTUnwrap(
                events
                    .compactMap(ProxyTranscoder.jsonObject(from:))
                    .last(where: { $0["error"] != nil }),
                text
            )
            let error = try XCTUnwrap(errorPayload["error"] as? [String: Any], text)
            let details = try XCTUnwrap(error["details"] as? [[String: Any]], text)

            XCTAssertEqual(response.statusCode, 200, text)
            XCTAssertTrue(text.contains("Partial output"), text)
            XCTAssertEqual(error["code"] as? Int, 403)
            XCTAssertEqual(error["status"] as? String, "PERMISSION_DENIED")
            XCTAssertEqual(details.first?["reason"] as? String, "VALIDATION_REQUIRED")

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertTrue(entry.errorSummary?.contains("protocol_failed") == true, entry.errorSummary ?? "nil")
            XCTAssertTrue(entry.errorSummary?.contains("PERMISSION_DENIED") == true, entry.errorSummary ?? "nil")
            XCTAssertTrue(entry.errorSummary?.contains("VALIDATION_REQUIRED") == true, entry.errorSummary ?? "nil")

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.streamGenerateHits, 1)
        }
    }

    func testGeminiOAuthPublicCountTokensPropagatesStructuredValidationRequiredError() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(
            probe: probe,
            countTokensStatus: 403,
            countTokensBody: Self.mockGeminiValidationRequiredError()
        )
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:countTokens",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Count me"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-validation-count",
                    ]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any], Self.string(from: body))
            let error = try XCTUnwrap(payload["error"] as? [String: Any], Self.string(from: body))
            let details = try XCTUnwrap(error["details"] as? [[String: Any]], Self.string(from: body))

            XCTAssertEqual(response.statusCode, 403, Self.string(from: body))
            XCTAssertEqual(error["status"] as? String, "PERMISSION_DENIED")
            XCTAssertEqual(details.first?["reason"] as? String, "VALIDATION_REQUIRED")

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertTrue(entry.errorSummary?.contains("403 PERMISSION_DENIED") == true)
            XCTAssertTrue(entry.errorSummary?.contains("VALIDATION_REQUIRED") == true)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.countTokensHits, 1)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer gemini-access-live")
        }
    }

    func testGeminiOAuthPublicGenerateContentCleansStaleThoughtSignatureForCLISessionWithoutStickyBinding() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let request = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    body: """
                    {
                      "contents": [
                        {
                          "role": "user",
                          "parts": [
                            {"text": "Inspect /.gemini/tmp/\(String(repeating: "d", count: 64))/workspace"}
                          ]
                        },
                        {
                          "role": "model",
                          "parts": [
                            {
                              "text": "Internal thought",
                              "thought": true,
                              "thoughtSignature": "stale_sig_123"
                            }
                          ]
                        }
                      ]
                    }
                    """,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-cleanup",
                    ]
                ),
                kind: .publicAPI
            )
            let responseBody = try await Self.data(from: request.body)
            XCTAssertEqual(request.statusCode, 200, Self.string(from: responseBody))

            let snapshot = await probe.snapshot()
            let generateBody = try XCTUnwrap(snapshot.generateBodies.first)
            XCTAssertTrue(generateBody.contains(GeminiTranscoder.compatibilityThoughtSignature))
            XCTAssertFalse(generateBody.contains("stale_sig_123"))
        }
    }

    func testAnthropicCountTokensDoesNotSelectGeminiOAuthAccount() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages/count_tokens",
                    body: #"{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hello"}]}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(
                text.contains("没有任何可用的上游账号")
                    || text.contains("没有可用账号")
                    || text.contains("Anthropic"),
                text
            )

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.generateHits, 0)
            XCTAssertEqual(snapshot.countTokensHits, 0)
            XCTAssertEqual(snapshot.loadCodeAssistHits, 0)
        }
    }

    func testAdminOAuthCallbackPageUsesSharedRendererAndAcceptLanguage() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        try await harness.service.makeAdminApplication().test(.router) { client in
            var headers = HTTPFields()
            headers.append(.init(name: .acceptLanguage, value: "zh-CN,zh;q=0.9"))

            try await client.execute(
                uri: "/auth/callback?code=test-code&state=test-state",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
                let body = Self.string(from: response.body)
                XCTAssertTrue(body.contains("授权失败"))
                XCTAssertTrue(body.contains("AI Coding Proxy"))
                XCTAssertTrue(body.contains("下一步"))
                XCTAssertTrue(body.contains("没有进行中的 OAuth 登录"))
            }
        }
    }

    func testAdminCanDisableAccountAndDisabledAccountStopsServingRequests() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        _ = try await harness.controller.importAuthJSONAccounts([
            .init(source: "test-api-key.json", content: Self.openAIAPIKeyAuthJSON(), label: "Disabled API Key")
        ])
        let accounts = try await harness.controller.listAccounts()
        let account = try XCTUnwrap(accounts.first)

        let disableResponse = await harness.service.handle(
            Self.makeAdminRequest(
                method: "PATCH",
                path: "/admin/accounts/\(account.id)/enabled",
                body: #"{"enabled":false}"#,
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        XCTAssertEqual(disableResponse.statusCode, 200)
        let disableBody = try await Self.data(from: disableResponse.body)
        let disabledAccount = try Helpers.readJSON(AccountSummary.self, from: disableBody)
        XCTAssertFalse(disabledAccount.enabled)

        let response = await harness.service.handle(
            Self.makePublicRequest(
                path: "/v1/responses",
                body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                proxyKey: harness.config.proxyAPIKey
            ),
            kind: .publicAPI
        )
        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertTrue(Self.string(from: body).contains("当前 API Key 绑定的是全部数据源，但没有任何可用的上游账号。"))
    }

    func testAdminDeleteAccountClearsActiveSelection() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        _ = try await harness.controller.importAuthJSONAccounts([
            .init(source: "test-api-key.json", content: Self.openAIAPIKeyAuthJSON(), label: "Delete API Key")
        ])
        let accounts = try await harness.controller.listAccounts()
        let account = try XCTUnwrap(accounts.first)
        await harness.controller.runtimeState.setActive(accountKey: account.accountKey, accountID: account.accountID, label: account.label)

        let deleteResponse = await harness.service.handle(
            Self.makeAdminRequest(
                method: "DELETE",
                path: "/admin/accounts/\(account.id)",
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        XCTAssertEqual(deleteResponse.statusCode, 200)
        let deleteBody = try await Self.data(from: deleteResponse.body)
        let result = try Helpers.readJSON(DeleteAccountResult.self, from: deleteBody)
        XCTAssertEqual(result.id, account.id)

        let status = try await harness.controller.status()
        XCTAssertNil(status.activeAccountKey)
        let remainingAccounts = try await harness.controller.listAccounts()
        XCTAssertTrue(remainingAccounts.isEmpty)
    }

    func testAdminOAuthAccountLabelUpdateChangesActiveLabelWithoutRewritingHistoricalLogs() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        _ = try await harness.controller.importAuthJSONAccounts([
            .init(source: "oauth-auth.json", content: Self.chatGPTAuthJSON(), label: "Old OAuth Label")
        ])
        let importedAccounts = try await harness.controller.listAccounts()
        let account = try XCTUnwrap(importedAccounts.first)
        try harness.controller.store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256("proxy-key"),
                accountKey: account.accountKey,
                accountLabel: account.label,
                model: "gpt-5.4",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 12, outputTokens: 8, totalTokens: 20, cacheHitTokens: nil),
                timestamp: Helpers.now(),
                apiKeyValue: "proxy-key"
            )
        )
        await harness.controller.runtimeState.setActive(
            accountKey: account.accountKey,
            accountID: account.accountID,
            label: account.label
        )

        let response = await harness.service.handle(
            Self.makeAdminRequest(
                method: "PATCH",
                path: "/admin/accounts/\(account.id)/label",
                body: #"{"label":"Renamed OAuth Label"}"#,
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
        let updated = try Helpers.readJSON(AccountSummary.self, from: body)
        XCTAssertEqual(updated.label, "Renamed OAuth Label")
        XCTAssertEqual(updated.accountKey, account.accountKey)

        let status = try await harness.controller.status()
        XCTAssertEqual(status.activeAccountLabel, "Renamed OAuth Label")

        let logs = try await harness.controller.requestLogs(query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10))
        XCTAssertEqual(logs.entries.count, 1)
        XCTAssertEqual(logs.entries[0].accountLabel, "Old OAuth Label")
    }

    func testAdminAccountManagedProxyNodeUpdateRoutePersistsNode() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )
        let service = DaemonHTTPService(controller: controller, publicHost: "127.0.0.1", publicPort: 8787, adminPort: 8788)

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        let savedConfig = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await controller.manualAddAPIKeyAccount(
                .init(label: "Managed Proxy Node", baseURL: baseURL, apiKey: "sk-route-node")
            )

            let response = await service.handle(
                Self.makeAdminRequest(
                    method: "PATCH",
                    path: "/admin/accounts/\(added.id)/managed-proxy-node",
                    body: #"{"managedProxyNodeName":"Seoul"}"#,
                    adminToken: savedConfig.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

            let updated = try Helpers.readJSON(AccountSummary.self, from: body)
            XCTAssertEqual(updated.managedProxyNodeName, "Seoul")

            let accounts = try await controller.listAccounts()
            XCTAssertEqual(accounts.first?.managedProxyNodeName, "Seoul")
        }
    }

    func testAdminClearAccountManagedProxyNodesRouteClearsAllOverrides() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )
        let service = DaemonHTTPService(controller: controller, publicHost: "127.0.0.1", publicPort: 8787, adminPort: 8788)

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        let savedConfig = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await controller.manualAddAPIKeyAccount(
                .init(label: "Managed Proxy Node A", baseURL: baseURL, apiKey: "sk-route-node-a")
            )
            let second = try await controller.manualAddAPIKeyAccount(
                .init(label: "Managed Proxy Node B", baseURL: baseURL, apiKey: "sk-route-node-b")
            )

            _ = try await controller.updateAccountManagedProxyNode(
                id: first.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Tokyo")
            )
            _ = try await controller.updateAccountManagedProxyNode(
                id: second.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )

            let response = await service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/managed-proxy-node/clear",
                    adminToken: savedConfig.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

            let result = try Helpers.readJSON(ClearAccountManagedProxyNodesResult.self, from: body)
            XCTAssertEqual(result.clearedCount, 2)

            let accounts = try await controller.listAccounts()
            XCTAssertTrue(accounts.allSatisfy { $0.managedProxyNodeName == nil })
        }
    }

    func testRefreshAccountUsageUsesAccountManagedProxyListenerPortWithoutSelectingGlobalNode() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await controller.manualAddAPIKeyAccount(
                .init(label: "Node Bound Account", baseURL: baseURL, apiKey: "sk-node-bound")
            )
            _ = try await controller.updateAccountManagedProxyNode(
                id: added.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )

            let globalProxyCallsBeforeRefresh = await runtime.snapshotGlobalEffectiveProxySettingsCallCount()
            _ = try await controller.refreshAccountUsage(id: added.id)

            let activePorts = await runtime.snapshotActiveAccountNodePorts()
            let resolvedNodeNames = await runtime.snapshotResolvedAccountNodeNames()
            let resolvedPorts = await runtime.snapshotResolvedAccountNodePorts()
            let selectedNodeNames = await runtime.snapshotSelectedNodeNames()
            let globalProxyCallsAfterRefresh = await runtime.snapshotGlobalEffectiveProxySettingsCallCount()
            XCTAssertEqual(resolvedNodeNames, ["Seoul"])
            XCTAssertEqual(resolvedPorts, [try XCTUnwrap(activePorts["Seoul"])])
            XCTAssertTrue(selectedNodeNames.isEmpty)
            XCTAssertEqual(globalProxyCallsAfterRefresh - globalProxyCallsBeforeRefresh, 0)
        }
    }

    func testRefreshAccountUsageUsesAccountManagedProxyNodeOutsideSubscriptionMode() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var subscriptionConfig = try await controller.loadConfig()
        subscriptionConfig.outboundProxyMode = .subscription
        subscriptionConfig.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(subscriptionConfig)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await controller.manualAddAPIKeyAccount(
                .init(label: "Manual Mode Account", baseURL: baseURL, apiKey: "sk-manual-mode")
            )
            _ = try await controller.updateAccountManagedProxyNode(
                id: added.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )

            var manualConfig = try await controller.loadConfig()
            manualConfig.outboundProxyMode = .manual
            _ = try await controller.saveConfig(manualConfig)

            let globalProxyCallsBeforeRefresh = await runtime.snapshotGlobalEffectiveProxySettingsCallCount()
            _ = try await controller.refreshAccountUsage(id: added.id)

            let activePorts = await runtime.snapshotActiveAccountNodePorts()
            let resolvedNodeNames = await runtime.snapshotResolvedAccountNodeNames()
            let resolvedPorts = await runtime.snapshotResolvedAccountNodePorts()
            let selectedNodeNames = await runtime.snapshotSelectedNodeNames()
            let globalProxyCallsAfterRefresh = await runtime.snapshotGlobalEffectiveProxySettingsCallCount()
            XCTAssertNotNil(activePorts["Seoul"])
            XCTAssertEqual(resolvedNodeNames, ["Seoul"])
            XCTAssertEqual(resolvedPorts, [try XCTUnwrap(activePorts["Seoul"])])
            XCTAssertTrue(selectedNodeNames.isEmpty)
            XCTAssertEqual(globalProxyCallsAfterRefresh - globalProxyCallsBeforeRefresh, 0)
        }
    }

    func testRefreshAccountUsageUsesAccountManagedProxyNodeWhenGlobalModeIsDisabled() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await controller.manualAddAPIKeyAccount(
                .init(label: "Disabled Mode Account", baseURL: baseURL, apiKey: "sk-disabled-mode")
            )
            _ = try await controller.updateAccountManagedProxyNode(
                id: added.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )

            var disabledConfig = try await controller.loadConfig()
            disabledConfig.outboundProxyMode = .disabled
            _ = try await controller.saveConfig(disabledConfig)

            _ = try await controller.refreshAccountUsage(id: added.id)

            let activePorts = await runtime.snapshotActiveAccountNodePorts()
            let resolvedNodeNames = await runtime.snapshotResolvedAccountNodeNames()
            let resolvedPorts = await runtime.snapshotResolvedAccountNodePorts()
            let selectedNodeNames = await runtime.snapshotSelectedNodeNames()
            XCTAssertEqual(resolvedNodeNames, ["Seoul"])
            XCTAssertEqual(resolvedPorts, [try XCTUnwrap(activePorts["Seoul"])])
            XCTAssertTrue(selectedNodeNames.isEmpty)
        }
    }

    func testRefreshAccountUsageFailsWhenAccountManagedProxyNodeBecomesUnavailable() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let added = try await controller.manualAddAPIKeyAccount(
                .init(label: "Unavailable Node Account", baseURL: baseURL, apiKey: "sk-unavailable-node")
            )
            _ = try await controller.updateAccountManagedProxyNode(
                id: added.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )

            await runtime.setAvailableNodeNames(["Tokyo"])

            do {
                _ = try await controller.refreshAccountUsage(id: added.id)
                XCTFail("Expected refresh to fail when the saved node is unavailable")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Unavailable Node Account"))
                XCTAssertTrue(error.localizedDescription.contains("Seoul"))
            }

            let activePorts = await runtime.snapshotActiveAccountNodePorts()
            let resolvedNodeNames = await runtime.snapshotResolvedAccountNodeNames()
            let selectedNodeNames = await runtime.snapshotSelectedNodeNames()
            XCTAssertTrue(activePorts.isEmpty)
            XCTAssertTrue(resolvedNodeNames.isEmpty)
            XCTAssertTrue(selectedNodeNames.isEmpty)
        }
    }

    func testManagedProxyAccountNodeListenersSharePortAndReleaseAfterLastAccountUnbinds() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await controller.manualAddAPIKeyAccount(
                .init(label: "First Shared Node", baseURL: baseURL, apiKey: "sk-shared-first")
            )
            let second = try await controller.manualAddAPIKeyAccount(
                .init(label: "Second Shared Node", baseURL: baseURL, apiKey: "sk-shared-second")
            )

            _ = try await controller.updateAccountManagedProxyNode(
                id: first.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )
            let firstPorts = await runtime.snapshotActiveAccountNodePorts()
            let sharedPort = try XCTUnwrap(firstPorts["Seoul"])

            _ = try await controller.updateAccountManagedProxyNode(
                id: second.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )
            let secondPorts = await runtime.snapshotActiveAccountNodePorts()
            XCTAssertEqual(secondPorts, ["Seoul": sharedPort])

            _ = try await controller.updateAccountManagedProxyNode(
                id: first.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: nil)
            )
            let afterFirstUnbind = await runtime.snapshotActiveAccountNodePorts()
            XCTAssertEqual(afterFirstUnbind, ["Seoul": sharedPort])

            _ = try await controller.updateAccountManagedProxyNode(
                id: second.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: nil)
            )
            let afterLastUnbind = await runtime.snapshotActiveAccountNodePorts()
            XCTAssertTrue(afterLastUnbind.isEmpty)
        }
    }

    func testClearAccountManagedProxyNodesClearsOverridesAndReconcilesListeners() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await controller.manualAddAPIKeyAccount(
                .init(label: "Clear Node A", baseURL: baseURL, apiKey: "sk-clear-node-a")
            )
            let second = try await controller.manualAddAPIKeyAccount(
                .init(label: "Clear Node B", baseURL: baseURL, apiKey: "sk-clear-node-b")
            )

            _ = try await controller.updateAccountManagedProxyNode(
                id: first.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Tokyo")
            )
            _ = try await controller.updateAccountManagedProxyNode(
                id: second.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )
            let activePortsBeforeClear = await runtime.snapshotActiveAccountNodePorts()
            XCTAssertEqual(Set(activePortsBeforeClear.keys), Set(["Tokyo", "Seoul"]))

            let result = try await controller.clearAccountManagedProxyNodes()
            XCTAssertEqual(result.clearedCount, 2)

            let accounts = try await controller.listAccounts()
            XCTAssertTrue(accounts.allSatisfy { $0.managedProxyNodeName == nil })
            let activePortsAfterClear = await runtime.snapshotActiveAccountNodePorts()
            XCTAssertTrue(activePortsAfterClear.isEmpty)
        }
    }

    func testManagedProxyDifferentAccountsUseDifferentListenerPortsWithoutSelectNode() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let runtime = ManagedProxyRuntimeStub(
            secretStore: secretStore,
            availableNodeNames: ["Tokyo", "Seoul"]
        )
        let controller = try Self.makeController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: true,
            secretStore: secretStore,
            managedProxyRuntime: runtime
        )

        try secretStore.setMihomoSubscriptionURL("https://example.com/subscription")
        var config = try await controller.loadConfig()
        config.outboundProxyMode = .subscription
        config.managedProxySummary.selectedNodeName = "Tokyo"
        _ = try await controller.saveConfig(config)

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let tokyo = try await controller.manualAddAPIKeyAccount(
                .init(label: "Tokyo Account", baseURL: baseURL, apiKey: "sk-node-tokyo")
            )
            let seoul = try await controller.manualAddAPIKeyAccount(
                .init(label: "Seoul Account", baseURL: baseURL, apiKey: "sk-node-seoul")
            )

            _ = try await controller.updateAccountManagedProxyNode(
                id: tokyo.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Tokyo")
            )
            _ = try await controller.updateAccountManagedProxyNode(
                id: seoul.id,
                input: UpdateAccountManagedProxyNodeRequest(managedProxyNodeName: "Seoul")
            )

            async let refreshTokyo = controller.refreshAccountUsage(id: tokyo.id)
            async let refreshSeoul = controller.refreshAccountUsage(id: seoul.id)
            _ = try await (refreshTokyo, refreshSeoul)

            let activePorts = await runtime.snapshotActiveAccountNodePorts()
            let resolvedNodeNames = await runtime.snapshotResolvedAccountNodeNames()
            let resolvedPorts = await runtime.snapshotResolvedAccountNodePorts()
            let selectedNodeNames = await runtime.snapshotSelectedNodeNames()
            XCTAssertEqual(Set(resolvedNodeNames), Set(["Tokyo", "Seoul"]))
            XCTAssertEqual(Set(resolvedPorts), Set([try XCTUnwrap(activePorts["Tokyo"]), try XCTUnwrap(activePorts["Seoul"])]))
            XCTAssertNotEqual(activePorts["Tokyo"], activePorts["Seoul"])
            XCTAssertTrue(selectedNodeNames.isEmpty)
        }
    }

    func testAdminManualAPIKeyAccountAddAndSingleUsageRefreshUseAccountBaseURL() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Manual API Key","base_url":"\(baseURL)/v1","api_key":"sk-manual-route","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
            let added = try Helpers.readJSON(AccountSummary.self, from: addBody)
            XCTAssertEqual(added.authMode, .openAIAPIKey)
            XCTAssertEqual(added.upstreamBaseURL, "\(baseURL)/v1")
            XCTAssertTrue(added.enabled)

            let refreshResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/\(added.id)/usage/refresh",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let refreshBody = try await Self.data(from: refreshResponse.body)
            XCTAssertEqual(refreshResponse.statusCode, 200, Self.string(from: refreshBody))
            let refreshed = try Helpers.readJSON(AccountSummary.self, from: refreshBody)
            XCTAssertEqual(refreshed.authMode, .openAIAPIKey)
            XCTAssertEqual(refreshed.upstreamBaseURL, "\(baseURL)/v1")
            XCTAssertNil(refreshed.usage)
            XCTAssertNil(refreshed.usageError)
        }
    }

    func testAdminAccountStopCooldownRouteClearsAPIKeyCoolingState() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Cooling API",
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-admin-stop-cooldown",
                    enabled: true
                )
            )
            try harness.controller.store.updateAccountFailureState(
                id: added.id,
                consecutiveFailureCount: 3,
                cooldownUntil: Helpers.now() + 3_600,
                usageError: "API key cooling down"
            )

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/\(added.id)/cooldown/stop",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            let updated = try Helpers.readJSON(AccountSummary.self, from: body)
            XCTAssertEqual(updated.consecutiveFailureCount, 0)
            XCTAssertNil(updated.cooldownUntil)
            XCTAssertNil(updated.usageError)
        }
    }

    func testAdminAccountStopCooldownRouteReturnsErrorForMissingAccount() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let response = await harness.service.handle(
            Self.makeAdminRequest(
                method: "POST",
                path: "/admin/accounts/missing-account/cooldown/stop",
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        let body = try await Self.data(from: response.body)

        XCTAssertEqual(response.statusCode, 500, Self.string(from: body))
        XCTAssertTrue(Self.string(from: body).contains("停止账号冷却失败"))
    }

    func testAdminManualAPIKeyAccountAddAliyunPresetUsesChatCompletionsValidation() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AliyunCodingPlanProbe()
        let upstream = Self.makeAliyunCodingPlanUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Aliyun Coding Plan","provider_preset":"aliyun_qwen_coding_plan","base_url":"\(baseURL)/v1","api_key":"sk-aliyun","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
            let added = try Helpers.readJSON(AccountSummary.self, from: addBody)
            XCTAssertEqual(added.providerPreset, .aliyunQwenCodingPlan)
            XCTAssertEqual(added.upstreamBaseURL, baseURL)

            let detailsResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "GET",
                    path: "/admin/accounts/\(added.id)/manual-api-key",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let detailsBody = try await Self.data(from: detailsResponse.body)
            XCTAssertEqual(detailsResponse.statusCode, 200, Self.string(from: detailsBody))
            let details = try Helpers.readJSON(ManualAPIKeyAccountDetails.self, from: detailsBody)
            XCTAssertEqual(details.providerPreset, .aliyunQwenCodingPlan)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, 0)
            XCTAssertEqual(snapshot.chatHits, 1)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer sk-aliyun")
            XCTAssertTrue(snapshot.lastUserAgent.contains("OpenClaw"))
            XCTAssertTrue(snapshot.requestBodies.last?.contains(#""model":"qwen3-coder-plus""#) == true)
        }
    }

    func testAdminManualAPIKeyAccountAddRejectsGenericPresetForOfficialGeminiRoot() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let response = await harness.service.handle(
            Self.makeAdminRequest(
                method: "POST",
                path: "/admin/accounts/manual-api-key",
                body: """
                {"label":"Gemini Wrong Preset","provider_preset":"generic_openai_compatible","base_url":"\(OpenAICompatibleUpstream.defaultGeminiBaseURL)","api_key":"sk-gemini-runtime","enabled":true}
                """,
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        let body = try await Self.data(from: response.body)

        XCTAssertEqual(response.statusCode, 500, Self.string(from: body))
        XCTAssertTrue(Self.string(from: body).contains("Google Gemini OpenAI-compatible"))
        XCTAssertTrue(Self.string(from: body).contains("Google Gemini Compatible"))
    }

    func testAdminManualAPIKeyAccountAddRejectsGoogleAIOAuthLikeCredentialForGeminiPreset() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let response = await harness.service.handle(
            Self.makeAdminRequest(
                method: "POST",
                path: "/admin/accounts/manual-api-key",
                body: """
                {"label":"Gemini AI Pro","provider_preset":"google_gemini_compatible","base_url":"\(OpenAICompatibleUpstream.defaultGeminiBaseURL)","api_key":"AQ.test-google-session","enabled":true}
                """,
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        let body = try await Self.data(from: response.body)
        let bodyText = Self.string(from: body)

        XCTAssertEqual(response.statusCode, 500, bodyText)
        XCTAssertTrue(bodyText.lowercased().contains("gemini api key"), bodyText)
        XCTAssertTrue(
            bodyText.lowercased().contains("google ai pro")
                || bodyText.lowercased().contains("gemini cli")
                || bodyText.lowercased().contains("google oauth")
                || bodyText.lowercased().contains(#"google \/ gemini login"#),
            bodyText
        )
    }

    func testImportAuthJSONAccountsRejectsGoogleAIOAuthLikeGeminiCredential() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let authJSON = try AuthService.normalizeManualAPIKeyInput(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "AQ.test-google-session",
            providerPreset: .googleGeminiCompatible
        )

        let result = try await harness.controller.importAuthJSONAccounts([
            .init(source: "gemini-ai-pro.json", content: authJSON, label: "Gemini AI Pro")
        ])
        let accounts = try await harness.controller.listAccounts()

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].error.contains(OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage))
        XCTAssertTrue(accounts.isEmpty)
    }

    func testAdminManualAPIKeyAccountDetailsReturnsStoredSecret() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let addResponse = await harness.service.handle(
            Self.makeAdminRequest(
                method: "POST",
                path: "/admin/accounts/manual-api-key",
                body: """
                {"label":"Editable API Key","base_url":"https://example.com/proxy/v1","api_key":"sk-stored-secret","enabled":false}
                """,
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        let addBody = try await Self.data(from: addResponse.body)
        XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
        let added = try Helpers.readJSON(AccountSummary.self, from: addBody)

        let detailsResponse = await harness.service.handle(
            Self.makeAdminRequest(
                method: "GET",
                path: "/admin/accounts/\(added.id)/manual-api-key",
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        let detailsBody = try await Self.data(from: detailsResponse.body)
        XCTAssertEqual(detailsResponse.statusCode, 200, Self.string(from: detailsBody))
        let details = try Helpers.readJSON(ManualAPIKeyAccountDetails.self, from: detailsBody)

        XCTAssertEqual(
            details,
            ManualAPIKeyAccountDetails(
                label: "Editable API Key",
                baseURL: "https://example.com/proxy/v1",
                upstreamAdapter: .responses,
                upstreamThinkingCompatibility: .disabled,
                apiKey: "sk-stored-secret",
                enabled: false
            )
        )
    }

    func testAdminManualAPIKeyAccountUpdateClearsActiveSelectionWhenIdentityChanges() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Editable API Key","base_url":"\(baseURL)/v1","api_key":"sk-before-edit","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
            let added = try Helpers.readJSON(AccountSummary.self, from: addBody)
            await harness.controller.runtimeState.setActive(
                accountKey: added.accountKey,
                accountID: added.accountID,
                label: added.label
            )

            let updateResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "PUT",
                    path: "/admin/accounts/\(added.id)/manual-api-key",
                    body: """
                    {"label":"Edited API Key","base_url":"\(baseURL)/v1","api_key":"sk-after-edit","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let updateBody = try await Self.data(from: updateResponse.body)
            XCTAssertEqual(updateResponse.statusCode, 200, Self.string(from: updateBody))
            let updated = try Helpers.readJSON(AccountSummary.self, from: updateBody)

            XCTAssertEqual(updated.id, added.id)
            XCTAssertNotEqual(updated.accountKey, added.accountKey)
            XCTAssertEqual(updated.label, "Edited API Key")
            XCTAssertEqual(updated.upstreamBaseURL, "\(baseURL)/v1")

            let status = try await harness.controller.status()
            XCTAssertNil(status.activeAccountKey)

            let accounts = try await harness.controller.listAccounts()
            XCTAssertEqual(accounts.count, 1)
            XCTAssertEqual(accounts.first?.id, added.id)
            XCTAssertEqual(accounts.first?.accountKey, updated.accountKey)
        }
    }

    func testAdminManualAPIKeyAccountUpdateRejectsGenericPresetForOfficialGeminiRoot() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeOpenAICompatibleModelsApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Editable API Key","provider_preset":"generic_openai_compatible","base_url":"\(baseURL)","api_key":"sk-before-edit","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
            let added = try Helpers.readJSON(AccountSummary.self, from: addBody)

            let updateResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "PUT",
                    path: "/admin/accounts/\(added.id)/manual-api-key",
                    body: """
                    {"label":"Wrong Gemini Preset","provider_preset":"generic_openai_compatible","base_url":"\(OpenAICompatibleUpstream.defaultGeminiBaseURL)","api_key":"sk-gemini-runtime","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let updateBody = try await Self.data(from: updateResponse.body)

            XCTAssertEqual(updateResponse.statusCode, 500, Self.string(from: updateBody))
            XCTAssertTrue(Self.string(from: updateBody).contains("Google Gemini OpenAI-compatible"))
            XCTAssertTrue(Self.string(from: updateBody).contains("Google Gemini Compatible"))
        }
    }

    func testAdminAccountOrderEndpointReordersAccounts() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        _ = try await harness.controller.importAuthJSONAccounts([
            .init(source: "auth-1", content: Self.chatGPTAuthJSON(accountID: "account-1"), label: "First OAuth"),
            .init(source: "auth-2", content: Self.chatGPTAuthJSON(accountID: "account-2"), label: "Second OAuth"),
        ])
        let initial = try await harness.controller.listAccounts()

        let response = await harness.service.handle(
            Self.makeAdminRequest(
                method: "PUT",
                path: "/admin/accounts/order",
                body: #"{"orderedAccountIDs":["\#(initial[1].id)","\#(initial[0].id)"]}"#,
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
        let reordered = try Helpers.readJSON([AccountSummary].self, from: body)
        let persisted = try await harness.controller.listAccounts()

        XCTAssertEqual(reordered.map(\.id), [initial[1].id, initial[0].id])
        XCTAssertEqual(reordered.map(\.selectionOrder), [0, 1])
        XCTAssertEqual(persisted.map(\.id), [initial[1].id, initial[0].id])
    }

    func testResponsesProxyUsesCustomAccountOrderForAPIKeyAccounts() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "First API route"),
            secondMode: .success(text: "Second API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "First API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            let second = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )
            _ = try await harness.controller.reorderAccounts(ids: [second.id, first.id])
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("Second API route"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 0)
            XCTAssertEqual(hits.secondHits, 1)

            let status = try await harness.controller.status()
            XCTAssertEqual(status.activeAccountKey, second.accountKey)
        }
    }

    func testResponsesProxyPinnedAccountHeaderOverridesCustomOrderWithoutFallback() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "First API route"),
            secondMode: .success(text: "Second API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "First API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            let second = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )
            _ = try await harness.controller.reorderAccounts(ids: [second.id, first.id])
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: first.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("First API route"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 1)
            XCTAssertEqual(hits.secondHits, 0)
        }
    }

    func testResponsesProxyRestrictedAPIKeyOnlyAutoRoutesToAllowlistedAccounts() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "First API route"),
            secondMode: .success(text: "Second API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "First API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            let second = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )

            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "restricted-primary",
                    label: "Restricted Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    allowedAccountKeys: [second.accountKey],
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "restricted-primary"
            _ = try await harness.controller.saveConfig(config)
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("Second API route"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 0)
            XCTAssertEqual(hits.secondHits, 1)

            let status = try await harness.controller.status()
            XCTAssertEqual(status.activeAccountKey, second.accountKey)
            XCTAssertNotEqual(status.activeAccountKey, first.accountKey)
        }
    }

    func testResponsesProxyPinnedAccountOutsideAllowlistFailsWithRestrictionError() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "First API route"),
            secondMode: .success(text: "Second API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "First API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            let second = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )

            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "restricted-primary",
                    label: "Restricted Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    allowedAccountKeys: [second.accountKey],
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "restricted-primary"
            _ = try await harness.controller.saveConfig(config)
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: first.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(Self.string(from: body).contains("指定的测试账号不在当前 API Key 允许使用的账号范围内"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 0)
            XCTAssertEqual(hits.secondHits, 0)
        }
    }

    func testResponsesProxyRestrictedAPIKeyReturnsRestrictedNoAvailableAccountsMessage() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeOpenAICompatibleModelsApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let disabled = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Disabled API",
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-disabled-route",
                    enabled: false
                )
            )

            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "restricted-primary",
                    label: "Restricted Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    allowedAccountKeys: [disabled.accountKey],
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "restricted-primary"
            _ = try await harness.controller.saveConfig(config)

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(Self.string(from: body).contains("当前 API Key 已限制可用账号范围，但限制范围内没有可用的 OpenAI 账号。"))
        }
    }

    func testResponsesProxyPinnedAnthropicOAuthAccountAllowsOpenAIProxyKeyBridge() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-openai",
                    label: "OpenAI Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-openai"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])
            let accounts = try await harness.controller.listAccounts()
            let account = try XCTUnwrap(accounts.first(where: { $0.authMode == .anthropicSubscriptionOAuth }))

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: account.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains(#""object":"response""#))
            XCTAssertTrue(Self.string(from: body).contains("Anthropic model=claude-sonnet-4-5"))
        }
    }

    func testAnthropicMessagesPinnedAnthropicOAuthAccountAllowsOpenAIProxyKeyBridge() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-openai",
                    label: "OpenAI Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-openai"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])
            let accounts = try await harness.controller.listAccounts()
            let account = try XCTUnwrap(accounts.first(where: { $0.authMode == .anthropicSubscriptionOAuth }))

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: account.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let content = try XCTUnwrap(payload["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["text"] as? String, "Anthropic model=claude-sonnet-4-5")
        }
    }

    func testResponsesProxyPinnedAnthropicAPIKeyAccountStillRejectsOpenAIProxyKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-openai",
                    label: "OpenAI Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-openai"
            _ = try await harness.controller.saveConfig(config)

            let account = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Anthropic API Key",
                    providerPreset: .anthropicAPICompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-anthropic-runtime",
                    enabled: true
                )
            )

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: account.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(Self.string(from: body).contains("指定的测试账号与当前 API Key 的数据源不匹配"))

            let hits = await probe.snapshot()
            XCTAssertEqual(hits.modelsHits, 1)
            XCTAssertEqual(hits.messagesHits, 0)
            XCTAssertEqual(hits.countTokensHits, 0)
        }
    }

    func testResponsesProxyPinnedAccountHeaderRejectsMissingAccountWithoutFallback() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "First API route"),
            secondMode: .success(text: "Second API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "First API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: "missing|account"]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(Self.string(from: body).contains("指定的测试账号不存在"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 0)
            XCTAssertEqual(hits.secondHits, 0)
        }
    }

    func testResponsesProxyPinnedAccountHeaderRejectsDisabledAccountWithoutFallback() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "First API route"),
            secondMode: .success(text: "Second API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Disabled API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )
            _ = try await harness.controller.setAccountEnabled(id: first.id, enabled: false)
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: first.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(Self.string(from: body).contains("指定的测试账号已禁用"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 0)
            XCTAssertEqual(hits.secondHits, 0)
        }
    }

    func testResponsesProxyPinnedAccountHeaderRejectsQuotaBlockedAccountWithoutFallback() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "First API route"),
            secondMode: .success(text: "Second API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Quota API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )

            let record = try XCTUnwrap(try harness.controller.store.listAccountRecords().first(where: { $0.id == first.id }))
            try harness.controller.store.updateUsage(
                accountKey: first.accountKey,
                usage: UsageSnapshot(
                    planType: record.effectivePlanType,
                    fiveHour: UsageWindow(
                        usedPercent: 100,
                        windowSeconds: 18_000,
                        resetAt: Helpers.now() + 3_600
                    ),
                    oneWeek: nil,
                    credits: nil
                ),
                usageError: "usage_limit_reached",
                planType: record.effectivePlanType,
                authJSON: record.authJSON,
                usageWindowsVisible: nil,
                authRefreshBlocked: record.authRefreshBlocked,
                authRefreshError: record.authRefreshError
            )
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: first.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 500)
            XCTAssertTrue(Self.string(from: body).contains("额度窗口受限"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 0)
            XCTAssertEqual(hits.secondHits, 0)
        }
    }

    func testResponsesProxyCoolsDownAPIKeyAfterThreeFailures() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .failure(message: "upstream unavailable"),
            secondMode: .success(text: "Fallback API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "First API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )
            await routingState.reset()

            for attempt in 0..<4 {
                let response = await harness.service.handle(
                    Self.makePublicRequest(
                        path: "/v1/responses",
                        body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                        proxyKey: harness.config.proxyAPIKey,
                        extraHeaders: ["session_id": "cooldown-\(attempt)"]
                    ),
                    kind: .publicAPI
                )
                let body = try await Self.data(from: response.body)
                XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
                XCTAssertTrue(Self.string(from: body).contains("Fallback API route"))
            }

            let accounts = try await harness.controller.listAccounts()
            let cooled = try XCTUnwrap(accounts.first(where: { $0.id == first.id }))
            XCTAssertEqual(cooled.consecutiveFailureCount, 3)
            XCTAssertNotNil(cooled.cooldownUntil)
            XCTAssertTrue(cooled.cooldownUntil ?? 0 > Helpers.now())

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 3)
            XCTAssertEqual(hits.secondHits, 4)
        }
    }

    func testResponsesProxyPinnedAPIKeyStillCoolsDownAfterThreeFailures() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .failure(message: "upstream unavailable"),
            secondMode: .success(text: "Fallback API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Pinned API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Fallback API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )
            await routingState.reset()

            for _ in 0..<3 {
                let response = await harness.service.handle(
                    Self.makePublicRequest(
                        path: "/v1/responses",
                        body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                        proxyKey: harness.config.proxyAPIKey,
                        extraHeaders: [ProxyHeaderName.testAccountKey: first.accountKey]
                    ),
                    kind: .publicAPI
                )
                let body = try await Self.data(from: response.body)
                XCTAssertEqual(response.statusCode, 500)
                XCTAssertTrue(Self.string(from: body).contains("upstream unavailable"))
            }

            let accounts = try await harness.controller.listAccounts()
            let cooled = try XCTUnwrap(accounts.first(where: { $0.id == first.id }))
            XCTAssertEqual(cooled.consecutiveFailureCount, 3)
            XCTAssertNotNil(cooled.cooldownUntil)
            XCTAssertTrue(cooled.cooldownUntil ?? 0 > Helpers.now())

            let cooledResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: first.accountKey]
                ),
                kind: .publicAPI
            )
            let cooledBody = try await Self.data(from: cooledResponse.body)
            XCTAssertEqual(cooledResponse.statusCode, 500)
            XCTAssertTrue(Self.string(from: cooledBody).contains("冷却期"))

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 3)
            XCTAssertEqual(hits.secondHits, 0)
        }
    }

    func testResponsesProxyRetriesAPIKeyAfterCooldownExpires() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let routingState = APIKeyRoutingState(
            firstMode: .success(text: "Recovered API route"),
            secondMode: .success(text: "Fallback API route")
        )
        let upstream = Self.makeAPIKeyRoutingUpstreamApplication(state: routingState)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let first = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "First API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-first", enabled: true)
            )
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(label: "Second API", baseURL: "\(baseURL)/v1", apiKey: "sk-route-second", enabled: true)
            )
            try harness.controller.store.updateAccountFailureState(
                id: first.id,
                consecutiveFailureCount: 3,
                cooldownUntil: Helpers.now() - 5
            )
            await routingState.reset()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("Recovered API route"))

            let refreshed = try await harness.controller.listAccounts()
            let recovered = try XCTUnwrap(refreshed.first(where: { $0.id == first.id }))
            XCTAssertEqual(recovered.consecutiveFailureCount, 0)
            XCTAssertNil(recovered.cooldownUntil)

            let hits = await routingState.snapshot()
            XCTAssertEqual(hits.firstHits, 1)
            XCTAssertEqual(hits.secondHits, 0)
        }
    }

    func testImportOAuthPrefersUsagePlanTypeOverStaleAuthClaim() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication(usagePlanType: "plus")
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)

            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "oauth-auth",
                    content: Self.chatGPTAuthJSON(planType: "free"),
                    label: "Upgraded OAuth"
                ),
            ])

            let accounts = try await harness.controller.listAccounts()
            let account = try XCTUnwrap(accounts.first)
            XCTAssertEqual(account.planType, "plus")
            XCTAssertEqual(account.effectivePlanType, "plus")
            XCTAssertTrue(account.usageWindowsVisible)
        }
    }

    func testImportCompletedOpenAIOAuthAccountHidesUsageWindowsUntilRefresh() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication(usagePlanType: "plus")
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)

            let imported = try await harness.controller.importCompletedOAuthAccount(
                authJSON: Self.chatGPTAuthJSON(planType: "free"),
                providerFamily: .openAI,
                config: config
            )

            XCTAssertEqual(imported.authMode, .chatGPT)
            XCTAssertEqual(imported.label, "mock@example.com")
            XCTAssertFalse(imported.usageWindowsVisible)

            let stored = try harness.controller.store.loadAccountRecord(id: imported.id)
            XCTAssertFalse(stored.usageWindowsVisible)
        }
    }

    func testRefreshUsageFailureKeepsKnownPlusPlanType() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication(usagePlanType: "plus")
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)

            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "oauth-auth",
                    content: Self.chatGPTAuthJSON(planType: "free"),
                    label: "Stable Plus"
                ),
            ])
            let importedAccounts = try await harness.controller.listAccounts()
            let imported = try XCTUnwrap(importedAccounts.first)
            XCTAssertEqual(imported.effectivePlanType, "plus")
            try harness.controller.accountService.updateUsageWindowsVisible(accountKey: imported.accountKey, visible: false)

            let failingUsage = Self.makeUsageFailureApplication()
            try await failingUsage.test(.ahc()) { failingClient in
                var failingConfig = try await harness.controller.loadConfig()
                failingConfig.chatGPTBaseURL = "http://localhost:\(failingClient.port ?? 0)"
                _ = try await harness.controller.saveConfig(failingConfig)

                let refreshed = try await harness.controller.refreshAccountUsage(id: imported.id)
                XCTAssertEqual(refreshed.planType, "plus")
                XCTAssertEqual(refreshed.effectivePlanType, "plus")
                XCTAssertEqual(refreshed.usage?.planType, "plus")
                XCTAssertFalse(refreshed.usageWindowsVisible)
            }
        }
    }

    func testRefreshAccountUsageClearsCoolingDownStateForAPIKeyAccount() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeOpenAICompatibleModelsApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let imported = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Refreshable API",
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-refresh-cooldown",
                    enabled: true
                )
            )
            try harness.controller.store.updateAccountFailureState(
                id: imported.id,
                consecutiveFailureCount: 3,
                cooldownUntil: Helpers.now() + 3_600
            )

            let refreshed = try await harness.controller.refreshAccountUsage(id: imported.id)

            XCTAssertEqual(refreshed.authMode, .openAIAPIKey)
            XCTAssertEqual(refreshed.consecutiveFailureCount, 0)
            XCTAssertNil(refreshed.cooldownUntil)
            XCTAssertNil(refreshed.usageError)
            XCTAssertFalse(refreshed.authRefreshBlocked)
            XCTAssertNil(refreshed.authRefreshError)

            let accounts = try await harness.controller.listAccounts()
            let updated = try XCTUnwrap(accounts.first(where: { $0.id == imported.id }))
            XCTAssertEqual(updated.consecutiveFailureCount, 0)
            XCTAssertNil(updated.cooldownUntil)
            XCTAssertFalse(updated.authRefreshBlocked)
            XCTAssertNil(updated.authRefreshError)
        }
    }

    func testRefreshAllUsageClearsCoolingDownStateForAPIKeyAccounts() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeOpenAICompatibleModelsApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let imported = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Refresh All API",
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-refresh-all-cooldown",
                    enabled: true
                )
            )
            try harness.controller.store.updateAccountFailureState(
                id: imported.id,
                consecutiveFailureCount: 3,
                cooldownUntil: Helpers.now() + 3_600
            )

            let refreshed = try await harness.controller.refreshAllUsage()
            let updatedFromRefresh = try XCTUnwrap(refreshed.first(where: { $0.id == imported.id }))

            XCTAssertEqual(updatedFromRefresh.authMode, .openAIAPIKey)
            XCTAssertEqual(updatedFromRefresh.consecutiveFailureCount, 0)
            XCTAssertNil(updatedFromRefresh.cooldownUntil)
            XCTAssertNil(updatedFromRefresh.usageError)
            XCTAssertFalse(updatedFromRefresh.authRefreshBlocked)
            XCTAssertNil(updatedFromRefresh.authRefreshError)

            let accounts = try await harness.controller.listAccounts()
            let updated = try XCTUnwrap(accounts.first(where: { $0.id == imported.id }))
            XCTAssertEqual(updated.consecutiveFailureCount, 0)
            XCTAssertNil(updated.cooldownUntil)
            XCTAssertFalse(updated.authRefreshBlocked)
            XCTAssertNil(updated.authRefreshError)
        }
    }

    func testAdminRefreshAccountUsageClearsStaleRefreshErrorForOAuthAccount() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication(usagePlanType: "plus")
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)

            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(planType: "free"), label: "Recovering OAuth")
            ])
            let importedAccounts = try await harness.controller.listAccounts()
            let imported = try XCTUnwrap(importedAccounts.first)
            var staleRecord = try harness.controller.store.loadAccountRecord(id: imported.id)
            staleRecord.authRefreshBlocked = true
            staleRecord.authRefreshError = "previous refresh error"
            staleRecord.usageError = "previous usage error"
            staleRecord.usageWindowsVisible = false
            _ = try harness.controller.store.upsertAccount(staleRecord)

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/\(imported.id)/usage/refresh",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

            let refreshed = try Helpers.readJSON(AccountSummary.self, from: body)
            XCTAssertFalse(refreshed.authRefreshBlocked)
            XCTAssertNil(refreshed.authRefreshError)
            XCTAssertNil(refreshed.usageError)
            XCTAssertEqual(refreshed.effectivePlanType, "plus")
            XCTAssertTrue(refreshed.usageWindowsVisible)

            let stored = try harness.controller.store.loadAccountRecord(id: imported.id)
            XCTAssertFalse(stored.authRefreshBlocked)
            XCTAssertNil(stored.authRefreshError)
            XCTAssertNil(stored.usageError)
            XCTAssertEqual(stored.effectivePlanType, "plus")
            XCTAssertTrue(stored.usageWindowsVisible)
        }
    }

    func testAdminRefreshAllUsageClearsErrorsOnlyForAccountsThatRefreshSuccessfully() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let oauthUpstream = Self.makeUpstreamApplication(usagePlanType: "plus")
        let failingAPIUpstream = Self.makeOpenAICompatibleModelsApplication(
            status: .internalServerError,
            errorMessage: "models unavailable"
        )

        try await oauthUpstream.test(.ahc()) { oauthClient in
            try await failingAPIUpstream.test(.ahc()) { failingAPIClient in
                var config = harness.config
                config.chatGPTBaseURL = "http://localhost:\(oauthClient.port ?? 0)"
                _ = try await harness.controller.saveConfig(config)

                _ = try await harness.controller.importAuthJSONAccounts([
                    .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(planType: "free"), label: "Recovering OAuth")
                ])
                let oauthAccounts = try await harness.controller.listAccounts()
                let oauthAccount = try XCTUnwrap(oauthAccounts.first)
                var staleOAuthRecord = try harness.controller.store.loadAccountRecord(id: oauthAccount.id)
                staleOAuthRecord.authRefreshBlocked = true
                staleOAuthRecord.authRefreshError = "previous refresh error"
                staleOAuthRecord.usageError = "previous usage error"
                staleOAuthRecord.usageWindowsVisible = false
                _ = try harness.controller.store.upsertAccount(staleOAuthRecord)

                let failingAPI = try await harness.controller.manualAddAPIKeyAccount(
                    ManualAPIKeyAccountInput(
                        label: "Failing API",
                        baseURL: "http://localhost:\(failingAPIClient.port ?? 0)/v1",
                        apiKey: "sk-failing-api",
                        enabled: true
                    )
                )

                let response = await harness.service.handle(
                    Self.makeAdminRequest(
                        method: "POST",
                        path: "/admin/usage/refresh",
                        adminToken: harness.config.adminToken
                    ),
                    kind: .admin
                )
                let body = try await Self.data(from: response.body)
                XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

                let refreshed = try Helpers.readJSON([AccountSummary].self, from: body)
                let refreshedOAuth = try XCTUnwrap(refreshed.first(where: { $0.id == oauthAccount.id }))
                XCTAssertFalse(refreshedOAuth.authRefreshBlocked)
                XCTAssertNil(refreshedOAuth.authRefreshError)
                XCTAssertNil(refreshedOAuth.usageError)
                XCTAssertEqual(refreshedOAuth.effectivePlanType, "plus")
                XCTAssertTrue(refreshedOAuth.usageWindowsVisible)

                let refreshedFailingAPI = try XCTUnwrap(refreshed.first(where: { $0.id == failingAPI.id }))
                XCTAssertTrue(refreshedFailingAPI.usageError?.contains("models unavailable") == true)

                let storedOAuth = try harness.controller.store.loadAccountRecord(id: oauthAccount.id)
                XCTAssertFalse(storedOAuth.authRefreshBlocked)
                XCTAssertNil(storedOAuth.authRefreshError)
                XCTAssertNil(storedOAuth.usageError)
                XCTAssertTrue(storedOAuth.usageWindowsVisible)

                let storedFailingAPI = try harness.controller.store.loadAccountRecord(id: failingAPI.id)
                XCTAssertTrue(storedFailingAPI.usageError?.contains("models unavailable") == true)
            }
        }
    }

    func testAdminRefreshAllUsageLimitsManualAPIKeyRefreshesToThreeConcurrentTasks() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = ConcurrentRequestProbe()
        let upstream = Self.makeDelayedOpenAICompatibleModelsApplication(probe: probe)

        try await upstream.test(.ahc()) { client in
            for index in 0..<5 {
                _ = try await harness.controller.manualAddAPIKeyAccount(
                    ManualAPIKeyAccountInput(
                        label: "Concurrent API \(index)",
                        baseURL: "http://localhost:\(client.port ?? 0)/v1",
                        apiKey: "sk-admin-refresh-concurrent-\(index)",
                        enabled: true
                    )
                )
            }
            await probe.reset()

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/usage/refresh",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

            let refreshed = try Helpers.readJSON([AccountSummary].self, from: body)
            let snapshot = await probe.snapshot()

            XCTAssertEqual(refreshed.count, 5)
            XCTAssertTrue(
                refreshed.allSatisfy { $0.usageError == nil },
                refreshed.compactMap(\.usageError).joined(separator: " | ")
            )
            XCTAssertEqual(snapshot.totalHits, 5)
            XCTAssertEqual(snapshot.maxActiveHits, 3)
        }
    }

    func testResponsesProxySupportsNonStreamAndStream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let nonStream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let nonStreamBody = try await Self.data(from: nonStream.body)
            XCTAssertEqual(nonStream.statusCode, 200, Self.string(from: nonStreamBody))
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"object\":\"response\""))
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"status\":\"completed\""))
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"text\":\"Hello world\""))

            let stream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let streamBody = try await Self.data(from: stream.body)
            XCTAssertEqual(stream.statusCode, 200, Self.string(from: streamBody))
            XCTAssertTrue(Self.string(from: streamBody).contains("response.output_text.delta"))
            XCTAssertTrue(Self.string(from: streamBody).contains("response.completed"))
        }
    }

    func testResponsesStreamTransportErrorBecomesResponseFailedEventAndFailureTrace() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeInterruptedResponsesStreamUpstreamApplication(
            termination: .throwError("terminated"),
            includeCreatedEvent: false
        )
        try await upstream.test(.ahc()) { upstreamClient in
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Interrupted Responses",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-stream-interrupted",
                    enabled: true
                )
            )

            let stream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5","input":"hello","stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let streamBody = try await Self.data(from: stream.body)
            let streamText = Self.string(from: streamBody)

            XCTAssertEqual(stream.statusCode, 200, streamText)
            XCTAssertTrue(streamText.contains("response.output_text.delta"), streamText)
            XCTAssertTrue(streamText.contains(#""type":"response.created""#), streamText)
            XCTAssertTrue(streamText.contains(#""type":"response.failed""#), streamText)
            XCTAssertFalse(streamText.contains(#""type":"response.completed""#), streamText)
            XCTAssertTrue(
                streamText.contains("Upstream stream terminated before response.completed was received."),
                streamText
            )

            let types = ProxyTranscoder.decodeSSE(streamBody).compactMap(ProxyTranscoder.responseEventType(from:))
            XCTAssertEqual(Array(types.suffix(2)), ["response.created", "response.failed"])

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertEqual(entry.failureCategory, "upstream")
            XCTAssertTrue(entry.errorSummary?.contains("response.completed") == true)
            XCTAssertTrue(entry.errorSummary?.contains("terminated") == true)
        }
    }

    func testResponsesStreamPrematureEOFBecomesResponseFailedEventWithoutDuplicatingCreated() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeInterruptedResponsesStreamUpstreamApplication(
            termination: .prematureEOF,
            includeCreatedEvent: true
        )
        try await upstream.test(.ahc()) { upstreamClient in
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Premature EOF Responses",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-stream-eof",
                    enabled: true
                )
            )

            let stream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5","input":"hello","stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let streamBody = try await Self.data(from: stream.body)
            let streamText = Self.string(from: streamBody)

            XCTAssertEqual(stream.statusCode, 200, streamText)
            XCTAssertTrue(streamText.contains(#""type":"response.failed""#), streamText)
            XCTAssertFalse(streamText.contains(#""type":"response.completed""#), streamText)

            let types = ProxyTranscoder.decodeSSE(streamBody).compactMap(ProxyTranscoder.responseEventType(from:))
            XCTAssertEqual(types.filter { $0 == "response.created" }.count, 1)
            XCTAssertEqual(types.last, "response.failed")

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertTrue(entry.errorSummary?.contains("response.completed") == true)
            XCTAssertFalse(entry.errorSummary?.contains("Raw upstream error") == true)
        }
    }

    func testResponsesStreamFailedEventStillRecordsSingleFailureTraceAfterDownstreamCancellation() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeHangingResponsesStreamUpstreamApplication(
            chunks: [
                "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_failed_then_cancelled\",\"created_at\":1710000000}}\n\n",
                "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_failed_then_cancelled\",\"created_at\":1710000000,\"error\":{\"message\":\"We're currently experiencing high demand, which may cause temporary errors.\"}}}\n\n",
            ]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Failed Then Cancelled Responses",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-stream-failed-cancelled",
                    enabled: true
                )
            )

            let proxyKey = try await harness.controller.authenticateProxyAPIKey(harness.config.proxyAPIKey)
            let stream = try await harness.controller.proxyResponses(
                body: Data(#"{"model":"gpt-5.5","input":"hello","stream":true}"#.utf8),
                proxyKey: proxyKey,
                apiKeyValue: harness.config.proxyAPIKey
            )
            XCTAssertEqual(stream.statusCode, 200)
            var responseBody: ProxyHTTPResponse.Body? = stream.body
            guard case .stream(let bodyStream) = responseBody else {
                return XCTFail("Expected streaming body")
            }

            var observedStreamText = ""
            for try await chunk in bodyStream {
                observedStreamText += String(decoding: chunk, as: UTF8.self)
                if observedStreamText.contains(#""type":"response.failed""#) {
                    break
                }
            }
            XCTAssertTrue(observedStreamText.contains(#""type":"response.failed""#))
            responseBody = nil

            try await Task.sleep(for: .milliseconds(200))

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            XCTAssertEqual(logs.entries.count, 1)
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertEqual(entry.failureCategory, "upstream")
            XCTAssertTrue(entry.errorSummary?.contains("response.failed") == true)
            XCTAssertTrue(entry.errorSummary?.contains("high demand") == true)
        }
    }

    func testResponsesStreamClientCancellationRecordsCancelledTrace() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeHangingResponsesStreamUpstreamApplication(
            chunks: [
                "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_cancelled\",\"created_at\":1710000000}}\n\n",
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello before cancellation\"}\n\n",
            ]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Cancelled Responses",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-stream-cancelled",
                    enabled: true
                )
            )

            let proxyKey = try await harness.controller.authenticateProxyAPIKey(harness.config.proxyAPIKey)
            let stream = try await harness.controller.proxyResponses(
                body: Data(#"{"model":"gpt-5.5","input":"hello","stream":true}"#.utf8),
                proxyKey: proxyKey,
                apiKeyValue: harness.config.proxyAPIKey
            )
            XCTAssertEqual(stream.statusCode, 200)
            var responseBody: ProxyHTTPResponse.Body? = stream.body
            guard case .stream(let bodyStream) = responseBody else {
                return XCTFail("Expected streaming body")
            }

            let consumer = Task {
                do {
                    for try await _ in bodyStream {}
                } catch {}
            }
            try await Task.sleep(for: .milliseconds(100))
            consumer.cancel()
            _ = await consumer.result
            responseBody = nil

            try await Task.sleep(for: .milliseconds(300))

            let logs = try harness.controller.store.loadRequestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            XCTAssertEqual(logs.entries.count, 1)
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertFalse(entry.success)
            XCTAssertEqual(entry.failureCategory, "cancelled")
            XCTAssertTrue(entry.errorSummary?.contains("client_cancelled") == true)
        }
    }

    func testGeminiStreamGenerateContentRejectsManualCompatibleAccountBeforeUpstream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Manual Gemini Compatible",
                    providerPreset: .googleGeminiCompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai",
                    apiKey: "sk-gemini-compatible",
                    enabled: true
                )
            )

            let stream = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:streamGenerateContent",
                    body: """
                    {
                      "contents": [
                        {
                          "role": "user",
                          "parts": [{"text": "Summarize the project"}]
                        }
                      ],
                      "tools": [
                        {
                          "functionDeclarations": [
                            {
                              "name": "run_command",
                              "parameters": {
                                "type": "object",
                                "properties": {
                                  "command": {"type": "string"}
                                },
                                "required": ["command"]
                              }
                            }
                          ]
                        }
                      ],
                      "generationConfig": {
                        "thinkingConfig": {"includeThoughts": true}
                      }
                    }
                    """,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-stream-manual",
                    ]
                ),
                kind: .publicAPI
            )
            let streamBody = try await Self.data(from: stream.body)
            let streamText = Self.string(from: streamBody)
            let errorMessage = try Self.errorMessage(from: streamBody)

            XCTAssertEqual(stream.statusCode, 400, streamText)
            Self.assertGeminiRequiresGoogleLoginMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testGeminiStreamGenerateContentRejectsNonCLISessionBeforeUpstream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                )
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let stream = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:streamGenerateContent",
                    body: """
                    {
                      "contents": [
                        {
                          "role": "user",
                          "parts": [{"text": "Summarize the project"}]
                        }
                      ],
                      "tools": [
                        {
                          "functionDeclarations": [
                            {
                              "name": "run_command",
                              "parameters": {
                                "type": "object",
                                "properties": {
                                  "command": {"type": "string"}
                                },
                                "required": ["command"]
                              }
                            }
                          ]
                        }
                      ],
                      "generationConfig": {
                        "thinkingConfig": {"includeThoughts": true}
                      }
                    }
                    """,
                    proxyKey: "sk-local-gemini-only"
                ),
                kind: .publicAPI
            )
            let streamBody = try await Self.data(from: stream.body)
            let streamText = Self.string(from: streamBody)
            let errorMessage = try Self.errorMessage(from: streamBody)

            XCTAssertEqual(stream.statusCode, 400, streamText)
            Self.assertGeminiCLIOnlyMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.generateHits, 0)
            XCTAssertEqual(snapshot.countTokensHits, 0)
        }
    }

    func testTransportSafeStreamSwallowsLateThrowAfterPartialChunk() async throws {
        let original = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: partial\n\n".utf8))
            continuation.finish(throwing: MockStreamError(message: "terminated"))
        }

        let safe = DaemonHTTPService.transportSafeStream(original)

        var collected = Data()
        for try await chunk in safe {
            collected.append(chunk)
        }

        XCTAssertEqual(Self.string(from: collected), "data: partial\n\n")
    }

    func testTransportSafeStreamStillThrowsBeforeAnyChunkIsWritten() async throws {
        let original = AsyncThrowingStream<Data, Error> { continuation in
            continuation.finish(throwing: MockStreamError(message: "terminated"))
        }

        let safe = DaemonHTTPService.transportSafeStream(original)

        do {
            _ = try await Self.data(from: .stream(safe))
            XCTFail("Expected stream to throw before any chunk was emitted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "terminated")
        }
    }

    func testResponsesProxyMarksUsageLimitAccountAndSkipsItUntilReset() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let hitCounter = UpstreamHitCounter()
        let resetAt: Int64 = Helpers.now() + 604_800
        let upstream = Self.makeUsageLimitFallbackUpstreamApplication(counter: hitCounter, resetAt: resetAt)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "quota-auth",
                    content: Self.chatGPTAuthJSON(
                        principalID: "principal-quota",
                        accountID: "quota-account",
                        email: "quota@example.com"
                    ),
                    label: "A Quota OAuth"
                ),
                .init(
                    source: "fallback-auth",
                    content: Self.chatGPTAuthJSON(
                        principalID: "principal-fallback",
                        accountID: "fallback-account",
                        email: "fallback@example.com"
                    ),
                    label: "Z Fallback OAuth"
                ),
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"object\":\"response\""))

            let accounts = try await harness.controller.listAccounts()
            let quotaAccount = try XCTUnwrap(accounts.first(where: { $0.accountID == "quota-account" }))
            XCTAssertEqual(quotaAccount.usage?.oneWeek?.usedPercent, 100)
            XCTAssertEqual(quotaAccount.usage?.oneWeek?.resetAt, resetAt)
            XCTAssertTrue(quotaAccount.usageError?.contains("usage_limit_reached") == true)

            let followup = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello again","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let followupBody = try await Self.data(from: followup.body)
            XCTAssertEqual(followup.statusCode, 200, Self.string(from: followupBody))

            let hits = await hitCounter.snapshot()
            XCTAssertEqual(hits.quotaAccountResponses, 1)
            XCTAssertEqual(hits.fallbackAccountResponses, 2)
        }
    }

    func testChatCompletionsProxySupportsNonStreamAndStream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let requestJSON = #"""
            {
              "model": "gpt-5.4",
              "messages": [
                {"role": "system", "content": "You are helpful"},
                {"role": "user", "content": "Say hello"}
              ]
            }
            """#

            let nonStream = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/chat/completions", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            XCTAssertEqual(nonStream.statusCode, 200)
            let nonStreamBody = try await Self.data(from: nonStream.body)
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"object\":\"chat.completion\""))
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"content\":\"Hello world\""))

            let streamRequestJSON = #"""
            {
              "model": "gpt-5.4",
              "stream": true,
              "messages": [
                {"role": "user", "content": "Say hello"}
              ]
            }
            """#
            let stream = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/chat/completions", body: streamRequestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            XCTAssertEqual(stream.statusCode, 200)
            let streamBody = try await Self.data(from: stream.body)
            XCTAssertTrue(Self.string(from: streamBody).contains("\"chat.completion.chunk\""))
            XCTAssertTrue(Self.string(from: streamBody).contains("data: [DONE]"))
        }
    }

    func testAliyunPresetSupportsResponsesChatCompletionsAndAnthropicMessagesViaChatCompletionsAdapter() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AliyunCodingPlanProbe()
        let upstream = Self.makeAliyunCodingPlanUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Aliyun Coding Plan",
                    providerPreset: .aliyunQwenCodingPlan,
                    baseURL: "\(baseURL)/v1",
                    apiKey: "sk-aliyun-runtime",
                    enabled: true
                )
            )

            let responses = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let responsesBody = try await Self.data(from: responses.body)
            XCTAssertEqual(responses.statusCode, 200, Self.string(from: responsesBody))
            XCTAssertTrue(Self.string(from: responsesBody).contains("Aliyun route"))

            let chatStream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"gpt-5.4","messages":[{"role":"user","content":"hello"}],"stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let chatStreamBody = try await Self.data(from: chatStream.body)
            XCTAssertEqual(chatStream.statusCode, 200, Self.string(from: chatStreamBody))
            XCTAssertTrue(Self.string(from: chatStreamBody).contains("\"chat.completion.chunk\""))
            XCTAssertTrue(Self.string(from: chatStreamBody).contains("Aliyun "))
            XCTAssertTrue(Self.string(from: chatStreamBody).contains("stream"))

            let anthropic = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
                    ]
                ),
                kind: .publicAPI
            )
            let anthropicBody = try await Self.data(from: anthropic.body)
            XCTAssertEqual(anthropic.statusCode, 200, Self.string(from: anthropicBody))
            XCTAssertTrue(Self.string(from: anthropicBody).contains(#""type":"message""#))
            XCTAssertTrue(Self.string(from: anthropicBody).contains("Aliyun route"))

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, 1)
            XCTAssertEqual(snapshot.chatHits, 4)
            XCTAssertTrue(
                snapshot.requestBodies.allSatisfy { $0.contains(#""model":"qwen"#) || $0.contains(#""model":"glm"#) },
                snapshot.requestBodies.joined(separator: "\n---\n")
            )
            XCTAssertTrue(snapshot.requestBodies[1].contains(#""role":"user""#))
            XCTAssertTrue(snapshot.requestBodies[1].contains(#""content":"hello""#))
            XCTAssertTrue(snapshot.requestBodies[2].contains(#""stream":true"#))
        }
    }

    func testProxyTestConsoleCustomAliyunModelPassesThroughResponsesAndChatCompletions() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AliyunCodingPlanProbe()
        let upstream = Self.makeAliyunCodingPlanUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Aliyun Coding Plan",
                    providerPreset: .aliyunQwenCodingPlan,
                    baseURL: "\(baseURL)/v1",
                    apiKey: "sk-aliyun-runtime",
                    enabled: true
                )
            )

            let proxyTestHeaders = [
                ProxyHeaderName.proxyTestConsole: "1",
            ]

            let responses = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"qwen3.6-plus","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: proxyTestHeaders
                ),
                kind: .publicAPI
            )
            let responsesBody = try await Self.data(from: responses.body)
            XCTAssertEqual(responses.statusCode, 200, Self.string(from: responsesBody))
            XCTAssertTrue(Self.string(from: responsesBody).contains("Aliyun route"))

            let chat = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"qwen3.6-plus","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: proxyTestHeaders
                ),
                kind: .publicAPI
            )
            let chatBody = try await Self.data(from: chat.body)
            XCTAssertEqual(chat.statusCode, 200, Self.string(from: chatBody))
            XCTAssertTrue(Self.string(from: chatBody).contains("Aliyun route"))

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits, 3)
            XCTAssertTrue(snapshot.requestBodies.suffix(2).allSatisfy { $0.contains(#""model":"qwen3.6-plus""#) })
        }
    }

    func testDiscoveredAliyunModelWithoutProxyTestHeaderIsAccepted() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AliyunCodingPlanProbe()
        let upstream = Self.makeAliyunCodingPlanUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Aliyun Coding Plan",
                    providerPreset: .aliyunQwenCodingPlan,
                    baseURL: "\(baseURL)/v1",
                    apiKey: "sk-aliyun-runtime",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"qwen3.6-plus","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 200, text)
            XCTAssertTrue(text.contains("Aliyun route"))

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits - baseline.chatHits, 1)
            XCTAssertTrue(snapshot.requestBodies.last?.contains(#""model":"qwen3.6-plus""#) == true)
        }
    }

    func testFutureModelIsAcceptedAndPreservedForResponsesRoute() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = ResponsesRequestProbe()
        let upstream = Self.makeOpenAIResponsesProbeApplication(
            probe: probe,
            models: ["gpt-5.5"]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Dynamic Responses OpenAI",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dynamic-responses",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-6","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let responseBody = try await Self.data(from: response.body)

            XCTAssertEqual(response.statusCode, 200, Self.string(from: responseBody))
            XCTAssertTrue(Self.string(from: responseBody).contains("OpenAI route"))

            let snapshot = await probe.snapshot()
            let runtimeBodies = Array(snapshot.requestBodies.dropFirst(baseline.requestBodies.count))
            XCTAssertEqual(runtimeBodies.count, 1)
            XCTAssertTrue(runtimeBodies[0].contains(#""model":"gpt-6""#))
        }
    }

    func testFutureModelIsAcceptedAndPreservedForChatCompletionsRoute() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            listedModels: ["gpt-5.5"]
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Dynamic Chat OpenAI",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dynamic-chat",
                    enabled: true
                )
            )

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"gpt-6","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let responseBody = try await Self.data(from: response.body)

            XCTAssertEqual(response.statusCode, 200, Self.string(from: responseBody))
            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.responsesHits, 2)
            XCTAssertTrue(snapshot.responsesRequestBodies.last?.contains(#""model":"gpt-6""#) == true)
        }
    }

    func testGeminiPresetUsesCompatibilityRootForValidationAndChatCompletionsAdapters() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Gemini Compatible","provider_preset":"google_gemini_compatible","base_url":"\(baseURL)","api_key":"sk-gemini-runtime","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
            let added = try Helpers.readJSON(AccountSummary.self, from: addBody)
            XCTAssertEqual(added.authMode, .openAIAPIKey)
            XCTAssertEqual(added.providerPreset, .googleGeminiCompatible)
            XCTAssertEqual(added.upstreamBaseURL, baseURL)

            let refreshResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/\(added.id)/usage/refresh",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let refreshBody = try await Self.data(from: refreshResponse.body)
            XCTAssertEqual(refreshResponse.statusCode, 200, Self.string(from: refreshBody))
            let refreshed = try Helpers.readJSON(AccountSummary.self, from: refreshBody)
            XCTAssertEqual(refreshed.providerPreset, .googleGeminiCompatible)
            XCTAssertNil(refreshed.usageError)

            let responses = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4-mini","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let responsesBody = try await Self.data(from: responses.body)
            XCTAssertEqual(responses.statusCode, 200, Self.string(from: responsesBody))
            XCTAssertTrue(Self.string(from: responsesBody).contains("Gemini route"))

            let anthropic = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
                    ]
                ),
                kind: .publicAPI
            )
            let anthropicBody = try await Self.data(from: anthropic.body)
            XCTAssertEqual(anthropic.statusCode, 200, Self.string(from: anthropicBody))
            XCTAssertTrue(Self.string(from: anthropicBody).contains(#""type":"message""#))
            XCTAssertTrue(Self.string(from: anthropicBody).contains("Gemini route"))

            let snapshot = await probe.snapshot()
            XCTAssertGreaterThanOrEqual(snapshot.modelsHits, 2)
            XCTAssertEqual(snapshot.chatHits, 2)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer sk-gemini-runtime")
            XCTAssertTrue(snapshot.requestBodies.contains(where: { $0.contains(#""model":"gemini-2.5-flash-lite""#) }))
            XCTAssertTrue(snapshot.requestBodies.contains(where: { $0.contains(#""model":"gemini-2.5-flash""#) }))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            XCTAssertEqual(logs.entries.count, 2)
            XCTAssertEqual(Set(logs.entries.map(\.model)), Set(["gpt-5.4-mini", "claude-sonnet-4-5"]))
            XCTAssertEqual(Set(logs.entries.compactMap(\.actualModel)), Set(["gemini-2.5-flash-lite", "gemini-2.5-flash"]))
        }
    }

    func testBootstrapRepairsStoredLegacyGenericGeminiAccount() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let secretStore = SecretStore(dataDirectory: dataDirectory)
        let store = try SQLiteStore(dataDirectory: dataDirectory, secretStore: secretStore)
        let legacy = try Self.makeLegacyGenericGeminiManualAPIKeyRecord(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "sk-gemini-bootstrap",
            label: "Legacy Gemini Bootstrap"
        )
        XCTAssertFalse(try store.upsertAccount(legacy))

        let controller = try Self.makeController(dataDirectory: dataDirectory)
        try await controller.bootstrap()

        let repaired = try controller.store.loadAccountRecord(id: legacy.id)
        XCTAssertEqual(repaired.accountKey, legacy.accountKey)
        XCTAssertEqual(repaired.providerPreset, .googleGeminiCompatible)
        XCTAssertEqual(AuthService.extractAuthMetadata(from: repaired.authJSON).providerPreset, .googleGeminiCompatible)
    }

    func testResponsesProxyRepairsPinnedStoredGeminiPresetFieldsBeforeRouting() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let legacy = try Self.makeStoredGeminiRecordWithStaleGenericPreset(
                baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai",
                apiKey: "sk-gemini-legacy-runtime",
                label: "Legacy Gemini Runtime"
            )
            XCTAssertFalse(try harness.controller.store.upsertAccount(legacy))

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4-mini","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: legacy.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("Gemini route"))

            let repaired = try harness.controller.store.loadAccountRecord(id: legacy.id)
            XCTAssertEqual(repaired.providerPreset, .googleGeminiCompatible)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits, 1)
            XCTAssertEqual(snapshot.lastAuthorization, "Bearer sk-gemini-legacy-runtime")
            XCTAssertTrue(snapshot.requestBodies.contains(where: { $0.contains(#""model":"gemini-2.5-flash-lite""#) }))
        }
    }

    func testResponsesProxyPinnedDamagedLegacyGenericGeminiAccountReturnsConfigurationError() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var legacy = try Self.makeLegacyGenericGeminiManualAPIKeyRecord(
            baseURL: OpenAICompatibleUpstream.defaultGeminiBaseURL,
            apiKey: "sk-gemini-broken-runtime",
            label: "Legacy Gemini Broken"
        )
        legacy.authJSON = "{"
        XCTAssertFalse(try harness.controller.store.upsertAccount(legacy))

        let response = await harness.service.handle(
            Self.makePublicRequest(
                path: "/v1/responses",
                body: #"{"model":"gpt-5.4-mini","input":"hello","stream":false}"#,
                proxyKey: harness.config.proxyAPIKey,
                extraHeaders: [ProxyHeaderName.testAccountKey: legacy.accountKey]
            ),
            kind: .publicAPI
        )
        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertTrue(Self.string(from: body).contains("指定的测试账号配置有误"))
        XCTAssertTrue(
            Self.string(from: body).contains(OpenAICompatibleUpstream.geminiCompatibilityRootRequiresGeminiPresetMessage)
        )
    }

    func testGeminiPublicRoutesKeepStaticModelCatalogButRejectManualCompatiblePOSTRoutes() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Gemini CLI Runtime","provider_preset":"google_gemini_compatible","base_url":"\(baseURL)","api_key":"sk-gemini-runtime","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
            let added = try Helpers.readJSON(AccountSummary.self, from: addBody)

            let refreshResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/\(added.id)/usage/refresh",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let refreshBody = try await Self.data(from: refreshResponse.body)
            XCTAssertEqual(refreshResponse.statusCode, 200, Self.string(from: refreshBody))

            let models = await harness.service.handle(
                DaemonHTTPService.Request(
                    method: "GET",
                    target: "/v1beta/models?key=\(harness.config.proxyAPIKey)",
                    path: "/v1beta/models",
                    headers: [
                        "accept": "application/json",
                    ],
                    body: Data()
                ),
                kind: .publicAPI
            )
            let modelsBody = try await Self.data(from: models.body)
            XCTAssertEqual(models.statusCode, 200, Self.string(from: modelsBody))
            let modelsPayload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: modelsBody) as? [String: Any]
            )
            let listedModels = try XCTUnwrap(modelsPayload["models"] as? [[String: Any]])
            XCTAssertTrue(
                listedModels.contains(where: {
                    ($0["name"] as? String) == "models/gemini-2.5-pro"
                })
            )
            XCTAssertTrue(
                listedModels.contains(where: {
                    ($0["name"] as? String) == "models/gemini-2.0-flash"
                })
            )
            XCTAssertTrue(
                listedModels.contains(where: {
                    ($0["name"] as? String) == "models/gemini-3.1-pro-preview"
                })
            )

            let generate = await harness.service.handle(
                DaemonHTTPService.Request(
                    method: "POST",
                    target: "/v1beta/models/gemini-2.5-pro:generateContent",
                    path: "/v1beta/models/gemini-2.5-pro:generateContent",
                    headers: [
                        "x-goog-api-key": harness.config.proxyAPIKey,
                        "content-type": "application/json",
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-static-models",
                    ],
                    body: Data(#"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#.utf8)
                ),
                kind: .publicAPI
            )
            let generateBody = try await Self.data(from: generate.body)
            let generateText = Self.string(from: generateBody)
            let errorMessage = try Self.errorMessage(from: generateBody)
            XCTAssertEqual(generate.statusCode, 400, generateText)
            Self.assertGeminiRequiresGoogleLoginMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, 2)
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testGeminiPublicRoutesUseGoogleGeminiLoginErrorWhenOnlyCompatibleAccountsExist() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Gemini Stable Default","provider_preset":"google_gemini_compatible","base_url":"\(baseURL)","api_key":"sk-gemini-stable","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))

            let generate = await harness.service.handle(
                DaemonHTTPService.Request(
                    method: "POST",
                    target: "/v1beta/models/gemini-2.5-flash:generateContent",
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    headers: [
                        "x-goog-api-key": harness.config.proxyAPIKey,
                        "content-type": "application/json",
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-login-required",
                    ],
                    body: Data(#"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#.utf8)
                ),
                kind: .publicAPI
            )
            let generateBody = try await Self.data(from: generate.body)
            let generateText = Self.string(from: generateBody)
            let errorMessage = try Self.errorMessage(from: generateBody)
            XCTAssertEqual(generate.statusCode, 400, generateText)
            Self.assertGeminiRequiresGoogleLoginMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testGeminiPublicRoutesRejectManualGeminiCompatibleAccountsForCLISession() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai"
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Gemini Compatible",
                    providerPreset: .googleGeminiCompatible,
                    baseURL: baseURL,
                    apiKey: "sk-gemini-compatible-runtime",
                    enabled: true
                )
            )

            let models = await harness.service.handle(
                DaemonHTTPService.Request(
                    method: "GET",
                    target: "/v1beta/models?key=\(harness.config.proxyAPIKey)",
                    path: "/v1beta/models",
                    headers: ["accept": "application/json"],
                    body: Data()
                ),
                kind: .publicAPI
            )
            let modelsBody = try await Self.data(from: models.body)
            XCTAssertEqual(models.statusCode, 200, Self.string(from: modelsBody))
            let modelNames = try Self.geminiModelNames(from: modelsBody)
            XCTAssertTrue(modelNames.contains("models/gemini-2.5-flash"), Self.string(from: modelsBody))

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-compatible",
                    ]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)
            let errorMessage = try Self.errorMessage(from: body)

            XCTAssertEqual(response.statusCode, 400, text)
            Self.assertGeminiRequiresGoogleLoginMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testGeminiPublicRoutesRejectGenericOpenAIAccountsForCLISession() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Generic OpenAI",
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-generic-openai-runtime",
                    enabled: true
                )
            )
            let baseline = await probe.snapshot()

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Inspect the project"}]}]}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-generic",
                    ]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)
            let errorMessage = try Self.errorMessage(from: body)

            XCTAssertEqual(response.statusCode, 400, text)
            Self.assertGeminiRequiresGoogleLoginMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits - baseline.chatHits, 0)
            XCTAssertEqual(snapshot.responsesHits - baseline.responsesHits, 0)
        }
    }

    func testGeminiPublicRoutesRejectNonCLISessionEvenWithGeminiOAuthAccount() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                    proxyKey: "sk-local-gemini-only"
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)
            let errorMessage = try Self.errorMessage(from: body)

            XCTAssertEqual(response.statusCode, 400, text)
            Self.assertGeminiCLIOnlyMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.generateHits, 0)
            XCTAssertEqual(snapshot.countTokensHits, 0)
        }
    }

    func testGeminiPublicRoutesRequireGoogleGeminiLoginForCountTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Gemini Compatible CountTokens",
                    providerPreset: .googleGeminiCompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai",
                    apiKey: "sk-gemini-compatible-count",
                    enabled: true
                )
            )

            let response = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:countTokens",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Count me"}]}]}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-count",
                    ]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)
            let errorMessage = try Self.errorMessage(from: body)

            XCTAssertEqual(response.statusCode, 400, text)
            Self.assertGeminiRequiresGoogleLoginMessage(errorMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testAdminProxyTestRunSupportsGeminiOAuthSelectedAccount() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                )
            ])
            let accounts = try await harness.controller.listAccounts()
            let selectedAccount = try XCTUnwrap(accounts.first(where: { $0.authMode == .geminiOAuth }))

            let payload = AdminProxyTestRunRequest(
                endpoint: .geminiGenerateContent,
                model: "gemini-2.5-flash",
                payloadJSON: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                stream: false,
                selectedAccountKey: selectedAccount.accountKey
            )
            let encodedPayload = try Helpers.encodeJSON(payload, pretty: false)

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/proxy-test/run",
                    body: String(decoding: encodedPayload, as: UTF8.self),
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 200, text)
            XCTAssertTrue(text.contains("Google AI Pro Route"), text)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.generateHits, 1)
            XCTAssertEqual(snapshot.countTokensHits, 0)
        }
    }

    func testAdminProxyTestRunSupportsResponsesWithProxyAPIKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let payload = AdminProxyTestRunRequest(
                endpoint: .responses,
                model: "gpt-5.4",
                payloadJSON: #"{"model":"gpt-5.4","input":"Say hello","stream":false}"#,
                stream: false,
                proxyAPIKey: harness.config.proxyAPIKey
            )
            let encodedPayload = try Helpers.encodeJSON(payload, pretty: false)

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/proxy-test/run",
                    body: String(decoding: encodedPayload, as: UTF8.self),
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 200, text)
            XCTAssertTrue(text.contains("\"object\":\"response\""), text)
            XCTAssertTrue(text.contains("Hello world"), text)
        }
    }

    func testAdminProxyTestRunSurfacesRecordedCandidateFailureMessage() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeGenericOpenAIErrorApplication(
            status: .unauthorized,
            body: #"{"error":{"message":"Missing proxy api key.","type":"authentication_error"}}"#
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            let account = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Broken Generic",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-broken-generic",
                    enabled: true
                )
            )
            let payload = AdminProxyTestRunRequest(
                endpoint: .responses,
                model: "gpt-5.4",
                payloadJSON: #"{"model":"gpt-5.4","input":"Say hello","stream":false}"#,
                stream: false,
                selectedAccountKey: account.accountKey,
                proxyAPIKey: harness.config.proxyAPIKey
            )
            let encodedPayload = try Helpers.encodeJSON(payload, pretty: false)

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/proxy-test/run",
                    body: String(decoding: encodedPayload, as: UTF8.self),
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 500, text)
            XCTAssertTrue(text.contains("Broken Generic: Missing proxy api key."), text)
            XCTAssertFalse(text.contains("RecordedCandidateFailure"), text)
        }
    }

    func testAdminProxyTestRunStringErrorIsRecordedInRequestLogs() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeGenericOpenAIErrorApplication(
            status: .tooManyRequests,
            body: #"{"error":"too many requests"}"#
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"
            let account = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Limited Generic",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-limited-generic",
                    enabled: true
                )
            )
            let payload = AdminProxyTestRunRequest(
                endpoint: .responses,
                model: "gpt-5.4",
                payloadJSON: #"{"model":"gpt-5.4","input":"Say hello","stream":false}"#,
                stream: false,
                selectedAccountKey: account.accountKey,
                proxyAPIKey: harness.config.proxyAPIKey
            )
            let encodedPayload = try Helpers.encodeJSON(payload, pretty: false)

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/proxy-test/run",
                    body: String(decoding: encodedPayload, as: UTF8.self),
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 500, text)
            XCTAssertTrue(text.contains("Limited Generic: too many requests"), text)
            XCTAssertFalse(text.contains("RecordedCandidateFailure"), text)

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            XCTAssertEqual(logs.entries.count, 1)
            XCTAssertEqual(logs.entries.first?.success, false)
            XCTAssertTrue(logs.entries.first?.errorSummary?.contains("too many requests") == true)
        }
    }

    func testAdminProxyTestRunSupportsAnthropicMessagesWithProxyAPIKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Anthropic API Key","provider_preset":"anthropic_api_compatible","base_url":"\(baseURL)/v1","api_key":"sk-anthropic-runtime","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))

            let payload = AdminProxyTestRunRequest(
                endpoint: .anthropicMessages,
                model: "claude-sonnet-4-6",
                payloadJSON: #"{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":[{"type":"text","text":"Say hello"}]}],"stream":false}"#,
                stream: false,
                proxyAPIKey: harness.config.proxyAPIKey,
                anthropicVersion: AnthropicTranscoder.defaultAnthropicVersion
            )
            let encodedPayload = try Helpers.encodeJSON(payload, pretty: false)

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/proxy-test/run",
                    body: String(decoding: encodedPayload, as: UTF8.self),
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            let text = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 200, text)
            XCTAssertTrue(text.contains("\"type\":\"message\""), text)
            XCTAssertTrue(text.contains("Anthropic model="), text)
        }
    }

    func testAdminRefreshUsageForStoredGoogleAIOAuthLikeGeminiCredentialReturnsLocalConfigurationErrorWithoutUpstreamHit() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai"
            let record = try Self.makeStoredGoogleGeminiOAuthLikeRecord(
                baseURL: baseURL,
                apiKey: "AQ.test-google-session",
                label: "Gemini AI Pro"
            )
            XCTAssertFalse(try harness.controller.store.upsertAccount(record))

            let response = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/\(record.id)/usage/refresh",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)

            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            let refreshed = try Helpers.readJSON(AccountSummary.self, from: body)
            XCTAssertEqual(refreshed.usageError, OpenAICompatibleUpstream.googleGeminiAPIKeyOnlyMessage)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, 0)
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testResponsesProxyPinnedStoredGoogleAIOAuthLikeGeminiCredentialReturnsLocalConfigurationErrorWithoutUpstreamHit() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiCompatibilityProbe()
        let upstream = Self.makeGeminiCompatibleUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1beta/openai"
            let record = try Self.makeStoredGoogleGeminiOAuthLikeRecord(
                baseURL: baseURL,
                apiKey: "AQ.test-google-session",
                label: "Gemini AI Pro"
            )
            XCTAssertFalse(try harness.controller.store.upsertAccount(record))

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4-mini","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [ProxyHeaderName.testAccountKey: record.accountKey]
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            let bodyText = Self.string(from: body)

            XCTAssertEqual(response.statusCode, 500, bodyText)
            XCTAssertTrue(bodyText.lowercased().contains("gemini api key"), bodyText)
            XCTAssertTrue(
                bodyText.lowercased().contains("google")
                    || bodyText.lowercased().contains("google ai pro")
                    || bodyText.lowercased().contains("gemini cli"),
                bodyText
            )

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, 0)
            XCTAssertEqual(snapshot.chatHits, 0)
        }
    }

    func testAnthropicManualAPIKeyUsesNativeValidationMessagesCountTokensAndOpenAIBridge() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "primary-anthropic",
                label: "Anthropic Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .anthropic,
                enabled: true,
                createdAt: 1
            ),
        ]
        config.primaryProxyAPIKeyID = "primary-anthropic"
        _ = try await harness.controller.saveConfig(config)

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"

            let addResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/manual-api-key",
                    body: """
                    {"label":"Anthropic API Key","provider_preset":"anthropic_api_compatible","base_url":"\(baseURL)/v1","api_key":"sk-anthropic-runtime","enabled":true}
                    """,
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let addBody = try await Self.data(from: addResponse.body)
            XCTAssertEqual(addResponse.statusCode, 200, Self.string(from: addBody))
            let added = try Helpers.readJSON(AccountSummary.self, from: addBody)
            XCTAssertEqual(added.authMode, .anthropicAPIKey)
            XCTAssertEqual(added.providerPreset, .anthropicAPICompatible)
            XCTAssertEqual(added.upstreamBaseURL, baseURL)

            let refreshResponse = await harness.service.handle(
                Self.makeAdminRequest(
                    method: "POST",
                    path: "/admin/accounts/\(added.id)/usage/refresh",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            let refreshBody = try await Self.data(from: refreshResponse.body)
            XCTAssertEqual(refreshResponse.statusCode, 200, Self.string(from: refreshBody))
            let refreshed = try Helpers.readJSON(AccountSummary.self, from: refreshBody)
            XCTAssertEqual(refreshed.authMode, .anthropicAPIKey)
            XCTAssertNil(refreshed.usageError)

            let messagesRequest = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Say hello"}
                  ]
                }
              ],
              "stream": false
            }
            """#

            let messages = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: messagesRequest,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
                    ]
                ),
                kind: .publicAPI
            )
            let messagesBody = try await Self.data(from: messages.body)
            XCTAssertEqual(messages.statusCode, 200, Self.string(from: messagesBody))
            XCTAssertTrue(Self.string(from: messagesBody).contains("Anthropic native"))

            let countTokens = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages/count_tokens",
                    body: #"""
                    {
                      "model": "claude-sonnet-4-5",
                      "messages": [
                        {
                          "role": "user",
                          "content": [
                            {"type": "text", "text": "Count tokens"}
                          ]
                        }
                      ]
                    }
                    """#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: [
                        "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
                    ]
                ),
                kind: .publicAPI
            )
            let countTokensBody = try await Self.data(from: countTokens.body)
            XCTAssertEqual(countTokens.statusCode, 200, Self.string(from: countTokensBody))
            XCTAssertTrue(Self.string(from: countTokensBody).contains(#""input_tokens":11"#))

            let chatBridge = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"gpt-5.4","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let chatBridgeBody = try await Self.data(from: chatBridge.body)
            XCTAssertEqual(chatBridge.statusCode, 200, Self.string(from: chatBridgeBody))
            XCTAssertTrue(Self.string(from: chatBridgeBody).contains(#""object":"chat.completion""#))

            let snapshot = await probe.snapshot()
            XCTAssertGreaterThanOrEqual(snapshot.modelsHits, 2)
            XCTAssertEqual(snapshot.messagesHits, 2)
            XCTAssertEqual(snapshot.countTokensHits, 1)
            XCTAssertEqual(snapshot.lastAPIKey, "sk-anthropic-runtime")
            XCTAssertNil(snapshot.lastAuthorization)
            XCTAssertEqual(snapshot.lastAnthropicVersion, AnthropicTranscoder.defaultAnthropicVersion)
            XCTAssertNil(snapshot.lastAnthropicBeta)
        }
    }

    func testAnthropicManualAPIKeyRefreshFallsBackToCountTokensWhenModelsMissing() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(
            probe: probe,
            modelsStatus: .notFound
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"

            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Anthropic Fallback",
                    providerPreset: .anthropicAPICompatible,
                    baseURL: "\(baseURL)/v1",
                    apiKey: "sk-anthropic-fallback",
                    enabled: true
                )
            )
            XCTAssertEqual(added.authMode, .anthropicAPIKey)
            XCTAssertNil(added.usageError)

            _ = try await harness.controller.updateAccountModelRouting(
                id: added.id,
                input: UpdateAccountModelRoutingRequest(defaultTargetModel: "qwen3.6-plus")
            )

            let refreshed = try await harness.controller.refreshAccountUsage(id: added.id)
            XCTAssertEqual(refreshed.authMode, .anthropicAPIKey)
            XCTAssertNil(refreshed.usageError)

            let snapshot = await probe.snapshot()
            XCTAssertGreaterThanOrEqual(snapshot.modelsHits, 2)
            XCTAssertGreaterThanOrEqual(snapshot.messagesHits, 2)
            XCTAssertEqual(snapshot.countTokensHits, 0)
            XCTAssertTrue(snapshot.requestBodies.last?.contains(#""model":"qwen3.6-plus""#) == true)
        }
    }

    func testDashScopeAnthropicManualAccountStripsThinkingHistoryForMessagesAndCountTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "primary-anthropic",
                label: "Anthropic Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .anthropic,
                enabled: true,
                createdAt: 1
            ),
        ]
        config.primaryProxyAPIKeyID = "primary-anthropic"
        _ = try await harness.controller.saveConfig(config)

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://dashscope.aliyuncs.com.localhost:\(upstreamClient.port ?? 0)/v1"

            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "DashScope Anthropic API Key",
                    providerPreset: .anthropicAPICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-dashscope-thinking",
                    enabled: true
                )
            )
            XCTAssertEqual(added.authMode, .anthropicAPIKey)

            let headers = [
                "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
            ]
            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [{"type": "text", "text": "hello"}]
                },
                {
                  "role": "assistant",
                  "content": [
                    {"type": "thinking", "thinking": "internal"},
                    {"type": "text", "text": "visible answer"},
                    {"type": "redacted_thinking", "data": "hidden"}
                  ]
                },
                {
                  "role": "assistant",
                  "content": [
                    {"type": "thinking", "thinking": "drop me"}
                  ]
                },
                {
                  "role": "user",
                  "content": [{"type": "text", "text": "next"}]
                }
              ],
              "max_tokens": 64,
              "stream": false
            }
            """#

            let messages = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: requestJSON,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )
            let messagesBody = try await Self.data(from: messages.body)
            XCTAssertEqual(messages.statusCode, 200, Self.string(from: messagesBody))

            let countTokens = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages/count_tokens",
                    body: requestJSON,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )
            let countTokensBody = try await Self.data(from: countTokens.body)
            XCTAssertEqual(countTokens.statusCode, 200, Self.string(from: countTokensBody))

            let snapshot = await probe.snapshot()
            let routedBodies = Array(snapshot.requestBodies.suffix(2))
            XCTAssertEqual(snapshot.messagesHits, 1)
            XCTAssertEqual(snapshot.countTokensHits, 1)
            XCTAssertEqual(routedBodies.count, 2)
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""text":"visible answer""#) })
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""text":"next""#) })
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""model":"claude-sonnet-4-5""#) })
            XCTAssertFalse(routedBodies.contains(where: { $0.contains(#""type":"thinking""#) }))
            XCTAssertFalse(routedBodies.contains(where: { $0.contains(#""type":"redacted_thinking""#) }))
            XCTAssertFalse(routedBodies.contains(where: { $0.contains("drop me") }))
        }
    }

    func testOfficialAnthropicManualAccountPreservesThinkingHistoryForMessagesAndCountTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "primary-anthropic",
                label: "Anthropic Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .anthropic,
                enabled: true,
                createdAt: 1
            ),
        ]
        config.primaryProxyAPIKeyID = "primary-anthropic"
        _ = try await harness.controller.saveConfig(config)

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://api.anthropic.com.localhost:\(upstreamClient.port ?? 0)/v1"

            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Official Anthropic API Key",
                    providerPreset: .anthropicAPICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-official-thinking",
                    enabled: true
                )
            )
            XCTAssertEqual(added.authMode, .anthropicAPIKey)

            let headers = [
                "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
            ]
            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [{"type": "text", "text": "hello"}]
                },
                {
                  "role": "assistant",
                  "content": [
                    {"type": "thinking", "thinking": "internal"},
                    {"type": "text", "text": "visible answer"},
                    {"type": "redacted_thinking", "data": "hidden"}
                  ]
                },
                {
                  "role": "user",
                  "content": [{"type": "text", "text": "next"}]
                }
              ],
              "max_tokens": 64,
              "stream": false
            }
            """#

            let messages = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: requestJSON,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )
            let messagesBody = try await Self.data(from: messages.body)
            XCTAssertEqual(messages.statusCode, 200, Self.string(from: messagesBody))

            let countTokens = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages/count_tokens",
                    body: requestJSON,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: headers
                ),
                kind: .publicAPI
            )
            let countTokensBody = try await Self.data(from: countTokens.body)
            XCTAssertEqual(countTokens.statusCode, 200, Self.string(from: countTokensBody))

            let snapshot = await probe.snapshot()
            let routedBodies = Array(snapshot.requestBodies.suffix(2))
            XCTAssertEqual(snapshot.messagesHits, 1)
            XCTAssertEqual(snapshot.countTokensHits, 1)
            XCTAssertEqual(routedBodies.count, 2)
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""type":"thinking""#) })
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""type":"redacted_thinking""#) })
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""text":"visible answer""#) })
        }
    }

    func testAnthropicMessagesProxySupportsNonStreamAndStream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "system": "You are helpful",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Say hello"}
                  ]
                }
              ],
              "stream": false
            }
            """#

            let nonStream = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let nonStreamBody = try await Self.data(from: nonStream.body)
            XCTAssertEqual(nonStream.statusCode, 200, Self.string(from: nonStreamBody))
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"type\":\"message\""))
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"model\":\"claude-sonnet-4-5\""))
            XCTAssertTrue(Self.string(from: nonStreamBody).contains("\"text\":\"Hello world\""))

            let streamRequestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Say hello"}
                  ]
                }
              ],
              "stream": true
            }
            """#
            let stream = await harness.service.handle(
                Self.makePublicBearerRequest(path: "/v1/messages", body: streamRequestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            XCTAssertEqual(stream.statusCode, 200)
            let streamBody = try await Self.data(from: stream.body)
            let streamText = Self.string(from: streamBody)
            XCTAssertTrue(streamText.contains("event: message_start"))
            XCTAssertTrue(streamText.contains("event: content_block_delta"))
            XCTAssertTrue(streamText.contains("event: message_stop"))
            XCTAssertTrue(streamText.contains("\"text\":\"Hello world\""))
        }
    }

    func testAnthropicMessagesStreamSupportsProxyAuthorizationPingAndToolUse() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeDelayedToolStreamUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Run the tool"}
                  ]
                }
              ],
              "stream": true
            }
            """#

            let stream = await harness.service.handle(
                Self.makePublicProxyAuthorizationRequest(
                    path: "/v1/messages",
                    body: requestJSON,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(stream.statusCode, 200)
            let streamBody = try await Self.data(from: stream.body)
            let streamText = Self.string(from: streamBody)

            XCTAssertTrue(streamText.contains("event: message_start"))
            XCTAssertTrue(streamText.contains("event: ping"))
            XCTAssertTrue(streamText.contains(#""type":"tool_use""#))
            XCTAssertTrue(streamText.contains(#""type":"input_json_delta""#))
            XCTAssertTrue(streamText.contains(#""stop_reason":"tool_use""#))
            XCTAssertTrue(streamText.contains(#""index":0"#))
        }
    }

    func testAnthropicCountTokensReturnsAnthropicShape() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Count tokens"}
                  ]
                }
              ]
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages/count_tokens", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"input_tokens\":3"))
        }
    }

    func testAnthropicMessagesProxyMapsAssistantHistoryTextToOutputText() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAssistantHistoryStrictUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "First question"}
                  ]
                },
                {
                  "role": "assistant",
                  "content": [
                    {"type": "text", "text": "First answer"}
                  ]
                },
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Second question"}
                  ]
                }
              ],
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"type\":\"message\""))
        }
    }

    func testAnthropicCountTokensMapsAssistantHistoryTextToOutputText() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAssistantHistoryStrictUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "First question"}
                  ]
                },
                {
                  "role": "assistant",
                  "content": [
                    {"type": "text", "text": "First answer"}
                  ]
                },
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Second question"}
                  ]
                }
              ]
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages/count_tokens", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"input_tokens\":3"))
        }
    }

    func testAnthropicRoutesReturnAnthropicErrorShapeWithoutProxyKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let response = await harness.service.handle(
            DaemonHTTPService.Request(
                method: "POST",
                target: "/v1/messages",
                path: "/v1/messages",
                headers: [
                    "content-type": "application/json",
                ],
                body: Data(#"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]}"#.utf8)
            ),
            kind: .publicAPI
        )

        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertTrue(Self.string(from: body).contains("\"type\":\"error\""))
        XCTAssertTrue(Self.string(from: body).contains("\"authentication_error\""))
    }

    func testOAuthAnthropicMessagesCompatibilityStripsUnsupportedParameters() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "system": "You are helpful",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Say hello"}
                  ]
                }
              ],
              "metadata": {
                "source": "claude-code"
              },
              "max_tokens": 256,
              "temperature": 0.5,
              "top_p": 0.9,
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"type\":\"message\""))
        }
    }

    func testOAuthAnthropicCountTokensCompatibilityStripsUnsupportedParameters() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Count tokens"}
                  ]
                }
              ],
              "metadata": {
                "source": "claude-code"
              },
              "max_tokens": 128
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages/count_tokens", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"input_tokens\":3"))
        }
    }

    func testOAuthAnthropicMessagesDefaultMappingAvoidsMiniModel() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let requestJSON = #"""
            {
              "model": "claude-3-5-haiku-latest",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Say hello"}
                  ]
                }
              ],
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"model\":\"claude-3-5-haiku-latest\""))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            XCTAssertEqual(logs.entries.count, 1)
            XCTAssertEqual(logs.entries.first?.model, "claude-3-5-haiku-latest")
            XCTAssertEqual(logs.entries.first?.actualModel, "gpt-5.5")
        }
    }

    func testOAuthAnthropicFutureSourceModelUsesDefaultTargetWhenUnmapped() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let requestJSON = #"""
            {
              "model": "claude-future-7",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Say hello"}
                  ]
                }
              ],
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"model\":\"claude-future-7\""))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            XCTAssertEqual(logs.entries.count, 1)
            XCTAssertEqual(logs.entries.first?.model, "claude-future-7")
            XCTAssertEqual(logs.entries.first?.actualModel, "gpt-5.5")
        }
    }

    func testOAuthAnthropicCountTokensUsesDefaultTargetWhenConfiguredTargetModelIsBlank() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            config.anthropicModelMappings = [
                .init(sourceModel: "claude-3-5-haiku-latest", targetModel: " "),
            ]
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let requestJSON = #"""
            {
              "model": "claude-3-5-haiku-latest",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Count tokens"}
                  ]
                }
              ]
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages/count_tokens", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"input_tokens\":3"))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            XCTAssertEqual(logs.entries.count, 1)
            XCTAssertEqual(logs.entries.first?.model, "claude-3-5-haiku-latest")
            XCTAssertEqual(logs.entries.first?.actualModel, "gpt-5.5")
        }
    }

    func testOAuthChatCompletionsCompatibilityStripsUnsupportedParameters() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let requestJSON = #"""
            {
              "model": "gpt-5.4",
              "messages": [
                {"role": "user", "content": "Say hello"}
              ],
              "max_tokens": 123,
              "temperature": 0.5,
              "top_p": 0.9,
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/chat/completions", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"object\":\"chat.completion\""))
        }
    }

    func testOpenAIAPIKeyPathKeepsParametersForOpenAIResponsesUpstream() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeStrictCompatibilityUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)/api.openai.com/v1"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "api-key-auth",
                    content: Self.openAIAPIKeyAuthJSON(baseURL: "http://localhost:\(upstreamClient.port ?? 0)/api.openai.com/v1"),
                    label: "API Key"
                )
            ])

            let requestJSON = #"""
            {
              "model": "gpt-5.4",
              "messages": [
                {"role": "user", "content": "Say hello"}
              ],
              "max_tokens": 123,
              "temperature": 0.5,
              "top_p": 0.9,
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/chat/completions", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("\"object\":\"chat.completion\""))
        }
    }

    func testAdminRequestLogsEndpointsReturnDetailedRowsAndFilters() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let nonStream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","reasoning":{"effort":"xhigh"},"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(nonStream.statusCode, 200)
            _ = try await Self.data(from: nonStream.body)

            let stream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(stream.statusCode, 200)
            _ = try await Self.data(from: stream.body)

            let chatStream = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"gpt-5.4","messages":[{"role":"user","content":"hello"}],"reasoning_effort":"medium","stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(chatStream.statusCode, 200)
            _ = try await Self.data(from: chatStream.body)

            let logsResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/requests",
                    query: "time_preset=7d&page=1&page_size=10",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(logsResponse.statusCode, 200)
            let logsBody = try await Self.data(from: logsResponse.body)
            let page = try Helpers.readJSON(RequestLogPage.self, from: logsBody)
            XCTAssertEqual(page.totalCount, 3)
            XCTAssertEqual(page.entries.count, 3)
            XCTAssertEqual(page.entries.first?.apiKey, harness.config.proxyAPIKey)
            XCTAssertTrue(page.entries.contains { $0.cacheHitTokens == 2 })
            XCTAssertEqual(Set(page.entries.compactMap(\.actualModel)), Set(["gpt-5.4"]))
            XCTAssertEqual(Set(page.entries.compactMap(\.reasoningEffort)), Set(["xhigh", "medium"]))

            let filterResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/request-filters",
                    query: "time_preset=7d",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(filterResponse.statusCode, 200)
            let filterBody = try await Self.data(from: filterResponse.body)
            let filters = try Helpers.readJSON(RequestLogFilterOptions.self, from: filterBody)
            XCTAssertEqual(filters.availableAPIKeys, [harness.config.proxyAPIKey])
            XCTAssertEqual(filters.availableModels, ["gpt-5.4"])

            let repeatedLogsResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/requests",
                    query: "time_preset=7d&page=1&page_size=10",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(repeatedLogsResponse.statusCode, 200)
            let repeatedLogsBody = try await Self.data(from: repeatedLogsResponse.body)
            let repeatedPage = try Helpers.readJSON(RequestLogPage.self, from: repeatedLogsBody)
            XCTAssertEqual(repeatedPage.totalCount, 3)
            XCTAssertEqual(repeatedPage.availableAPIKeys, [harness.config.proxyAPIKey])
            XCTAssertEqual(repeatedPage.availableModels, ["gpt-5.4"])

            let repeatedFilterResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/request-filters",
                    query: "time_preset=7d",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(repeatedFilterResponse.statusCode, 200)

            let exportResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/requests/export",
                    query: "time_preset=7d&sort_by=latency&sort_direction=asc&page=1&page_size=10",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(exportResponse.statusCode, 200)
            let exportBody = try await Self.data(from: exportResponse.body)
            let exportText = String(decoding: exportBody.dropFirst(3), as: UTF8.self)
            XCTAssertEqual(Array(exportBody.prefix(3)), [0xEF, 0xBB, 0xBF])
            XCTAssertTrue(exportText.contains("time,endpoint,upstream_url,client_source,model,actual_model,reasoning_effort,api_key"))
            XCTAssertTrue(exportText.contains(RequestLogPresentation.maskedAPIKey(harness.config.proxyAPIKey)))
            XCTAssertFalse(exportText.contains(",\(harness.config.proxyAPIKey),"))
        }
    }

    func testRequestLogsCaptureClientSourceClassificationSignals() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            func latestClientSource() throws -> RequestLogClientSource {
                let page = try harness.controller.store.loadRequestLogs(
                    query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
                )
                return try XCTUnwrap(page.entries.first).clientSource
            }

            let claudeResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"claude-route","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: ["x-claude-code-session-id": "claude-session-1"]
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(claudeResponse.statusCode, 200)
            _ = try await Self.data(from: claudeResponse.body)
            XCTAssertEqual(try latestClientSource(), .claudeCode)

            let geminiResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"gemini-route","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: ["x-gemini-api-privileged-user-id": "gemini-cli-user-1"]
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(geminiResponse.statusCode, 200)
            _ = try await Self.data(from: geminiResponse.body)
            XCTAssertEqual(try latestClientSource(), .gemini)

            let codexResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"codex-route","stream":false,"metadata":{"user_id":"{\"session_id\":\"session-42\",\"user_id\":\"dev-1\"}"}}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(codexResponse.statusCode, 200)
            _ = try await Self.data(from: codexResponse.body)
            XCTAssertEqual(try latestClientSource(), .codex)

            let otherResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"other-route","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(otherResponse.statusCode, 200)
            _ = try await Self.data(from: otherResponse.body)
            XCTAssertEqual(try latestClientSource(), .other)

            let filteredLogsResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/requests",
                    query: "time_preset=7d&client_source=gemini&page=1&page_size=10",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(filteredLogsResponse.statusCode, 200)
            let filteredLogsBody = try await Self.data(from: filteredLogsResponse.body)
            let filteredPage = try Helpers.readJSON(RequestLogPage.self, from: filteredLogsBody)
            XCTAssertEqual(filteredPage.totalCount, 1)
            XCTAssertEqual(filteredPage.entries.count, 1)
            XCTAssertEqual(filteredPage.entries.first?.clientSource, .gemini)
        }
    }

    func testOAuthResponsesInjectStablePromptCacheKeyAndIsolateByProxyKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = PromptCacheProbe()
        let upstream = Self.makePromptCacheProbeUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-openai",
                    label: "Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    enabled: true,
                    createdAt: 1
                ),
                ProxyAPIKeyRecord(
                    id: "secondary-openai",
                    label: "Secondary",
                    key: "sk-local-secondary",
                    dataSource: .openAI,
                    enabled: true,
                    createdAt: 2
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-openai"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "oauth-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let firstResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false,"metadata":{"user_id":"{\"session_id\":\"session-42\",\"user_id\":\"dev-1\"}"}}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(firstResponse.statusCode, 200)
            _ = try await Self.data(from: firstResponse.body)

            let secondResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello again","stream":false,"metadata":{"user_id":"{\"session_id\":\"session-42\",\"user_id\":\"dev-1\"}"}}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(secondResponse.statusCode, 200)
            _ = try await Self.data(from: secondResponse.body)

            let thirdResponse = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false,"metadata":{"user_id":"{\"session_id\":\"session-42\",\"user_id\":\"dev-1\"}"}}"#,
                    proxyKey: "sk-local-secondary"
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(thirdResponse.statusCode, 200)
            _ = try await Self.data(from: thirdResponse.body)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.count, 3)
            XCTAssertEqual(snapshot[0].sessionID, snapshot[1].sessionID)
            XCTAssertEqual(snapshot[0].promptCacheKey, snapshot[1].promptCacheKey)
            XCTAssertNotEqual(snapshot[0].sessionID, snapshot[2].sessionID)
            XCTAssertNotEqual(snapshot[0].promptCacheKey, snapshot[2].promptCacheKey)
            XCTAssertTrue(snapshot[0].promptCacheKey.hasPrefix("cpx_"))
            XCTAssertFalse(snapshot[0].sessionID.isEmpty)
        }
    }

    func testAdminRequestLogsEndpointsSupportAccountKeyFiltering() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        _ = try await harness.controller.importAuthJSONAccounts([
            .init(
                source: "oauth-auth-1",
                content: Self.chatGPTAuthJSON(
                    principalID: "principal-1",
                    accountID: "account-1",
                    email: "shared-one@example.com"
                ),
                label: "Shared Label"
            ),
            .init(
                source: "oauth-auth-2",
                content: Self.chatGPTAuthJSON(
                    principalID: "principal-2",
                    accountID: "account-2",
                    email: "shared-two@example.com"
                ),
                label: "Shared Label"
            ),
        ])
        let accounts = try await harness.controller.listAccounts()
        let first = try XCTUnwrap(accounts.first(where: { $0.accountKey == "principal-1|account-1" }))
        let second = try XCTUnwrap(accounts.first(where: { $0.accountKey == "principal-2|account-2" }))

        try harness.controller.store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/responses",
                apiKeyHash: Helpers.sha256(harness.config.proxyAPIKey),
                accountKey: first.accountKey,
                accountLabel: first.label,
                model: "claude-sonnet-4-5",
                actualModel: "gpt-5.4",
                success: true,
                latencyMS: 120,
                usage: UpstreamUsage(inputTokens: 12, outputTokens: 8, totalTokens: 20, cacheHitTokens: nil),
                timestamp: Helpers.now() - 20,
                apiKeyValue: harness.config.proxyAPIKey
            )
        )
        try harness.controller.store.recordTrace(
            ProxyRequestTrace(
                endpoint: "/v1/chat/completions",
                apiKeyHash: Helpers.sha256(harness.config.proxyAPIKey),
                accountKey: second.accountKey,
                accountLabel: second.label,
                model: "gpt-5.4-mini",
                actualModel: "gemini-2.5-flash-lite",
                success: true,
                latencyMS: 95,
                usage: UpstreamUsage(inputTokens: 10, outputTokens: 4, totalTokens: 14, cacheHitTokens: nil),
                timestamp: Helpers.now() - 10,
                apiKeyValue: harness.config.proxyAPIKey
            )
        )

        let encodedAccountKey = first.accountKey.replacingOccurrences(of: "|", with: "%7C")
        let logsResponse = await harness.service.handle(
            Self.makeAdminQueryRequest(
                path: "/admin/stats/requests",
                query: "time_preset=7d&account_key=\(encodedAccountKey)&page=1&page_size=10",
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        XCTAssertEqual(logsResponse.statusCode, 200)
        let logsBody = try await Self.data(from: logsResponse.body)
        let page = try Helpers.readJSON(RequestLogPage.self, from: logsBody)
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(page.entries.map(\.accountKey), [first.accountKey])
        XCTAssertEqual(page.entries.map(\.model), ["claude-sonnet-4-5"])
        XCTAssertEqual(page.entries.compactMap(\.actualModel), ["gpt-5.4"])

        let exportResponse = await harness.service.handle(
            Self.makeAdminQueryRequest(
                path: "/admin/stats/requests/export",
                query: "time_preset=7d&account_key=\(encodedAccountKey)&sort_by=time&sort_direction=desc&page=1&page_size=10",
                adminToken: harness.config.adminToken
            ),
            kind: .admin
        )
        XCTAssertEqual(exportResponse.statusCode, 200)
        let exportBody = try await Self.data(from: exportResponse.body)
        let exportText = String(decoding: exportBody.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(exportText.contains("client_source"))
        XCTAssertTrue(exportText.contains("actual_model"))
        XCTAssertTrue(exportText.contains("claude-sonnet-4-5"))
        XCTAssertTrue(exportText.contains("gpt-5.4"))
        XCTAssertFalse(exportText.contains("gpt-5.4-mini"))
    }

    func testSecondaryProxyAPIKeyAuthenticatesAndUsageReportIncludesConfiguredKeys() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(id: "primary", label: "Primary", key: harness.config.proxyAPIKey, enabled: true, createdAt: 1),
                ProxyAPIKeyRecord(id: "secondary", label: "Team B", key: "sk-local-team-b", enabled: true, createdAt: 2),
            ]
            config.primaryProxyAPIKeyID = "primary"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let requestJSON = #"""
            {
              "model": "gpt-5.4",
              "messages": [
                {"role": "user", "content": "Hello"}
              ],
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/chat/completions", body: requestJSON, proxyKey: "sk-local-team-b"),
                kind: .publicAPI
            )
            let responseBody = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: responseBody))

            let usageResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/api-key-usage",
                    query: "time_preset=24h",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(usageResponse.statusCode, 200)
            let usageBody = try await Self.data(from: usageResponse.body)
            let report = try Helpers.readJSON(ProxyAPIKeyUsageReport.self, from: usageBody)

            let secondary = try XCTUnwrap(report.entries.first(where: { $0.apiKey == "sk-local-team-b" }))
            XCTAssertEqual(secondary.label, "Team B")
            XCTAssertEqual(secondary.dataSource, .openAI)
            XCTAssertEqual(secondary.requestCount, 1)
            XCTAssertTrue(secondary.totalTokens > 0)

            let primary = try XCTUnwrap(report.entries.first(where: { $0.apiKey == harness.config.proxyAPIKey }))
            XCTAssertEqual(primary.label, "Primary")
            XCTAssertEqual(primary.dataSource, .openAI)
            XCTAssertEqual(primary.requestCount, 0)
            XCTAssertTrue(primary.isPrimary)
        }
    }

    func testDefaultAllProxyAPIKeyUsageReportRetainsAllDataSource() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "OAuth")
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let responseBody = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: responseBody))

            let usageResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/api-key-usage",
                    query: "time_preset=24h",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(usageResponse.statusCode, 200)
            let usageBody = try await Self.data(from: usageResponse.body)
            let report = try Helpers.readJSON(ProxyAPIKeyUsageReport.self, from: usageBody)
            let primary = try XCTUnwrap(report.entries.first(where: { $0.apiKey == harness.config.proxyAPIKey }))

            XCTAssertEqual(primary.dataSource, .all)
            XCTAssertEqual(primary.requestCount, 1)
            XCTAssertTrue(primary.isPrimary)
        }
    }

    func testAnthropicDataSourceMessagesUseAnthropicProvider() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let requestJSON = #"""
            {
              "model": "claude-sonnet-4-5",
              "messages": [
                {
                  "role": "user",
                  "content": [
                    {"type": "text", "text": "Say hello"}
                  ]
                }
              ],
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(path: "/v1/messages", body: requestJSON, proxyKey: harness.config.proxyAPIKey),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["role"] as? String, "assistant")
            let content = try XCTUnwrap(payload["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["text"] as? String, "Anthropic model=claude-sonnet-4-5")
        }
    }

    func testAllDataSourceChatCompletionsUseAnthropicProvider() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let requestJSON = #"""
            {
              "model": "gpt-5.4",
              "messages": [
                {"role": "user", "content": "Say hello"}
              ],
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: requestJSON,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains(#""object":"chat.completion""#))
            XCTAssertTrue(Self.string(from: body).contains("Anthropic model=claude-sonnet-4-5"))
        }
    }

    func testAnthropicDataSourceMessagesNormalizeCachedTokensIntoCacheReadUsage() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicCachedUsageProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let usage = try XCTUnwrap(payload["usage"] as? [String: Any])
            XCTAssertEqual((usage["cache_read_input_tokens"] as? NSNumber)?.int64Value, 5)

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertEqual(entry.inputTokens, 16)
            XCTAssertEqual(entry.outputTokens, 7)
            XCTAssertEqual(entry.totalTokens, 23)
            XCTAssertEqual(entry.cacheHitTokens, 5)
        }
    }

    func testAnthropicDataSourceMessagesLogCacheReadTokensAsInputTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicCachedUsageProviderApplication(
            inputTokens: 0,
            cachedTokens: nil,
            cacheReadTokens: 17
        )
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first)
            XCTAssertEqual(entry.inputTokens, 17)
            XCTAssertEqual(entry.outputTokens, 7)
            XCTAssertEqual(entry.totalTokens, 24)
            XCTAssertEqual(entry.cacheHitTokens, 17)
        }
    }

    func testAnthropicDataSourceStreamingMessagesLogExplicitZeroCacheReadTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicStreamingUsageProviderApplication(cacheReadTokens: 0)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("event: message_stop"))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first(where: { $0.endpoint == "/v1/messages" }))
            XCTAssertEqual(entry.inputTokens, 11)
            XCTAssertEqual(entry.outputTokens, 7)
            XCTAssertEqual(entry.totalTokens, 18)
            XCTAssertEqual(entry.cacheHitTokens, 0)
        }
    }

    func testAnthropicDataSourceStreamingMessagesLogCachedTokensAsInputTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicStreamingUsageProviderApplication(
            cacheReadTokens: 17,
            inputTokens: 0,
            outputTokens: 7,
            cacheCreationTokens: 3
        )
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("event: message_stop"))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first(where: { $0.endpoint == "/v1/messages" }))
            XCTAssertEqual(entry.inputTokens, 20)
            XCTAssertEqual(entry.outputTokens, 7)
            XCTAssertEqual(entry.totalTokens, 27)
            XCTAssertEqual(entry.cacheHitTokens, 17)
        }
    }

    func testAnthropicDataSourceStreamingMessagesKeepMissingCacheReadTokensNil() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicStreamingUsageProviderApplication(cacheReadTokens: nil)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hello"}],"stream":true}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains("event: message_stop"))

            let logs = try await harness.controller.requestLogs(
                query: RequestLogQuery(timePreset: .last24Hours, page: 1, pageSize: 10)
            )
            let entry = try XCTUnwrap(logs.entries.first(where: { $0.endpoint == "/v1/messages" }))
            XCTAssertNil(entry.cacheHitTokens)
        }
    }

    func testAnthropicDataSourceResponsesUseOpenAIToAnthropicBridge() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains(#""object":"response""#))
            XCTAssertTrue(Self.string(from: body).contains("Anthropic model=claude-sonnet-4-5"))
        }
    }

    func testAnthropicDataSourceChatCompletionsUseOpenAIToAnthropicBridge() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeAnthropicProviderApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-anthropic",
                    label: "Anthropic Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .anthropic,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-anthropic"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                AnthropicOAuthSecretBundle(
                    accessToken: "anthropic-access",
                    refreshToken: "anthropic-refresh",
                    expiresAt: Helpers.now() + 3_600
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "anthropic-auth.json",
                    content: Self.anthropicOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)"
                    ),
                    label: "Anthropic OAuth"
                )
            ])

            let requestJSON = #"""
            {
              "model": "gpt-5.4",
              "messages": [
                {"role": "user", "content": "Say hello"}
              ],
              "stream": false
            }
            """#

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: requestJSON,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
            XCTAssertTrue(Self.string(from: body).contains(#""object":"chat.completion""#))
            XCTAssertTrue(Self.string(from: body).contains("Anthropic model=claude-sonnet-4-5"))
        }
    }

    func testAnthropicDataSourceDoesNotFallbackToOpenAIAccounts() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        var config = harness.config
        config.proxyAPIKeys = [
            ProxyAPIKeyRecord(
                id: "primary-anthropic",
                label: "Anthropic Primary",
                key: harness.config.proxyAPIKey,
                dataSource: .anthropic,
                enabled: true,
                createdAt: 1
            ),
        ]
        config.primaryProxyAPIKeyID = "primary-anthropic"
        _ = try await harness.controller.saveConfig(config)
        _ = try await harness.controller.importAuthJSONAccounts([
            .init(source: "oauth-auth.json", content: Self.chatGPTAuthJSON(), label: "OpenAI OAuth")
        ])

        let response = await harness.service.handle(
            Self.makePublicRequest(
                path: "/v1/responses",
                body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                proxyKey: harness.config.proxyAPIKey
            ),
            kind: .publicAPI
        )
        let body = try await Self.data(from: response.body)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertTrue(Self.string(from: body).contains("当前 API Key 绑定的是 Anthropic 数据源，但没有可用的 Anthropic 账号。"))
    }

    func testManualAddAnthropicAPIKeyAccountAutoAddsAnthropicAccessProxyKey() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "primary-openai",
                    label: "OpenAI Primary",
                    key: harness.config.proxyAPIKey,
                    dataSource: .openAI,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "primary-openai"
            _ = try await harness.controller.saveConfig(config)

            _ = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Anthropic API Key",
                    providerPreset: .anthropicAPICompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-anthropic-runtime",
                    enabled: true
                )
            )

            let updated = try await harness.controller.loadConfig()
            XCTAssertEqual(updated.primaryProxyAPIKeyID, "primary-openai")
            let anthropicAccess = try XCTUnwrap(updated.proxyAPIKeys.first(where: { $0.dataSource == .anthropic }))
            XCTAssertEqual(anthropicAccess.label, AppConfig.defaultAnthropicAccessProxyAPIKeyLabel)
            XCTAssertTrue(anthropicAccess.enabled)
        }
    }

    func testManualAddGenericOpenAICompatibleAPIKeyFallsBackToResponsesValidationWhenModelsMissing() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GenericOpenAICompatibilityProbe()
        let upstream = Self.makeGenericOpenAICompatibilityApplication(
            probe: probe,
            modelsStatus: .notFound
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)/v1"

            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Generic Validation Fallback",
                    providerPreset: .genericOpenAICompatible,
                    baseURL: baseURL,
                    apiKey: "sk-generic-validation",
                    enabled: true
                )
            )
            XCTAssertNil(added.usageError)

            let refreshed = try await harness.controller.refreshAccountUsage(id: added.id)
            XCTAssertNil(refreshed.usageError)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, 2)
            XCTAssertEqual(snapshot.chatHits, 0)
            XCTAssertEqual(snapshot.responsesHits, 2)
            XCTAssertTrue(snapshot.responsesRequestBodies[0].contains(#""input":"你好""#))
            XCTAssertTrue(snapshot.responsesRequestBodies[0].contains(#""stream":false"#))
            XCTAssertTrue(snapshot.responsesRequestBodies[0].contains(#""max_output_tokens":1"#))
        }
    }

    func testManualAddAnthropicAPIKeyAccountFallsBackToMessagesValidationWhenModelsMissing() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(
            probe: probe,
            modelsStatus: .notFound,
            expectedMessagesModel: "claude-sonnet-4-5",
            expectedProbeText: "你好"
        )
        try await upstream.test(.ahc()) { upstreamClient in
            let baseURL = "http://localhost:\(upstreamClient.port ?? 0)"

            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Anthropic Validation Fallback",
                    providerPreset: .anthropicAPICompatible,
                    baseURL: "\(baseURL)/v1",
                    apiKey: "sk-anthropic-validation",
                    enabled: true
                )
            )
            XCTAssertNil(added.usageError)

            let refreshed = try await harness.controller.refreshAccountUsage(id: added.id)
            XCTAssertNil(refreshed.usageError)

            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.modelsHits, 2)
            XCTAssertGreaterThanOrEqual(snapshot.messagesHits, 2)
            XCTAssertEqual(snapshot.countTokensHits, 0)
            XCTAssertTrue(snapshot.requestBodies.first?.contains("你好") == true)
        }
    }

    func testAllDataSourceResponsesFallbackFromOpenAIToAnthropicAccount() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let failingOpenAI = Self.makeFailingUpstreamApplication()
        let anthropicUpstream = Self.makeAnthropicProviderApplication()
        try await failingOpenAI.test(.ahc()) { openAIClient in
            try await anthropicUpstream.test(.ahc()) { anthropicClient in
                var config = harness.config
                config.chatGPTBaseURL = "http://localhost:\(openAIClient.port ?? 0)"
                _ = try await harness.controller.saveConfig(config)

                _ = try await harness.controller.importAuthJSONAccounts([
                    .init(source: "openai-auth.json", content: Self.chatGPTAuthJSON(), label: "OpenAI OAuth")
                ])

                let secretRef = try harness.controller.secretStore.saveAnthropicOAuthSecret(
                    AnthropicOAuthSecretBundle(
                        accessToken: "anthropic-access",
                        refreshToken: "anthropic-refresh",
                        expiresAt: Helpers.now() + 3_600
                    )
                )
                _ = try await harness.controller.importAuthJSONAccounts([
                    .init(
                        source: "anthropic-auth.json",
                        content: Self.anthropicOAuthAuthJSON(
                            secretRef: secretRef,
                            baseURL: "http://localhost:\(anthropicClient.port ?? 0)"
                        ),
                        label: "Anthropic OAuth"
                    )
                ])

                let response = await harness.service.handle(
                    Self.makePublicRequest(
                        path: "/v1/responses",
                        body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                        proxyKey: harness.config.proxyAPIKey
                    ),
                    kind: .publicAPI
                )
                let body = try await Self.data(from: response.body)
                XCTAssertEqual(response.statusCode, 200, Self.string(from: body))
                XCTAssertTrue(Self.string(from: body).contains("Anthropic model=claude-sonnet-4-5"))

                let status = try await harness.controller.status()
                XCTAssertEqual(status.activeAccountLabel, "Anthropic OAuth")
            }
        }
    }

    func testFailedProxyRequestIsRecordedInRequestLogs() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let upstream = Self.makeFailingUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            var config = harness.config
            config.chatGPTBaseURL = "http://localhost:\(upstreamClient.port ?? 0)"
            _ = try await harness.controller.saveConfig(config)
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(source: "test-auth", content: Self.chatGPTAuthJSON(), label: "Mock ChatGPT")
            ])

            let response = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            XCTAssertEqual(response.statusCode, 500)
            _ = try await Self.data(from: response.body)

            let logsResponse = await harness.service.handle(
                Self.makeAdminQueryRequest(
                    path: "/admin/stats/requests",
                    query: "time_preset=7d&page=1&page_size=10",
                    adminToken: harness.config.adminToken
                ),
                kind: .admin
            )
            XCTAssertEqual(logsResponse.statusCode, 200)
            let logsBody = try await Self.data(from: logsResponse.body)
            let page = try Helpers.readJSON(RequestLogPage.self, from: logsBody)
            XCTAssertEqual(page.totalCount, 1)
            XCTAssertEqual(page.entries.first?.success, false)
            XCTAssertEqual(page.entries.first?.failureCategory, "rateLimit")
            XCTAssertTrue(page.entries.first?.errorSummary?.contains("too many requests") == true)
        }
    }

    private static func makeHarness() async throws -> Harness {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let controller = try Self.makeController(dataDirectory: dataDirectory)
        try await controller.bootstrap()
        let config = try await controller.loadConfig()
        let service = DaemonHTTPService(
            controller: controller,
            publicHost: "127.0.0.1",
            publicPort: 8787,
            adminPort: 8788
        )
        return Harness(dataDirectory: dataDirectory, controller: controller, service: service, config: config)
    }

    private static func makeController(
        dataDirectory: URL,
        manageManagedProxyRuntime: Bool = true,
        secretStore: SecretStore? = nil,
        managedProxyRuntime: (any ManagedProxyRuntimeControlling)? = nil
    ) throws -> DaemonController {
        try DaemonController(
            dataDirectory: dataDirectory,
            manageManagedProxyRuntime: manageManagedProxyRuntime,
            publicBaseURLProvider: { "http://127.0.0.1:8787/v1" },
            adminBaseURLProvider: { "http://127.0.0.1:8788/admin" },
            secretStore: secretStore,
            managedProxyRuntimeOverride: managedProxyRuntime
        )
    }

    private static func makeUpstreamApplication(
        usagePlanType: String = "free"
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload(planType: usagePlanType)
        router.get("v1/models") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5.5"},{"id":"gpt-5.4-mini"}]}"#))
            )
        }
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.post("backend-api/codex/responses") { _, _ in
            var headers = HTTPFields()
            headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamSSEPayload()))
            )
        }
        router.post("v1/responses") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload(text: "Manual API route")))
            )
        }
        return Application(router: router)
    }

    private static func makeReasoningStreamUpstreamApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()
        router.get("v1/models") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5.4"},{"id":"gpt-5"}]}"#))
            )
        }
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        let reasoningResponse = Response(
            status: .ok,
            headers: {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return headers
            }(),
            body: .init { writer in
                var writer = writer
                try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_reasoning\",\"created_at\":1710000000}}\n\n"))
                try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"delta\":\"Inspecting files\"}\n\n"))
                try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Ready\"}\n\n"))
                try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_reasoning\",\"object\":\"response\",\"created_at\":1710000000,\"status\":\"completed\",\"model\":\"gpt-5\",\"output\":[{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Inspecting files\"}]},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Ready\"}]}],\"usage\":{\"input_tokens\":3,\"output_tokens\":4,\"total_tokens\":7}}}\n\n"))
                try await writer.finish(nil)
            }
        )
        router.post("backend-api/codex/responses") { _, _ in
            reasoningResponse
        }
        router.post("v1/responses") { _, _ in
            reasoningResponse
        }
        return Application(router: router)
    }

    private static func makeInterruptedResponsesStreamUpstreamApplication(
        termination: MockStreamTermination,
        includeCreatedEvent: Bool
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()
        router.get("v1/models") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5"},{"id":"gpt-5.4"}]}"#))
            )
        }
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        let interruptedResponse = Response(
            status: .ok,
            headers: {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return headers
            }(),
            body: .init { writer in
                var writer = writer
                if includeCreatedEvent {
                    try await writer.write(
                        ByteBuffer(
                            string: "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_interrupted\",\"created_at\":1710000000}}\n\n"
                        )
                    )
                }
                try await writer.write(
                    ByteBuffer(
                        string: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello before failure\"}\n\n"
                    )
                )
                switch termination {
                case .throwError(let message):
                    throw MockStreamError(message: message)
                case .prematureEOF:
                    try await writer.finish(nil)
                }
            }
        )
        router.post("v1/responses") { _, _ in
            interruptedResponse
        }
        return Application(router: router)
    }

    private static func makeHangingResponsesStreamUpstreamApplication(
        chunks: [String],
        finalDelayMS: Int64 = 1_000
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()
        router.get("v1/models") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5"},{"id":"gpt-5.5"}]}"#))
            )
        }
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        let hangingResponse = Response(
            status: .ok,
            headers: {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return headers
            }(),
            body: .init { writer in
                var writer = writer
                for chunk in chunks {
                    try await writer.write(ByteBuffer(string: chunk))
                }
                try await Task.sleep(for: .milliseconds(finalDelayMS))
                try await writer.finish(nil)
            }
        )
        router.post("v1/responses") { _, _ in
            hangingResponse
        }
        return Application(router: router)
    }

    private static func makeInterruptedGeminiStreamUpstreamApplication(
        termination: MockStreamTermination
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()
        router.get("v1/models") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5"},{"id":"gpt-5.4"}]}"#))
            )
        }
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        let interruptedResponse = Response(
            status: .ok,
            headers: {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return headers
            }(),
            body: .init { writer in
                var writer = writer
                try await writer.write(
                    ByteBuffer(
                        string: "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"delta\":\"Inspecting files\"}\n\n"
                    )
                )
                try await writer.write(
                    ByteBuffer(
                        string: "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"run_command\",\"arguments\":\"\"}}\n\n"
                    )
                )
                try await writer.write(
                    ByteBuffer(
                        string: "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_1\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}\n\n"
                    )
                )
                try await writer.write(
                    ByteBuffer(
                        string: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Ready\"}\n\n"
                    )
                )
                switch termination {
                case .throwError(let message):
                    throw MockStreamError(message: message)
                case .prematureEOF:
                    try await writer.finish(nil)
                }
            }
        )
        router.post("v1/responses") { _, _ in
            interruptedResponse
        }
        return Application(router: router)
    }

    private static func makePromptCacheProbeUpstreamApplication(
        probe: PromptCacheProbe
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()
        let sessionHeaderName = HTTPField.Name("session_id")!

        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.post("backend-api/codex/responses") { request, _ async throws -> Response in
            let bodyText = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any] ?? [:]
            await probe.record(
                sessionID: request.headers[sessionHeaderName] ?? "",
                promptCacheKey: payload["prompt_cache_key"] as? String ?? ""
            )
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload()))
            )
        }
        return Application(router: router)
    }

    private static func makeAnthropicProviderApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.post("v1/messages") { request, _ async throws -> Response in
            let authorization = request.headers[.authorization] ?? ""
            if authorization == "Bearer anthropic-access-missing-scope" {
                return Response(
                    status: .forbidden,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement any_of(user:inference, user:ccr_inference, user:voice, org:service_key_inference, workspace:inference)"}}"#
                        )
                    )
                )
            }
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? "claude-sonnet-4-5"

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: """
                        {
                          "id": "msg_test",
                          "type": "message",
                          "role": "assistant",
                          "model": "\(model)",
                          "content": [
                            {
                              "type": "text",
                              "text": "Anthropic model=\(model)"
                            }
                          ],
                          "stop_reason": "end_turn",
                          "usage": {
                            "input_tokens": 11,
                            "output_tokens": 7
                          }
                        }
                        """
                    )
                )
            )
        }

        router.post("v1/oauth/token") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let contentType = request.headers[.contentType] ?? ""
            let anthropicBetaHeaderName = HTTPField.Name("anthropic-beta")!
            let anthropicBetaHeader = request.headers[anthropicBetaHeaderName]
            guard anthropicBetaHeader == nil, contentType == "application/json" else {
                return Self.invalidAnthropicOAuthRequestFormatResponse()
            }
            guard let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let grantType = payload["grant_type"] as? String
            else {
                return Self.invalidAnthropicOAuthRequestFormatResponse()
            }

            if grantType == "authorization_code" {
                guard let code = payload["code"] as? String,
                      let redirectURI = payload["redirect_uri"] as? String,
                      let clientID = payload["client_id"] as? String,
                      let codeVerifier = payload["code_verifier"] as? String,
                      let state = payload["state"] as? String,
                      !code.isEmpty,
                      redirectURI.hasPrefix("http://localhost:"),
                      redirectURI.hasSuffix("/callback"),
                      clientID == AnthropicAuthService.defaultClientID,
                      !redirectURI.isEmpty,
                      !codeVerifier.isEmpty,
                      !state.isEmpty
                else {
                    return Self.invalidAnthropicOAuthRequestFormatResponse()
                }

                guard code != "bad-code" else {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: #"{"error":"invalid_grant","error_description":"Bad authorization code"}"#
                            )
                        )
                    )
                }

                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: """
                            {
                              "access_token": "anthropic-access-\(code)",
                              "refresh_token": "anthropic-refresh-\(code)",
                              "token_type": "Bearer",
                              "scope": "user:profile user:inference",
                              "sub": "anthropic-principal",
                              "account_id": "anthropic-account",
                              "email": "claude@example.com",
                              "name": "Claude OAuth"
                            }
                            """
                        )
                    )
                )
            }

            if grantType == "refresh_token" {
                guard let refreshToken = payload["refresh_token"] as? String,
                      let clientID = payload["client_id"] as? String,
                      let scope = payload["scope"] as? String,
                      !refreshToken.isEmpty,
                      clientID == AnthropicAuthService.defaultClientID,
                      !scope.isEmpty
                else {
                    return Self.invalidAnthropicOAuthRequestFormatResponse()
                }

                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: """
                            {
                              "access_token": "anthropic-access-refresh-\(refreshToken)",
                              "refresh_token": "anthropic-refresh-rotated-\(refreshToken)",
                              "token_type": "Bearer",
                              "scope": "\(scope)"
                            }
                            """
                        )
                    )
                )
            }

            return Self.invalidAnthropicOAuthRequestFormatResponse()
        }

        router.post("v1/messages/count_tokens") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"input_tokens":11}"#))
            )
        }

        return Application(router: router)
    }

    private static func makeGeminiOAuthProviderApplication(
        probe: GeminiOAuthProbe,
        loadCodeAssistResponses: [String]? = nil,
        onboardResponse: String? = nil,
        operationResponses: [String] = [],
        generateContentStatus: Int = 200,
        generateContentBody: String? = nil,
        streamGenerateContentStatus: Int = 200,
        streamGenerateContentBody: String? = nil,
        streamGenerateContentChunks: [String]? = nil,
        countTokensStatus: Int = 200,
        countTokensBody: String? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let sequence = GeminiOAuthResponseSequence(
            loadResponses: loadCodeAssistResponses ?? [Self.mockGeminiLoadCodeAssistPayload()],
            operationResponses: operationResponses
        )

        router.post("token") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe.recordTokenRequest(body)
            let contentType = request.headers[.contentType] ?? ""
            guard contentType == "application/x-www-form-urlencoded" else {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_content_type"}"#))
                )
            }

            let grantType = Self.formValue("grant_type", from: body) ?? ""
            switch grantType {
            case "authorization_code":
                let code = Self.formValue("code", from: body) ?? ""
                let redirectURI = Self.formValue("redirect_uri", from: body) ?? ""
                let clientID = Self.formValue("client_id", from: body) ?? ""
                let clientSecret = Self.formValue("client_secret", from: body) ?? ""
                let codeVerifier = Self.formValue("code_verifier", from: body) ?? ""
                guard !code.isEmpty,
                      redirectURI.hasPrefix("http://localhost:"),
                      redirectURI.hasSuffix(AuthService.geminiOAuthCallbackPath),
                      clientID == GeminiAuthService.defaultOAuthClientID,
                      clientSecret == GeminiAuthService.defaultOAuthClientSecret,
                      !codeVerifier.isEmpty
                else {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_request"}"#))
                    )
                }
                guard code != "bad-code" else {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: #"{"error":"invalid_grant","error_description":"Bad authorization code"}"#
                            )
                        )
                    )
                }
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: """
                            {
                              "access_token": "gemini-access-\(code)",
                              "refresh_token": "gemini-refresh-\(code)",
                              "expires_in": 3600,
                              "token_type": "Bearer",
                              "scope": "\(GeminiAuthService.defaultOAuthScopes)",
                              "id_token": "\(Self.jwt([
                                "sub": "gemini-principal",
                                "email": "gemini@example.com",
                                "name": "Gemini Example"
                              ]))"
                            }
                            """
                        )
                    )
                )
            case "refresh_token":
                let refreshToken = Self.formValue("refresh_token", from: body) ?? ""
                let clientID = Self.formValue("client_id", from: body) ?? ""
                let clientSecret = Self.formValue("client_secret", from: body) ?? ""
                guard !refreshToken.isEmpty,
                      clientID == GeminiAuthService.defaultOAuthClientID,
                      clientSecret == GeminiAuthService.defaultOAuthClientSecret
                else {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_request"}"#))
                    )
                }
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: """
                            {
                              "access_token": "gemini-access-refresh-\(refreshToken)",
                              "refresh_token": "gemini-refresh-rotated-\(refreshToken)",
                              "expires_in": 3600,
                              "token_type": "Bearer",
                              "scope": "\(GeminiAuthService.defaultOAuthScopes)"
                            }
                            """
                        )
                    )
                )
            default:
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"unsupported_grant_type"}"#))
                )
            }
        }

        router.post("v1internal:loadCodeAssist") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe.recordLoadCodeAssistHit(
                body: body,
                authorization: request.headers[.authorization]
            )
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: await sequence.nextLoadResponse()
                    )
                )
            )
        }

        router.post("v1internal:onboardUser") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe.recordOnboardUserHit(
                body: body,
                authorization: request.headers[.authorization]
            )
            guard let onboardResponse else {
                return Response(
                    status: .notFound,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"missing_onboard_stub"}"#))
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: onboardResponse))
            )
        }

        router.get("v1internal/operations/**") { request, _ async throws -> Response in
            await probe.recordOperationPollHit(authorization: request.headers[.authorization])
            guard operationResponses.isEmpty == false else {
                return Response(
                    status: .notFound,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"missing_operation_stub"}"#))
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: await sequence.nextOperationResponse()))
            )
        }

        router.post("v1internal:generateContent") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe.recordGenerateHit(
                body: body,
                authorization: request.headers[.authorization]
            )
            let responseBody = generateContentBody ?? """
            {
              "response": {
                "candidates": [
                  {
                    "content": {
                      "role": "model",
                      "parts": [
                        {"text": "Google AI Pro Route"}
                      ]
                    },
                    "finishReason": "STOP"
                  }
                ],
                "modelVersion": "gemini-2.5-flash",
                "usageMetadata": {
                  "promptTokenCount": 3,
                  "candidatesTokenCount": 5,
                  "totalTokenCount": 8
                }
              }
            }
            """
            return Response(
                status: .init(code: generateContentStatus),
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: responseBody
                    )
                )
            )
        }

        router.post("v1internal:streamGenerateContent") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe.recordStreamGenerateHit(
                body: body,
                authorization: request.headers[.authorization]
            )

            if (200 ..< 300).contains(streamGenerateContentStatus) == false {
                return Response(
                    status: .init(code: streamGenerateContentStatus),
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: streamGenerateContentBody ?? Self.mockGeminiValidationRequiredError()
                        )
                    )
                )
            }

            let chunks = streamGenerateContentChunks ?? [
                "data: {\"response\":{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Google AI Pro Route\"}]},\"finishReason\":\"STOP\"}],\"modelVersion\":\"gemini-2.5-flash\",\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":5,\"totalTokenCount\":8}}}\n\n",
            ]
            var headers = HTTPFields()
            headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
            return Response(
                status: .ok,
                headers: headers,
                body: .init { writer in
                    var writer = writer
                    for chunk in chunks {
                        try await writer.write(ByteBuffer(string: chunk))
                    }
                    try await writer.finish(nil)
                }
            )
        }

        router.post("v1internal:countTokens") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            await probe.recordCountTokensHit(
                body: body,
                authorization: request.headers[.authorization]
            )
            let responseBody = countTokensBody ?? #"{"totalTokens":11,"cachedContentTokenCount":2}"#
            return Response(
                status: .init(code: countTokensStatus),
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: responseBody
                    )
                )
            )
        }

        router.get("userinfo") { request, _ async throws -> Response in
            let authorization = request.headers[.authorization] ?? ""
            guard authorization.hasPrefix("Bearer gemini-access-") else {
                return Response(
                    status: .unauthorized,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":"unauthorized"}"#))
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: #"{"id":"gemini-principal","email":"gemini@example.com","name":"Gemini Example"}"#
                    )
                )
            )
        }

        return Application(router: router)
    }

    private static func makeAnthropicAPIKeyUpstreamApplication(
        probe: AnthropicAPIKeyProbe,
        modelsStatus: HTTPResponse.Status = .ok,
        modelsBody: String? = nil,
        messagesStatus: HTTPResponse.Status = .ok,
        messagesBody: String? = nil,
        expectedMessagesModel: String? = nil,
        expectedProbeText: String? = nil,
        countTokensStatus: HTTPResponse.Status = .ok,
        countTokensBody: String? = nil,
        expectedCountTokensModel: String? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let apiKeyHeaderName = HTTPField.Name("x-api-key")!
        let versionHeaderName = HTTPField.Name("anthropic-version")!
        let betaHeaderName = HTTPField.Name("anthropic-beta")!

        router.get("v1/models") { request, _ async throws -> Response in
            await probe.recordModelsHit(
                apiKey: request.headers[apiKeyHeaderName],
                authorization: request.headers[.authorization],
                anthropicVersion: request.headers[versionHeaderName],
                anthropicBeta: request.headers[betaHeaderName]
            )
            let body: String
            if modelsStatus == .ok {
                body = modelsBody ?? #"{"data":[{"id":"claude-sonnet-4-5","type":"model","display_name":"Claude Sonnet 4.5"}]}"#
            } else {
                body = modelsBody ?? ""
            }
            return Response(
                status: modelsStatus,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: body
                    )
                )
            )
        }

        router.post("v1/messages") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? "claude-sonnet-4-5"
            await probe.recordMessagesHit(
                body: body,
                apiKey: request.headers[apiKeyHeaderName],
                authorization: request.headers[.authorization],
                anthropicVersion: request.headers[versionHeaderName],
                anthropicBeta: request.headers[betaHeaderName]
            )
            if let expectedMessagesModel, model != expectedMessagesModel {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"expected model \#(expectedMessagesModel), got \#(model)"}}"#
                        )
                    )
                )
            }
            if let expectedProbeText, body.contains(expectedProbeText) == false {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"expected probe text \#(expectedProbeText)"}}"#
                        )
                    )
                )
            }
            return Response(
                status: messagesStatus,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: messagesBody ?? """
                        {
                          "id": "msg_manual_api_key",
                          "type": "message",
                          "role": "assistant",
                          "model": "\(model)",
                          "content": [
                            {
                              "type": "text",
                              "text": "Anthropic native model=\(model)"
                            }
                          ],
                          "stop_reason": "end_turn",
                          "usage": {
                            "input_tokens": 11,
                            "output_tokens": 7
                          }
                        }
                        """
                    )
                )
            )
        }

        router.post("v1/messages/count_tokens") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? ""
            await probe.recordCountTokensHit(
                body: body,
                apiKey: request.headers[apiKeyHeaderName],
                authorization: request.headers[.authorization],
                anthropicVersion: request.headers[versionHeaderName],
                anthropicBeta: request.headers[betaHeaderName]
            )
            if let expectedCountTokensModel, model != expectedCountTokensModel {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"expected model \#(expectedCountTokensModel), got \#(model)"}}"#
                        )
                    )
                )
            }
            return Response(
                status: countTokensStatus,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: countTokensBody ?? #"{"input_tokens":11}"#))
            )
        }

        return Application(router: router)
    }

    private static func makeAnthropicCachedUsageProviderApplication(
        inputTokens: Int64 = 11,
        outputTokens: Int64 = 7,
        cachedTokens: Int64? = 5,
        cacheReadTokens: Int64? = nil,
        cacheCreationTokens: Int64? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.post("v1/messages") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? "claude-sonnet-4-5"
            let cachedUsageFragment = cachedTokens.map { #","cached_tokens":\#($0)"# } ?? ""
            let cacheReadUsageFragment = cacheReadTokens.map { #","cache_read_input_tokens":\#($0)"# } ?? ""
            let cacheCreationUsageFragment = cacheCreationTokens.map { #","cache_creation_input_tokens":\#($0)"# } ?? ""

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: """
                        {
                          "id": "msg_cached",
                          "type": "message",
                          "role": "assistant",
                          "model": "\(model)",
                          "content": [
                            {
                              "type": "text",
                              "text": "Anthropic model=\(model)"
                            }
                          ],
                          "stop_reason": "end_turn",
                          "usage": {
                            "input_tokens": \(inputTokens),
                            "output_tokens": \(outputTokens)\(cachedUsageFragment)\(cacheReadUsageFragment)\(cacheCreationUsageFragment)
                          }
                        }
                        """
                    )
                )
            )
        }

        return Application(router: router)
    }

    private static func makeAnthropicStreamingUsageProviderApplication(
        cacheReadTokens: Int64?,
        inputTokens: Int64 = 11,
        outputTokens: Int64 = 7,
        cacheCreationTokens: Int64? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.post("v1/messages") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? "claude-sonnet-4-5"
            let cacheReadUsageFragment = cacheReadTokens.map { #","cache_read_input_tokens":\#($0)"# } ?? ""
            let cacheCreationUsageFragment = cacheCreationTokens.map { #","cache_creation_input_tokens":\#($0)"# } ?? ""

            var headers = HTTPFields()
            headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
            return Response(
                status: .ok,
                headers: headers,
                body: .init { writer in
                    var writer = writer
                    try await writer.write(
                        ByteBuffer(
                            string: "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"\(model)\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":\(inputTokens),\"output_tokens\":0\(cacheReadUsageFragment)\(cacheCreationUsageFragment)}}}\n\n"
                        )
                    )
                    try await writer.write(
                        ByteBuffer(
                            string: "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
                        )
                    )
                    try await writer.write(
                        ByteBuffer(
                            string: "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Anthropic model=\(model)\"}}\n\n"
                        )
                    )
                    try await writer.write(
                        ByteBuffer(
                            string: "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                        )
                    )
                    try await writer.write(
                        ByteBuffer(
                            string: "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":\(outputTokens)\(cacheReadUsageFragment)}}\n\n"
                        )
                    )
                    try await writer.write(
                        ByteBuffer(
                            string: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
                        )
                    )
                    try await writer.finish(nil)
                }
            )
        }

        return Application(router: router)
    }

    private static func makeDelayedToolStreamUpstreamApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()

        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.post("backend-api/codex/responses") { _, _ in
            var headers = HTTPFields()
            headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
            return Response(
                status: .ok,
                headers: headers,
                body: .init { writer in
                    var writer = writer
                    try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tool\",\"created_at\":1710000000}}\n\n"))
                    try await Task.sleep(for: .milliseconds(2_250))
                    try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc_123\",\"type\":\"function_call\",\"call_id\":\"call_123\",\"name\":\"run_command\",\"arguments\":\"\"}}\n\n"))
                    try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_123\",\"delta\":\"{\\\"command\\\":\\\"ls\\\"}\"}\n\n"))
                    try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_123\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}\n\n"))
                    try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tool\",\"object\":\"response\",\"created_at\":1710000000,\"status\":\"completed\",\"model\":\"gpt-5.4\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_123\",\"name\":\"run_command\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}],\"usage\":{\"input_tokens\":3,\"output_tokens\":4,\"total_tokens\":7}}}\n\n"))
                    try await writer.finish(nil)
                }
            )
        }
        return Application(router: router)
    }

    private static func makeAssistantHistoryStrictUpstreamApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()

        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.post("backend-api/codex/responses") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
            if Self.containsAssistantInputText(in: payload["input"]) {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"type":"invalid_request_error","message":"Invalid value: 'input_text'. Supported values are: 'output_text' and 'refusal'.","param":"input[1].content[0]"}"#
                        )
                    )
                )
            }

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload()))
            )
        }

        return Application(router: router)
    }

    private static func makeStrictCompatibilityUpstreamApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()

        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }

        router.post("backend-api/codex/responses") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            if body.contains("\"max_output_tokens\"")
                || body.contains("\"temperature\"")
                || body.contains("\"top_p\"")
                || body.contains("\"n\"")
                || body.contains("\"metadata\"")
            {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"detail":"Unsupported parameter: max_output_tokens"}"#))
                )
            }
            if body.contains(#""model":"gpt-5-mini""#) {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"detail":"The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account."}"#))
                )
            }

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload()))
            )
        }

        router.post("api.openai.com/v1/responses") { request, _ async throws -> Response in
            let body = try await Self.string(from: request.body)
            let containsExpectedParameters =
                body.contains(#""max_output_tokens":123"#)
                && body.contains(#""temperature":0.5"#)
                && body.contains(#""top_p":0.9"#)

            guard containsExpectedParameters else {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":{"message":"Expected OpenAI parameters were stripped."}}"#))
                )
            }

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload()))
            )
        }

        return Application(router: router)
    }

    private static func mockUpstreamSSEPayload() -> String {
        [
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_test\",\"created_at\":1710000000}}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello world\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\",\"object\":\"response\",\"created_at\":1710000000,\"status\":\"completed\",\"model\":\"gpt-5.4\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello world\"}]}],\"usage\":{\"input_tokens\":3,\"output_tokens\":4,\"total_tokens\":7,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n\n",
        ].joined()
    }

    private static func mockUpstreamCompletedResponsePayload() -> String {
        #"{"id":"resp_test","object":"response","created_at":1710000000,"status":"completed","model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello world"}]}],"usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7,"input_tokens_details":{"cached_tokens":2}}}"#
    }

    private static func mockUpstreamCompletedResponsePayload(text: String) -> String {
        #"{"id":"resp_test","object":"response","created_at":1710000000,"status":"completed","model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}],"usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7,"input_tokens_details":{"cached_tokens":2}}}"#
    }

    private static func mockUpstreamCompletedResponseEvent(
        responseID: String,
        text: String,
        includeUsage: Bool = true
    ) -> String {
        let usageFragment = includeUsage
            ? #","usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}"#
            : ""
        return "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"\(responseID)\",\"object\":\"response\",\"created_at\":1710000000,\"status\":\"completed\",\"model\":\"gpt-5.4\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}]\(usageFragment)}}\n\n"
    }

    private static func mockOpenAIChatCompletionPayload(
        text: String,
        model: String,
        includeUsage: Bool = true,
        cacheHitTokens: Int? = nil,
        reasoningContent: String? = nil
    ) -> String {
        let cacheHitFragment = cacheHitTokens.map {
            #","prompt_cache_hit_tokens":\#($0),"prompt_cache_miss_tokens":\#(max(0, 5 - $0))"#
        } ?? ""
        let usageFragment = includeUsage
            ? #","usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12\#(cacheHitFragment)}"#
            : ""
        let reasoningFragment = reasoningContent.map {
            #","reasoning_content":"\#($0)""#
        } ?? ""
        return """
        {
          "id": "chatcmpl_generic",
          "object": "chat.completion",
          "created": 1710000000,
          "model": "\(model)",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "\(text)"\(reasoningFragment)
              },
              "finish_reason": "stop"
            }
          ]\(usageFragment)
        }
        """
    }

    private static func mockOpenAIChatCompletionToolCallPayload(
        model: String,
        callID: String,
        name: String,
        arguments: String,
        includeUsage: Bool = true,
        cacheHitTokens: Int? = nil,
        reasoningContent: String? = nil
    ) -> String {
        let cacheHitFragment = cacheHitTokens.map {
            #","prompt_cache_hit_tokens":\#($0),"prompt_cache_miss_tokens":\#(max(0, 5 - $0))"#
        } ?? ""
        let usageFragment = includeUsage
            ? #","usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12\#(cacheHitFragment)}"#
            : ""
        let reasoningFragment = reasoningContent.map {
            #","reasoning_content":"\#($0)""#
        } ?? ""
        return """
        {
          "id": "chatcmpl_generic_tool",
          "object": "chat.completion",
          "created": 1710000000,
          "model": "\(model)",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "id": "\(callID)",
                    "type": "function",
                    "function": {
                      "name": "\(name)",
                      "arguments": \(arguments.debugDescription)
                    }
                  }
                ]\(reasoningFragment)
              },
              "finish_reason": "tool_calls"
            }
          ]\(usageFragment)
        }
        """
    }

    private struct GeminiCLIV0381ReplayFixture {
        let model = "gemini-2.5-flash"
        let tmpHash = String(repeating: "e", count: 64)

        var cliHeaders: [String: String] {
            [
                "x-gemini-api-privileged-user-id": "gemini-cli-v0.38.1-replay",
            ]
        }

        var textTurnBody: String {
            """
            {
              "contents": [
                {
                  "role": "user",
                  "parts": [
                    {"text": "Summarize /.gemini/tmp/\(self.tmpHash)/workspace"}
                  ]
                }
              ]
            }
            """
        }

        var countTokensBody: String {
            """
            {
              "contents": [
                {
                  "role": "user",
                  "parts": [
                    {"text": "Count tokens for /.gemini/tmp/\(self.tmpHash)/workspace"}
                  ]
                }
              ]
            }
            """
        }

        var toolTurnInitialBody: String {
            """
            {
              "contents": [
                {
                  "role": "user",
                  "parts": [
                    {"text": "Inspect /.gemini/tmp/\(self.tmpHash)/workspace"}
                  ]
                }
              ],
              "tools": [
                {
                  "functionDeclarations": [
                    {
                      "name": "run_command",
                      "description": "Run a shell command",
                      "parameters": {
                        "type": "object",
                        "properties": {
                          "command": {"type": "string"}
                        },
                        "required": ["command"]
                      }
                    }
                  ]
                }
              ],
              "toolConfig": {
                "functionCallingConfig": {
                  "mode": "ANY",
                  "allowedFunctionNames": ["run_command"]
                }
              }
            }
            """
        }

        func toolTurnFollowupBody(thoughtSignature: String) -> String {
            """
            {
              "contents": [
                {
                  "role": "user",
                  "parts": [
                    {"text": "Inspect /.gemini/tmp/\(self.tmpHash)/workspace"}
                  ]
                },
                {
                  "role": "model",
                  "parts": [
                    {
                      "functionCall": {
                        "id": "call_cli_tool_turn_1",
                        "name": "run_command",
                        "args": {"command": "ls"}
                      },
                      "thoughtSignature": "\(thoughtSignature)"
                    }
                  ]
                },
                {
                  "role": "tool",
                  "parts": [
                    {
                      "functionResponse": {
                        "id": "call_cli_tool_turn_1",
                        "name": "run_command",
                        "response": {"output": "file.txt"}
                      },
                      "thoughtSignature": "\(thoughtSignature)"
                    }
                  ]
                }
              ],
              "tools": [
                {
                  "functionDeclarations": [
                    {
                      "name": "run_command",
                      "description": "Run a shell command",
                      "parameters": {
                        "type": "object",
                        "properties": {
                          "command": {"type": "string"}
                        },
                        "required": ["command"]
                      }
                    }
                  ]
                }
              ],
              "toolConfig": {
                "functionCallingConfig": {
                  "mode": "ANY",
                  "allowedFunctionNames": ["run_command"]
                }
              }
            }
            """
        }
    }

    private static func chatCompletionMessages(from body: String) throws -> [[String: Any]] {
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(payload["messages"] as? [[String: Any]])
    }

    private static func firstChatSystemPrompt(in body: String) throws -> String {
        let messages = try self.chatCompletionMessages(from: body)
        let systemMessage = try XCTUnwrap(
            messages.first(where: { ($0["role"] as? String) == "system" })
        )
        return try XCTUnwrap(systemMessage["content"] as? String)
    }

    private static func containsAssistantInputText(in rawInput: Any?) -> Bool {
        guard let input = rawInput as? [[String: Any]] else { return false }
        for item in input {
            guard (item["type"] as? String) == "message",
                  ((item["role"] as? String) ?? "").lowercased() == "assistant",
                  let content = item["content"] as? [[String: Any]]
            else {
                continue
            }
            if content.contains(where: { ($0["type"] as? String) == "input_text" }) {
                return true
            }
        }
        return false
    }

    private static func makeFailingUpstreamApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.post("backend-api/codex/responses") { _, _ in
            var headers = HTTPFields()
            headers.append(.init(name: .contentType, value: "application/json; charset=utf-8"))
            return Response(
                status: .tooManyRequests,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"too many requests"}"#))
            )
        }
        return Application(router: router)
    }

    private static func makeGenericOpenAIErrorApplication(
        status: HTTPResponse.Status,
        body: String
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("v1/models") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5.4","object":"model","created":0,"owned_by":"openai"}]}"#))
            )
        }
        router.post("v1/responses") { _, _ in
            Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
        return Application(router: router)
    }

    private static func makeUsageFailureApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .internalServerError,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"usage unavailable"}"#))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .internalServerError,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"usage unavailable"}"#))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .internalServerError,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"usage unavailable"}"#))
            )
        }
        return Application(router: router)
    }

    private static func makeOpenAICompatibleModelsApplication(
        status: HTTPResponse.Status = .ok,
        models: [String] = ["gpt-5.4"],
        errorMessage: String = "models unavailable"
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("v1/models") { _, _ in
            let body: String
            if status == .ok {
                let modelsJSON = models.map {
                    #"{"id":"\#($0)","object":"model","created":0,"owned_by":"openai"}"#
                }
                .joined(separator: ",")
                body = #"{"object":"list","data":[\#(modelsJSON)]}"#
            } else {
                body = #"{"error":{"message":"\#(errorMessage)"}}"#
            }
            return Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
        router.post("v1/responses") { _, _ in
            Response(
                status: status,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"id":"resp_validation","status":"completed","output":[]}"#))
            )
        }
        return Application(router: router)
    }

    private static func makeDelayedOpenAICompatibleModelsApplication(
        probe: ConcurrentRequestProbe,
        delayMS: Int64 = 100
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.get("v1/models") { _, _ async throws in
            await probe.begin()
            do {
                try await Task.sleep(for: .milliseconds(delayMS))
                await probe.end()
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[{"id":"gpt-5.4","object":"model","created":0,"owned_by":"openai"}]}"#))
                )
            } catch {
                await probe.end()
                throw error
            }
        }
        router.post("v1/responses") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"id":"resp_validation","status":"completed","output":[]}"#))
            )
        }
        return Application(router: router)
    }

    private static func makeOpenAIResponsesProbeApplication(
        probe: ResponsesRequestProbe,
        models: [String] = ["gpt-5", "gpt-5.4"]
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.get("v1/models") { _, _ in
            let modelsJSON = models.map {
                #"{"id":"\#($0)","object":"model","created":0,"owned_by":"openai"}"#
            }
            .joined(separator: ",")
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"object":"list","data":[\#(modelsJSON)]}"#))
            )
        }

        router.post("v1/responses") { request, _ async throws -> Response in
            let bodyText = try await Self.string(from: request.body)
            await probe.record(
                body: bodyText,
                authorization: request.headers[.authorization]
            )
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload(text: "OpenAI route")))
            )
        }

        return Application(router: router)
    }

    private static func makeGenericOpenAICompatibilityApplication(
        probe: GenericOpenAICompatibilityProbe,
        routePrefix: String = "v1",
        modelsStatus: HTTPResponse.Status = .ok,
        listedModels: [String] = ["gpt-5", "gpt-5.4"],
        chatCompletionsAvailable: Bool = true,
        chatCompletionsIncludeUsage: Bool = true,
        chatCompletionsCacheHitTokens: Int? = nil,
        chatCompletionsStreamTermination: String? = nil,
        chatCompletionsReasoningContent: String? = nil,
        requireReasoningContentForAssistantHistory: Bool = false,
        requireReasoningContentForAssistantToolCallHistory: Bool = false,
        responsesAvailable: Bool = true,
        responsesIncludeUsage: Bool = true,
        unsupportedValidationResponseModels: Set<String> = [],
        toolTurnMode: Bool = false,
        responsesStreamTermination: String? = nil
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let normalizedPrefix = routePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func route(_ path: String) -> RouterPath {
            RouterPath(normalizedPrefix.isEmpty ? path : "\(normalizedPrefix)/\(path)")
        }

        router.get(route("models")) { request, _ async throws -> Response in
            await probe.recordModelsHit(authorization: request.headers[.authorization])
            guard modelsStatus == .ok else {
                return Response(
                    status: modelsStatus,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"models missing"}}"#
                        )
                    )
                )
            }
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: #"{"object":"list","data":[\#(listedModels.map { #"{"id":"\#($0)","object":"model","created":0,"owned_by":"openai"}"# }.joined(separator: ","))]}"#
                    )
                )
            )
        }

        router.post(route("chat/completions")) { request, _ async throws -> Response in
            let bodyText = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? "gpt-5"
            await probe.recordChatHit(
                body: bodyText,
                authorization: request.headers[.authorization]
            )

            guard chatCompletionsAvailable else {
                return Response(
                    status: .notFound,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"POST /v1/chat/completions not found"}}"#
                        )
                    )
                )
            }

            if requireReasoningContentForAssistantHistory {
                let messages = payload["messages"] as? [[String: Any]] ?? []
                let assistantHistory = messages.filter { (($0["role"] as? String) ?? "").lowercased() == "assistant" }
                if assistantHistory.contains(where: {
                    (($0["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }) {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: #"{"error":{"message":"The `reasoning_content` in the thinking mode must be passed back to the API.","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#
                            )
                        )
                    )
                }
            }
            if requireReasoningContentForAssistantToolCallHistory {
                let messages = payload["messages"] as? [[String: Any]] ?? []
                let assistantToolCallHistory = messages.filter {
                    (($0["role"] as? String) ?? "").lowercased() == "assistant"
                        && (($0["tool_calls"] as? [[String: Any]])?.isEmpty == false)
                }
                if assistantToolCallHistory.contains(where: {
                    (($0["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }) {
                    return Response(
                        status: .badRequest,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: #"{"error":{"message":"The `reasoning_content` in the thinking mode must be passed back to the API.","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#
                            )
                        )
                    )
                }
            }

            let stream = (payload["stream"] as? Bool) ?? false
            if stream {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return Response(
                    status: .ok,
                    headers: headers,
                    body: .init { writer in
                        var writer = writer
                        if toolTurnMode, bodyText.contains(#""role":"tool""#) == false {
                            try await writer.write(ByteBuffer(string: Self.mockOpenAIChatCompletionToolCallStreamChunk(
                                model: model,
                                reasoningContent: chatCompletionsReasoningContent,
                                includeRole: true
                            )))
                            try await writer.write(ByteBuffer(string: Self.mockOpenAIChatCompletionToolCallStreamChunk(
                                model: model,
                                callID: "call_cli_tool_turn_1",
                                name: "run_command",
                                arguments: #"{"command":"ls"}"#,
                                finishReason: "tool_calls",
                                usage: chatCompletionsIncludeUsage
                                    ? ["prompt_tokens": 4, "completion_tokens": 6, "total_tokens": 10]
                                    : nil
                            )))
                            try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
                            try await writer.finish(nil)
                            return
                        }
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(
                            model: model,
                            delta: nil,
                            finishReason: nil,
                            usage: nil,
                            includeRole: true
                        )))
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(
                            model: model,
                            delta: "Generic ",
                            finishReason: nil,
                            usage: nil
                        )))
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(
                            model: model,
                            delta: "stream",
                            finishReason: nil,
                            usage: nil
                        )))
                        if let chatCompletionsStreamTermination {
                            throw MockStreamError(message: chatCompletionsStreamTermination)
                        }
                        var usage = [
                            "prompt_tokens": 4,
                            "completion_tokens": 6,
                            "total_tokens": 10,
                        ]
                        if let chatCompletionsCacheHitTokens {
                            usage["prompt_cache_hit_tokens"] = chatCompletionsCacheHitTokens
                        }
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(
                            model: model,
                            delta: nil,
                            finishReason: "stop",
                            usage: chatCompletionsIncludeUsage ? usage : nil
                        )))
                        try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
                        try await writer.finish(nil)
                    }
                )
            }

            if toolTurnMode {
                if bodyText.contains(#""role":"tool""#) {
                    return Response(
                        status: .ok,
                        headers: Self.jsonHeaders(),
                        body: .init(
                            byteBuffer: ByteBuffer(
                                string: Self.mockOpenAIChatCompletionPayload(
                                    text: "Tool turn complete",
                                    model: model,
                                    includeUsage: chatCompletionsIncludeUsage,
                                    cacheHitTokens: chatCompletionsCacheHitTokens,
                                    reasoningContent: chatCompletionsReasoningContent
                                )
                            )
                        )
                    )
                }

                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: Self.mockOpenAIChatCompletionToolCallPayload(
                                model: model,
                                callID: "call_cli_tool_turn_1",
                                name: "run_command",
                                arguments: #"{"command":"ls"}"#,
                                includeUsage: chatCompletionsIncludeUsage,
                                cacheHitTokens: chatCompletionsCacheHitTokens,
                                reasoningContent: chatCompletionsReasoningContent
                            )
                        )
                    )
                )
            }

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: Self.mockOpenAIChatCompletionPayload(
                            text: "Generic route",
                            model: model,
                            includeUsage: chatCompletionsIncludeUsage,
                            cacheHitTokens: chatCompletionsCacheHitTokens,
                            reasoningContent: chatCompletionsReasoningContent
                        )
                    )
                )
            )
        }

        router.post(route("responses")) { request, _ async throws -> Response in
            let bodyText = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any] ?? [:]
            await probe.recordResponsesHit(
                body: bodyText,
                authorization: request.headers[.authorization]
            )
            guard responsesAvailable else {
                return Response(
                    status: .notFound,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"POST /v1/responses not found"}}"#
                        )
                    )
                )
            }
            let model = payload["model"] as? String ?? ""
            if unsupportedValidationResponseModels.contains(model) {
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: #"{"error":{"message":"model `\#(model)` is not supported."}}"#
                        )
                    )
                )
            }

            let stream = (payload["stream"] as? Bool) ?? false
            if stream {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return Response(
                    status: .ok,
                    headers: headers,
                    body: .init { writer in
                        var writer = writer
                        try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_generic_fallback\",\"created_at\":1710000000}}\n\n"))
                        try await writer.write(ByteBuffer(string: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Responses fallback\"}\n\n"))
                        if let responsesStreamTermination {
                            throw MockStreamError(message: responsesStreamTermination)
                        }
                        try await writer.write(ByteBuffer(string: Self.mockUpstreamCompletedResponseEvent(
                            responseID: "resp_generic_fallback",
                            text: "Responses fallback"
                        )))
                        try await writer.finish(nil)
                    }
                )
            }

            let responseBody = responsesIncludeUsage
                ? Self.mockUpstreamCompletedResponsePayload(text: "Responses fallback")
                : #"{"id":"resp_test","object":"response","created_at":1710000000,"status":"completed","model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Responses fallback"}]}]}"#
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: responseBody))
            )
        }

        return Application(router: router)
    }

    private static func makeGeminiCompatibleUpstreamApplication(
        probe: GeminiCompatibilityProbe
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.get("v1beta/openai/models") { request, _ async throws -> Response in
            await probe.recordModelsHit(authorization: request.headers[.authorization])
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: #"{"object":"list","data":[{"id":"gemini-2.5-flash","object":"model","created":0,"owned_by":"google"}]}"#
                    )
                )
            )
        }

        router.post("v1beta/openai/chat/completions") { request, _ async throws -> Response in
            let bodyText = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? "gemini-2.5-flash"
            await probe.recordChatHit(
                body: bodyText,
                authorization: request.headers[.authorization]
            )
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: """
                        {
                          "id": "chatcmpl_gemini",
                          "object": "chat.completion",
                          "created": 1710000000,
                          "model": "\(model)",
                          "choices": [
                            {
                              "index": 0,
                              "message": {
                                "role": "assistant",
                                "content": "Gemini route"
                              },
                              "finish_reason": "stop"
                            }
                          ],
                          "usage": {
                            "prompt_tokens": 4,
                            "completion_tokens": 6,
                            "total_tokens": 10
                          }
                        }
                        """
                    )
                )
            )
        }

        return Application(router: router)
    }

    private static func makeGeminiToolTurnCompatibilityUpstreamApplication(
        probe: GeminiCompatibilityProbe
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.get("v1beta/openai/models") { request, _ async throws -> Response in
            await probe.recordModelsHit(authorization: request.headers[.authorization])
            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: #"{"object":"list","data":[{"id":"gemini-2.5-flash","object":"model","created":0,"owned_by":"google"}]}"#
                    )
                )
            )
        }

        router.post("v1beta/openai/chat/completions") { request, _ async throws -> Response in
            let bodyText = try await Self.string(from: request.body)
            let payload = try JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any] ?? [:]
            let model = payload["model"] as? String ?? "gemini-2.5-flash"
            await probe.recordChatHit(
                body: bodyText,
                authorization: request.headers[.authorization]
            )

            if bodyText.contains(#""role":"tool""#) {
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: """
                            {
                              "id": "chatcmpl_gemini_tool_turn_2",
                              "object": "chat.completion",
                              "created": 1710000001,
                              "model": "\(model)",
                              "choices": [
                                {
                                  "index": 0,
                                  "message": {
                                    "role": "assistant",
                                    "content": "Tool turn complete"
                                  },
                                  "finish_reason": "stop"
                                }
                              ],
                              "usage": {
                                "prompt_tokens": 8,
                                "completion_tokens": 6,
                                "total_tokens": 14
                              }
                            }
                            """
                        )
                    )
                )
            }

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: """
                        {
                          "id": "chatcmpl_gemini_tool_turn_1",
                          "object": "chat.completion",
                          "created": 1710000000,
                          "model": "\(model)",
                          "choices": [
                            {
                              "index": 0,
                              "message": {
                                "role": "assistant",
                                "content": "",
                                "tool_calls": [
                                  {
                                    "id": "call_tool_turn_1",
                                    "type": "function",
                                    "function": {
                                      "name": "run_command",
                                      "arguments": "{\\"command\\":\\"ls\\"}"
                                    }
                                  }
                                ]
                              },
                              "finish_reason": "tool_calls"
                            }
                          ],
                          "usage": {
                            "prompt_tokens": 5,
                            "completion_tokens": 4,
                            "total_tokens": 9
                          }
                        }
                        """
                    )
                )
            )
        }

        return Application(router: router)
    }

    func testAdminAccountModelRoutingUpdateRoutePersistsConfig() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let controller = try Self.makeController(dataDirectory: dataDirectory, manageManagedProxyRuntime: false)
        let config = try await controller.loadConfig()
        let service = DaemonHTTPService(
            controller: controller,
            publicHost: "127.0.0.1",
            publicPort: 8787,
            adminPort: 8788
        )

        let upstream = Self.makeUpstreamApplication()
        try await upstream.test(.ahc()) { upstreamClient in
            let added = try await controller.manualAddAPIKeyAccount(
                .init(
                    label: "Model Routing",
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                    apiKey: "sk-route-model"
                )
            )

            let response = await service.handle(
                Self.makeAdminRequest(
                    method: "PATCH",
                    path: "/admin/accounts/\(added.id)/model-routing",
                    body: """
                    {
                      "defaultTargetModel": "  custom-default  ",
                      "mappings": [
                        {"sourceModel":" gpt-5.4 ","targetModel":" first-target "},
                        {"sourceModel":"gpt-5.4","targetModel":"override-target"},
                        {"sourceModel":"","targetModel":"ignored"}
                      ]
                    }
                    """,
                    adminToken: config.adminToken
                ),
                kind: .admin
            )
            let body = try await Self.data(from: response.body)
            XCTAssertEqual(response.statusCode, 200, Self.string(from: body))

            let updated = try Helpers.readJSON(AccountSummary.self, from: body)
            XCTAssertEqual(
                updated.modelRouting,
                AccountModelRoutingConfig(
                    defaultTargetModel: "custom-default",
                    mappings: [.init(sourceModel: "gpt-5.4", targetModel: "override-target")]
                )
            )

            let accounts = try await controller.listAccounts()
            XCTAssertEqual(accounts.first?.modelRouting, updated.modelRouting)
        }
    }

    func testAccountModelRoutingOverridesAliyunPresetForResponsesAndChatCompletions() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AliyunCodingPlanProbe()
        let upstream = Self.makeAliyunCodingPlanUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Aliyun Routed",
                    providerPreset: .aliyunQwenCodingPlan,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-aliyun-model-routing",
                    enabled: true
                )
            )
            _ = try await harness.controller.updateAccountModelRouting(
                id: added.id,
                input: UpdateAccountModelRoutingRequest(
                    mappings: [.init(sourceModel: "gpt-5.4", targetModel: "account-final-model")]
                )
            )

            let responses = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/responses",
                    body: #"{"model":"gpt-5.4","input":"hello","stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let responsesBody = try await Self.data(from: responses.body)
            XCTAssertEqual(responses.statusCode, 200, Self.string(from: responsesBody))

            let chat = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/chat/completions",
                    body: #"{"model":"gpt-5.4","messages":[{"role":"user","content":"hello"}],"stream":false}"#,
                    proxyKey: harness.config.proxyAPIKey
                ),
                kind: .publicAPI
            )
            let chatBody = try await Self.data(from: chat.body)
            XCTAssertEqual(chat.statusCode, 200, Self.string(from: chatBody))

            let snapshot = await probe.snapshot()
            let routedBodies = Array(snapshot.requestBodies.suffix(2))
            XCTAssertEqual(routedBodies.count, 2)
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""model":"account-final-model""#) })
            XCTAssertFalse(routedBodies.contains(where: { $0.contains(#""model":"qwen"#) || $0.contains(#""model":"glm"#) }))
        }
    }

    func testAnthropicAccountModelRoutingOverridesGlobalMappingForMessagesAndCountTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = AnthropicAPIKeyProbe()
        let upstream = Self.makeAnthropicAPIKeyUpstreamApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.anthropicModelMappings = [
                .init(sourceModel: "claude-sonnet-4-5", targetModel: "gpt-5.4"),
            ]
            _ = try await harness.controller.saveConfig(config)

            let added = try await harness.controller.manualAddAPIKeyAccount(
                ManualAPIKeyAccountInput(
                    label: "Anthropic Routed",
                    providerPreset: .anthropicAPICompatible,
                    baseURL: "http://localhost:\(upstreamClient.port ?? 0)/v1",
                    apiKey: "sk-anthropic-model-routing",
                    enabled: true
                )
            )
            _ = try await harness.controller.updateAccountModelRouting(
                id: added.id,
                input: UpdateAccountModelRoutingRequest(
                    mappings: [.init(sourceModel: "claude-sonnet-4-5", targetModel: "anthropic-final-model")]
                )
            )

            let anthropicHeaders = [
                "anthropic-version": AnthropicTranscoder.defaultAnthropicVersion,
            ]
            let messages = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages",
                    body: #"{"model":"claude-sonnet-4-5","max_tokens":64,"messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: anthropicHeaders
                ),
                kind: .publicAPI
            )
            let messagesBody = try await Self.data(from: messages.body)
            XCTAssertEqual(messages.statusCode, 200, Self.string(from: messagesBody))

            let countTokens = await harness.service.handle(
                Self.makePublicRequest(
                    path: "/v1/messages/count_tokens",
                    body: #"{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":[{"type":"text","text":"count"}]}]}"#,
                    proxyKey: harness.config.proxyAPIKey,
                    extraHeaders: anthropicHeaders
                ),
                kind: .publicAPI
            )
            let countTokensBody = try await Self.data(from: countTokens.body)
            XCTAssertEqual(countTokens.statusCode, 200, Self.string(from: countTokensBody))

            let snapshot = await probe.snapshot()
            let routedBodies = Array(snapshot.requestBodies.suffix(2))
            XCTAssertEqual(routedBodies.count, 2)
            XCTAssertTrue(routedBodies.allSatisfy { $0.contains(#""model":"anthropic-final-model""#) })
            XCTAssertFalse(routedBodies.contains(where: { $0.contains(#""model":"gpt-5.4""#) }))
        }
    }

    func testGeminiAccountModelRoutingUsesDefaultTargetForGenerateContentAndCountTokens() async throws {
        let harness = try await Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.dataDirectory) }

        let probe = GeminiOAuthProbe()
        let upstream = Self.makeGeminiOAuthProviderApplication(probe: probe)
        try await upstream.test(.ahc()) { upstreamClient in
            var config = try await harness.controller.loadConfig()
            config.proxyAPIKeys = [
                ProxyAPIKeyRecord(
                    id: "gemini-only",
                    label: "Gemini Only",
                    key: "sk-local-gemini-only",
                    dataSource: .gemini,
                    enabled: true,
                    createdAt: 1
                ),
            ]
            config.primaryProxyAPIKeyID = "gemini-only"
            _ = try await harness.controller.saveConfig(config)

            let secretRef = try harness.controller.secretStore.saveGeminiOAuthSecret(
                GeminiOAuthSecretBundle(
                    accessToken: "gemini-access-live",
                    refreshToken: "gemini-refresh-live",
                    expiresAt: Helpers.now() + 3_600,
                    tokenType: "Bearer",
                    scope: GeminiAuthService.defaultOAuthScopes
                )
            )
            _ = try await harness.controller.importAuthJSONAccounts([
                .init(
                    source: "gemini-oauth-auth.json",
                    content: Self.geminiOAuthAuthJSON(
                        secretRef: secretRef,
                        baseURL: "http://localhost:\(upstreamClient.port ?? 0)",
                        projectID: "gemini-project"
                    ),
                    label: "Gemini OAuth"
                ),
            ])

            let accounts = try await harness.controller.listAccounts()
            let account = try XCTUnwrap(accounts.first)
            _ = try await harness.controller.updateAccountModelRouting(
                id: account.id,
                input: UpdateAccountModelRoutingRequest(defaultTargetModel: "custom-gemini-final")
            )

            let generate = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:generateContent",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Say hello"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-model-routing",
                    ]
                ),
                kind: .publicAPI
            )
            let generateBody = try await Self.data(from: generate.body)
            XCTAssertEqual(generate.statusCode, 200, Self.string(from: generateBody))

            let countTokens = await harness.service.handle(
                Self.makePublicGeminiRequest(
                    path: "/v1beta/models/gemini-2.5-flash:countTokens",
                    body: #"{"contents":[{"role":"user","parts":[{"text":"Count me"}]}]}"#,
                    proxyKey: "sk-local-gemini-only",
                    extraHeaders: [
                        "x-gemini-api-privileged-user-id": "gemini-cli-user-model-routing",
                    ]
                ),
                kind: .publicAPI
            )
            let countTokensBody = try await Self.data(from: countTokens.body)
            XCTAssertEqual(countTokens.statusCode, 200, Self.string(from: countTokensBody))

            let snapshot = await probe.snapshot()
            XCTAssertTrue(
                snapshot.generateBodies.last?.contains(#""model":"custom-gemini-final""#) == true,
                snapshot.generateBodies.last ?? "missing generate body"
            )
            XCTAssertTrue(
                snapshot.countTokenBodies.last?.contains(#""model":"models\/custom-gemini-final""#) == true,
                snapshot.countTokenBodies.last ?? "missing countTokens body"
            )
        }
    }

    private static func proxyHeaders(_ key: String) -> HTTPFields {
        var headers = HTTPFields()
        headers.append(.init(name: .init("x-api-key")!, value: key))
        headers.append(.init(name: .contentType, value: "application/json"))
        return headers
    }

    private static func bearerHeaders(_ token: String) -> HTTPFields {
        var headers = HTTPFields()
        headers.append(.init(name: .authorization, value: "Bearer \(token)"))
        return headers
    }

    private static func makePublicRequest(
        path: String,
        body: String,
        proxyKey: String,
        extraHeaders: [String: String] = [:]
    ) -> DaemonHTTPService.Request {
        var headers: [String: String] = [
            "x-api-key": proxyKey,
            "content-type": "application/json",
        ]
        headers.merge(extraHeaders, uniquingKeysWith: { _, new in new })
        return DaemonHTTPService.Request(
            method: "POST",
            target: path,
            path: path,
            headers: headers,
            body: Data(body.utf8)
        )
    }

    private static func makePublicGeminiRequest(
        path: String,
        body: String,
        proxyKey: String,
        extraHeaders: [String: String] = [:]
    ) -> DaemonHTTPService.Request {
        var headers: [String: String] = [
            "x-goog-api-key": proxyKey,
            "content-type": "application/json",
        ]
        headers.merge(extraHeaders, uniquingKeysWith: { _, new in new })
        return DaemonHTTPService.Request(
            method: "POST",
            target: path,
            path: path,
            headers: headers,
            body: Data(body.utf8)
        )
    }

    private static func makePublicBearerRequest(path: String, body: String, proxyKey: String) -> DaemonHTTPService.Request {
        DaemonHTTPService.Request(
            method: "POST",
            target: path,
            path: path,
            headers: [
                "authorization": "Bearer \(proxyKey)",
                "content-type": "application/json",
            ],
            body: Data(body.utf8)
        )
    }

    private static func makePublicProxyAuthorizationRequest(path: String, body: String, proxyKey: String) -> DaemonHTTPService.Request {
        DaemonHTTPService.Request(
            method: "POST",
            target: path,
            path: path,
            headers: [
                "proxy-authorization": "Bearer \(proxyKey)",
                "content-type": "application/json",
            ],
            body: Data(body.utf8)
        )
    }

    private static func makeAdminRequest(method: String, path: String, body: String = "", adminToken: String) -> DaemonHTTPService.Request {
        var headers: [String: String] = [
            "authorization": "Bearer \(adminToken)",
            "accept": "application/json",
        ]
        if !body.isEmpty {
            headers["content-type"] = "application/json"
        }
        return DaemonHTTPService.Request(
            method: method,
            target: path,
            path: path,
            headers: headers,
            body: Data(body.utf8)
        )
    }

    private static func makeAdminQueryRequest(path: String, query: String, adminToken: String) -> DaemonHTTPService.Request {
        DaemonHTTPService.Request(
            method: "GET",
            target: "\(path)?\(query)",
            path: path,
            headers: [
                "authorization": "Bearer \(adminToken)",
                "accept": "application/json",
            ],
            body: Data()
        )
    }

    private static func data(from body: DaemonHTTPService.Response.Body) async throws -> Data {
        switch body {
        case .bytes(let data):
            return data
        case .stream(let stream):
            var combined = Data()
            for try await chunk in stream {
                combined.append(chunk)
            }
            return combined
        }
    }

    private static func fetchLocalHTML(from urlString: String, acceptLanguage: String? = nil) async throws -> (Int, String) {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        if let acceptLanguage {
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (httpResponse.statusCode, String(decoding: data, as: UTF8.self))
    }

    private static func withAnthropicOAuthEnvironment<T>(
        baseURL: String,
        operation: () async throws -> T
    ) async throws -> T {
        let tokenURL = "\(baseURL)/v1/oauth/token"
        let authorizeURL = AnthropicAuthService.defaultClaudeAIAuthorizeURL
        let previousTokenURL = ProcessInfo.processInfo.environment["CLAUDE_CODE_TOKEN_URL"]
        let previousAuthorizeURL = ProcessInfo.processInfo.environment["CLAUDE_CODE_AUTHORIZE_URL"]
        setenv("CLAUDE_CODE_TOKEN_URL", tokenURL, 1)
        setenv("CLAUDE_CODE_AUTHORIZE_URL", authorizeURL, 1)
        defer {
            if let previousAuthorizeURL {
                setenv("CLAUDE_CODE_AUTHORIZE_URL", previousAuthorizeURL, 1)
            } else {
                unsetenv("CLAUDE_CODE_AUTHORIZE_URL")
            }
            if let previousTokenURL {
                setenv("CLAUDE_CODE_TOKEN_URL", previousTokenURL, 1)
            } else {
                unsetenv("CLAUDE_CODE_TOKEN_URL")
            }
        }
        return try await operation()
    }

    private static func withGeminiOAuthEnvironment<T>(
        baseURL: String,
        operation: () async throws -> T
    ) async throws -> T {
        let tokenURL = "\(baseURL)/token"
        let userInfoURL = "\(baseURL)/userinfo"
        let previousTokenURL = ProcessInfo.processInfo.environment["CODEX_PROXY_TEST_GEMINI_TOKEN_URL"]
        let previousCodeAssistBaseURL = ProcessInfo.processInfo.environment["CODEX_PROXY_TEST_GEMINI_CODE_ASSIST_BASE_URL"]
        let previousUserInfoURL = ProcessInfo.processInfo.environment["CODEX_PROXY_TEST_GEMINI_USERINFO_URL"]
        let previousClientID = ProcessInfo.processInfo.environment[GeminiAuthService.oauthClientIDEnvironmentVariable]
        let previousClientSecret = ProcessInfo.processInfo.environment[GeminiAuthService.oauthClientSecretEnvironmentVariable]
        setenv("CODEX_PROXY_TEST_GEMINI_TOKEN_URL", tokenURL, 1)
        setenv("CODEX_PROXY_TEST_GEMINI_CODE_ASSIST_BASE_URL", baseURL, 1)
        setenv("CODEX_PROXY_TEST_GEMINI_USERINFO_URL", userInfoURL, 1)
        Self.setGeminiOAuthTestCredentials()
        defer {
            if let previousClientSecret {
                setenv(GeminiAuthService.oauthClientSecretEnvironmentVariable, previousClientSecret, 1)
            } else {
                unsetenv(GeminiAuthService.oauthClientSecretEnvironmentVariable)
            }
            if let previousClientID {
                setenv(GeminiAuthService.oauthClientIDEnvironmentVariable, previousClientID, 1)
            } else {
                unsetenv(GeminiAuthService.oauthClientIDEnvironmentVariable)
            }
            if let previousUserInfoURL {
                setenv("CODEX_PROXY_TEST_GEMINI_USERINFO_URL", previousUserInfoURL, 1)
            } else {
                unsetenv("CODEX_PROXY_TEST_GEMINI_USERINFO_URL")
            }
            if let previousCodeAssistBaseURL {
                setenv("CODEX_PROXY_TEST_GEMINI_CODE_ASSIST_BASE_URL", previousCodeAssistBaseURL, 1)
            } else {
                unsetenv("CODEX_PROXY_TEST_GEMINI_CODE_ASSIST_BASE_URL")
            }
            if let previousTokenURL {
                setenv("CODEX_PROXY_TEST_GEMINI_TOKEN_URL", previousTokenURL, 1)
            } else {
                unsetenv("CODEX_PROXY_TEST_GEMINI_TOKEN_URL")
            }
        }
        return try await operation()
    }

    private static func setGeminiOAuthTestCredentials() {
        setenv(GeminiAuthService.oauthClientIDEnvironmentVariable, testGeminiOAuthClientID, 1)
        setenv(GeminiAuthService.oauthClientSecretEnvironmentVariable, testGeminiOAuthClientSecret, 1)
    }

    private static func jsonHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers.append(.init(name: .contentType, value: "application/json; charset=utf-8"))
        return headers
    }

    private static func invalidAnthropicOAuthRequestFormatResponse() -> Response {
        Response(
            status: .badRequest,
            headers: Self.jsonHeaders(),
            body: .init(
                byteBuffer: ByteBuffer(
                    string: #"{"type":"error","error":{"type":"invalid_request_error","message":"Invalid request format"},"request_id":"req_test_invalid_request_format"}"#
                )
            )
        )
    }

    private static func string(from buffer: ByteBuffer) -> String {
        String(buffer: buffer)
    }

    private static func string(from requestBody: RequestBody) async throws -> String {
        var data = Data()
        for try await chunk in requestBody {
            data.append(contentsOf: chunk.readableBytesView)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func string(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func listedModelIDs(from data: Data) throws -> [String] {
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Self.string(from: data)
        )
        let models = try XCTUnwrap(payload["data"] as? [[String: Any]], Self.string(from: data))
        return models.compactMap { $0["id"] as? String }
    }

    private static func errorMessage(from data: Data) throws -> String {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], Self.string(from: data))
        if let error = payload["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = payload["message"] as? String {
            return message
        }
        XCTFail("Expected JSON error message in payload: \(Self.string(from: data))")
        return Self.string(from: data)
    }

    private static func geminiModelNames(from data: Data) throws -> [String] {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], Self.string(from: data))
        let models = try XCTUnwrap(payload["models"] as? [[String: Any]], Self.string(from: data))
        return models.compactMap { $0["name"] as? String }
    }

    private static func assertGeminiCLIOnlyMessage(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(message.contains("official Gemini CLI sessions only"), message, file: file, line: line)
        XCTAssertTrue(message.contains("Google / Gemini Login"), message, file: file, line: line)
    }

    private static func assertGeminiRequiresGoogleLoginMessage(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(message.contains("Gemini public routes require"), message, file: file, line: line)
        XCTAssertTrue(message.contains("Google / Gemini Login"), message, file: file, line: line)
    }

    private static func chatGPTAuthJSON(
        principalID: String = "principal-1",
        accountID: String = "account-1",
        email: String = "mock@example.com",
        planType: String? = nil
    ) -> String {
        let futureExpiration = Int(Date().timeIntervalSince1970) + 3600
        var authClaim: [String: Any] = ["chatgpt_account_id": accountID]
        if let planType {
            authClaim["chatgpt_plan_type"] = planType
        }
        return """
        {
          "access_token": "\(Self.jwt([
            "sub": principalID,
            "exp": futureExpiration,
          ]))",
          "refresh_token": "refresh-token",
          "id_token": "\(Self.jwt([
            "sub": principalID,
            "email": email,
            "exp": futureExpiration,
            "https://api.openai.com/auth": authClaim,
          ]))"
        }
        """
    }

    private static func makeUsageLimitFallbackUpstreamApplication(
        counter: UpstreamHitCounter,
        resetAt: Int64
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let usagePayload = Self.mockUsagePayload()
        let accountHeaderName = HTTPField.Name("ChatGPT-Account-Id")!

        router.get("backend-api/wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("wham/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.get("api/codex/usage") { _, _ in
            Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: usagePayload))
            )
        }
        router.post("backend-api/codex/responses") { request, _ async throws -> Response in
            switch request.headers[accountHeaderName] {
            case "quota-account":
                await counter.incrementQuotaAccountResponses()
                return Response(
                    status: .init(code: 402, reasonPhrase: "Payment Required"),
                    headers: Self.jsonHeaders(),
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: """
                            {"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"free","resets_at":\(resetAt)}}
                            """
                        )
                    )
                )
            case "fallback-account":
                await counter.incrementFallbackAccountResponses()
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload()))
                )
            default:
                return Response(
                    status: .badRequest,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":{"message":"Unexpected ChatGPT account header"}}"#))
                )
            }
        }

        return Application(router: router)
    }

    private static func makeAPIKeyRoutingUpstreamApplication(
        state: APIKeyRoutingState
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.post("v1/responses") { request, _ async throws -> Response in
            let authorization = request.headers[.authorization] ?? ""
            let outcome = await state.handle(authorization: authorization)
            switch outcome {
            case .success(let text):
                return Response(
                    status: .ok,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: Self.mockUpstreamCompletedResponsePayload(text: text)))
                )
            case .failure(let message):
                return Response(
                    status: .internalServerError,
                    headers: Self.jsonHeaders(),
                    body: .init(byteBuffer: ByteBuffer(string: #"{"error":{"message":"\#(message)"}}"#))
                )
            }
        }

        return Application(router: router)
    }

    private static func makeAliyunCodingPlanUpstreamApplication(
        probe: AliyunCodingPlanProbe
    ) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()

        router.get("v1/models") { _, _ async throws -> Response in
            await probe.recordModelsHit()
            return Response(
                status: .internalServerError,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":{"message":"unexpected models probe"}}"#))
            )
        }

        router.post("v1/chat/completions") { request, _ async throws -> Response in
            let bodyText = try await Self.string(from: request.body)
            let bodyData = Data(bodyText.utf8)
            let authorization = request.headers[.authorization] ?? ""
            let userAgent = request.headers[.userAgent] ?? ""
            await probe.recordChatHit(
                body: bodyText,
                authorization: authorization,
                userAgent: userAgent
            )

            let payload = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
            let stream = (payload["stream"] as? Bool) ?? false
            let model = (payload["model"] as? String) ?? "qwen3-coder-plus"

            if stream {
                var headers = HTTPFields()
                headers.append(.init(name: .contentType, value: "text/event-stream; charset=utf-8"))
                return Response(
                    status: .ok,
                    headers: headers,
                    body: .init { writer in
                        var writer = writer
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(model: model, delta: nil, finishReason: nil, usage: nil, includeRole: true)))
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(model: model, delta: "Aliyun ", finishReason: nil, usage: nil)))
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(model: model, delta: "stream", finishReason: nil, usage: nil)))
                        try await writer.write(ByteBuffer(string: Self.mockAliyunChatCompletionStreamChunk(
                            model: model,
                            delta: nil,
                            finishReason: "stop",
                            usage: ["prompt_tokens": 4, "completion_tokens": 6, "total_tokens": 10]
                        )))
                        try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
                        try await writer.finish(nil)
                    }
                )
            }

            return Response(
                status: .ok,
                headers: Self.jsonHeaders(),
                body: .init(byteBuffer: ByteBuffer(string: Self.mockAliyunChatCompletionPayload(text: "Aliyun route", model: model)))
            )
        }

        return Application(router: router)
    }

    private static func mockAliyunChatCompletionPayload(text: String, model: String) -> String {
        """
        {
          "id": "chatcmpl_aliyun",
          "object": "chat.completion",
          "created": 1710000000,
          "model": "\(model)",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "\(text)"
              },
              "finish_reason": "stop"
            }
          ],
          "usage": {
            "prompt_tokens": 5,
            "completion_tokens": 7,
            "total_tokens": 12
          }
        }
        """
    }

    private static func mockAliyunChatCompletionStreamChunk(
        model: String,
        delta: String?,
        finishReason: String?,
        usage: [String: Int]?,
        includeRole: Bool = false
    ) -> String {
        let deltaObject: String
        if let delta {
            deltaObject = #""content":"\#(delta)""#
        } else if includeRole {
            deltaObject = #""role":"assistant""#
        } else {
            deltaObject = ""
        }

        let finishReasonValue = finishReason.map { #""\#($0)""# } ?? "null"
        let usageFragment: String
        if let usage {
            let cacheHitFragment = usage["prompt_cache_hit_tokens"].map {
                #","prompt_cache_hit_tokens":\#($0),"prompt_cache_miss_tokens":\#(max(0, (usage["prompt_tokens"] ?? 0) - $0))"#
            } ?? ""
            usageFragment = #","usage":{"prompt_tokens":\#(usage["prompt_tokens"] ?? 0),"completion_tokens":\#(usage["completion_tokens"] ?? 0),"total_tokens":\#(usage["total_tokens"] ?? 0)\#(cacheHitFragment)}"#
        } else {
            usageFragment = ""
        }

        let deltaJSON = deltaObject.isEmpty ? "{}" : "{\(deltaObject)}"
        return #"data: {"id":"chatcmpl_aliyun","object":"chat.completion.chunk","created":1710000000,"model":"\#(model)","choices":[{"index":0,"delta":\#(deltaJSON),"finish_reason":\#(finishReasonValue)}]\#(usageFragment)}"#
            + "\n\n"
    }

    private static func mockOpenAIChatCompletionToolCallStreamChunk(
        model: String,
        callID: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        reasoningContent: String? = nil,
        finishReason: String? = nil,
        usage: [String: Int]? = nil,
        includeRole: Bool = false
    ) -> String {
        var delta: [String] = []
        if includeRole {
            delta.append(#""role":"assistant""#)
        }
        if let reasoningContent {
            delta.append(#""reasoning_content":"\#(reasoningContent)""#)
        }
        if let callID {
            let nameFragment = name.map { #","name":"\#($0)""# } ?? ""
            let argumentsFragment = arguments.map { #","arguments":\#($0.debugDescription)"# } ?? ""
            delta.append(#""tool_calls":[{"index":0,"id":"\#(callID)","type":"function","function":{\#(nameFragment.dropFirst())\#(argumentsFragment)}}]"#)
        }
        let deltaJSON = delta.isEmpty ? "{}" : "{\(delta.joined(separator: ","))}"
        let finishReasonValue = finishReason.map { #""\#($0)""# } ?? "null"
        let usageFragment: String
        if let usage {
            usageFragment = #","usage":{"prompt_tokens":\#(usage["prompt_tokens"] ?? 0),"completion_tokens":\#(usage["completion_tokens"] ?? 0),"total_tokens":\#(usage["total_tokens"] ?? 0)}"#
        } else {
            usageFragment = ""
        }
        return #"data: {"id":"chatcmpl_deepseek_stream_tool","object":"chat.completion.chunk","created":1710000000,"model":"\#(model)","choices":[{"index":0,"delta":\#(deltaJSON),"finish_reason":\#(finishReasonValue)}]\#(usageFragment)}"#
            + "\n\n"
    }

    private static func openAIAPIKeyAuthJSON(baseURL: String? = nil) -> String {
        if let baseURL {
            return #"{"OPENAI_API_KEY":"sk-test-daemon-account","base_url":"\#(baseURL)"}"#
        }
        return #"{"OPENAI_API_KEY":"sk-test-daemon-account"}"#
    }

    private static func anthropicOAuthAuthJSON(
        secretRef: String,
        baseURL: String? = nil,
        principalID: String = "anthropic-principal",
        accountID: String = "anthropic-account",
        email: String = "claude@example.com",
        planType: String = "pro",
        scope: String = "user:profile user:inference",
        oauthRequestedScope: String? = "user:profile user:inference",
        oauthAuthorizeURL: String? = AnthropicAuthService.defaultClaudeAIAuthorizeURL,
        oauthLoginSource: String? = "claude_ai_subscription",
        oauthTokenURL: String? = nil
    ) -> String {
        let upstreamBaseURL = baseURL ?? "https://api.anthropic.com"
        let resolvedTokenURL = oauthTokenURL ?? "\(upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/oauth/token"
        let requestedScopeJSON = oauthRequestedScope.map { #","oauth_requested_scope":"\#($0)""# } ?? ""
        let authorizeJSON = oauthAuthorizeURL.map { #","oauth_authorize_url":"\#($0)""# } ?? ""
        let loginSourceJSON = oauthLoginSource.map { #","oauth_login_source":"\#($0)""# } ?? ""
        return """
        {
          "auth_mode": "anthropic_subscription_oauth",
          "provider_family": "anthropic",
          "secret_ref": "\(secretRef)",
          "principal_id": "\(principalID)",
          "account_id": "\(accountID)",
          "email": "\(email)",
          "plan_type": "\(planType)",
          "scope": "\(scope)",
          "oauth_client_id": "\(AnthropicAuthService.defaultClientID)",
          "oauth_token_url": "\(resolvedTokenURL)"\(requestedScopeJSON)\(authorizeJSON)\(loginSourceJSON),
          "upstream_base_url": "\(upstreamBaseURL)"
        }
        """
    }

    private static func geminiOAuthAuthJSON(
        secretRef: String,
        baseURL: String,
        principalID: String = "gemini-principal",
        accountID: String = "gemini-account",
        email: String = "gemini@example.com",
        projectID: String,
        clientID: String = GeminiAuthService.defaultOAuthClientID,
        scopes: String = GeminiAuthService.defaultOAuthScopes,
        tokenURL: String? = nil,
        authorizeURL: String = GeminiAuthService.defaultAuthorizeURL
    ) -> String {
        let resolvedTokenURL = tokenURL ?? "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/token"
        return """
        {
          "auth_mode": "gemini_api_oauth",
          "provider_family": "gemini",
          "gemini_auth_backend": "\(GeminiAuthService.googleAIProBackend)",
          "secret_ref": "\(secretRef)",
          "principal_id": "\(principalID)",
          "account_id": "\(accountID)",
          "email": "\(email)",
          "plan_type": "google_ai_pro",
          "oauth_client_id": "\(clientID)",
          "oauth_scopes": "\(scopes)",
          "oauth_authorize_url": "\(authorizeURL)",
          "oauth_token_url": "\(resolvedTokenURL)",
          "upstream_base_url": "\(baseURL)",
          "gemini_code_assist_project": "\(projectID)",
          "gemini_current_tier_id": "google_ai_pro",
          "gemini_current_tier_name": "Google AI Pro",
          "gemini_paid_tier_id": "google_ai_pro",
          "gemini_paid_tier_name": "Google AI Pro",
          "gemini_google_one_ai_credit_balance": "99"
        }
        """
    }

    private static func mockGeminiLoadCodeAssistPayload(projectID: String = "gemini-project") -> String {
        """
        {
          "currentTier": {
            "id": "google_ai_pro",
            "name": "Google AI Pro",
            "userDefinedCloudaicompanionProject": false
          },
          "paidTier": {
            "id": "google_ai_pro",
            "name": "Google AI Pro",
            "availableCredits": [
              {
                "creditType": "GOOGLE_ONE_AI",
                "creditAmount": "99"
              }
            ]
          },
          "cloudaicompanionProject": "\(projectID)"
        }
        """
    }

    private static func mockGeminiValidationRequiredError(
        validationURL: String = "https://accounts.google.com/AccountChooser"
    ) -> String {
        """
        {
          "error": {
            "code": 403,
            "message": "Verify your account to continue.",
            "status": "PERMISSION_DENIED",
            "details": [
              {
                "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                "reason": "VALIDATION_REQUIRED",
                "domain": "cloudcode-pa.googleapis.com",
                "metadata": {
                  "validation_url": "\(validationURL)",
                  "validation_error_message": "Verify your account to continue."
                }
              }
            ]
          }
        }
        """
    }

    private static func compactJSONString(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return raw
        }
        return String(decoding: compact, as: UTF8.self)
    }

    private static func formValue(_ name: String, from body: String) -> String? {
        body
            .split(separator: "&")
            .compactMap { component -> String? in
                let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == name else { return nil }
                return parts[1].removingPercentEncoding ?? parts[1]
            }
            .first
    }

    private static func jwt(_ claims: [String: Any]) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        return "\(Self.base64URL(header)).\(Self.base64URL(claims)).sig"
    }

    private static func mockUsagePayload(planType: String = "free") -> String {
        """
        {
          "plan_type": "\(planType)",
          "rate_limit": {
            "primary_window": {
              "used_percent": 15,
              "limit_window_seconds": 18000,
              "reset_at": 1893456000
            },
            "secondary_window": {
              "used_percent": 25,
              "limit_window_seconds": 604800,
              "reset_at": 1894060800
            }
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "12.50"
          }
        }
        """
    }

    private static func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeLegacyGenericGeminiManualAPIKeyRecord(
        baseURL: String,
        apiKey: String,
        label: String
    ) throws -> AccountRecord {
        let normalizedBaseURL = try OpenAICompatibleUpstream.normalizeBaseURL(
            baseURL,
            providerPreset: .genericOpenAICompatible
        )
        let accountID = OpenAICompatibleUpstream.syntheticAccountID(apiKey: apiKey, baseURL: normalizedBaseURL)
        let authJSON = """
        {
          "auth_mode": "openai_api_key",
          "provider_preset": "generic_openai_compatible",
          "upstream_base_url": "\(normalizedBaseURL)",
          "tokens": {
            "access_token": "\(apiKey)",
            "provider_preset": "generic_openai_compatible",
            "account_id": "\(accountID)"
          }
        }
        """
        let extracted = try AuthService.extractAuth(from: authJSON)
        return AccountRecord(
            label: label,
            principalID: extracted.principalID,
            email: nil,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            providerPreset: .genericOpenAICompatible,
            upstreamBaseURL: normalizedBaseURL,
            authJSON: authJSON
        )
    }

    private static func makeStoredGeminiRecordWithStaleGenericPreset(
        baseURL: String,
        apiKey: String,
        label: String
    ) throws -> AccountRecord {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: .googleGeminiCompatible
        )
        let extracted = try AuthService.extractAuth(from: normalized)
        return AccountRecord(
            label: label,
            principalID: extracted.principalID,
            email: nil,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            providerPreset: .genericOpenAICompatible,
            upstreamBaseURL: extracted.upstreamBaseURL,
            authJSON: normalized
        )
    }

    private static func makeStoredGoogleGeminiOAuthLikeRecord(
        baseURL: String,
        apiKey: String,
        label: String
    ) throws -> AccountRecord {
        let normalized = try AuthService.normalizeManualAPIKeyInput(
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: .googleGeminiCompatible
        )
        let extracted = try AuthService.extractAuth(from: normalized)
        return AccountRecord(
            label: label,
            principalID: extracted.principalID,
            email: nil,
            accountID: extracted.accountID,
            planType: extracted.planType,
            authMode: extracted.authMode,
            providerPreset: extracted.providerPreset,
            upstreamBaseURL: extracted.upstreamBaseURL,
            authJSON: normalized
        )
    }

    #if os(macOS)
    private final class TestKeychainAdapter: SecretStoreKeychainAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data]
        private let readStatusByAccount: [String: OSStatus]
        private let addStatusByAccount: [String: OSStatus]
        private let updateStatusByAccount: [String: OSStatus]
        private var reads: [String] = []

        init(
            storage: [String: Data] = [:],
            readStatusByAccount: [String: OSStatus] = [:],
            addStatusByAccount: [String: OSStatus] = [:],
            updateStatusByAccount: [String: OSStatus] = [:]
        ) {
            self.storage = storage
            self.readStatusByAccount = readStatusByAccount
            self.addStatusByAccount = addStatusByAccount
            self.updateStatusByAccount = updateStatusByAccount
        }

        func read(service: String, account: String) throws -> Data? {
            _ = service
            self.lock.lock()
            defer { self.lock.unlock() }

            self.reads.append(account)
            let status = self.readStatusByAccount[account]
                ?? (self.storage[account] == nil ? errSecItemNotFound : errSecSuccess)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess else {
                throw KeychainOperationError(operation: .read, status: status, account: account)
            }
            return self.storage[account]
        }

        func write(service: String, account: String, data: Data) throws {
            _ = service
            self.lock.lock()
            defer { self.lock.unlock() }

            let itemExists = self.storage[account] != nil
            let updateStatus = self.updateStatusByAccount[account]
                ?? (itemExists ? errSecSuccess : errSecItemNotFound)
            if updateStatus == errSecSuccess {
                self.storage[account] = data
                return
            }
            guard updateStatus == errSecItemNotFound else {
                throw KeychainOperationError(operation: .update, status: updateStatus, account: account)
            }

            let addStatus = self.addStatusByAccount[account] ?? errSecSuccess
            guard addStatus == errSecSuccess else {
                throw KeychainOperationError(operation: .add, status: addStatus, account: account)
            }
            self.storage[account] = data
        }

        func delete(service: String, account: String) throws {
            _ = service
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storage[account] = nil
        }

        func readAttempts() -> [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.reads
        }
    }

    private actor ManagedProxyRuntimeStub: ManagedProxyRuntimeControlling {
        private let secretStore: SecretStore
        private let globalEffectiveProxySettingsValue: OutboundProxySettings
        private var availableNodeNames: [String]
        private var currentNodeName: String
        private var selectedNodeNames: [String] = []
        private var desiredAccountNodeNames: [String] = []
        private var persistedAccountNodePorts: [String: Int] = [:]
        private var activeAccountNodePorts: [String: Int] = [:]
        private var resolvedAccountNodeNames: [String] = []
        private var resolvedAccountNodePorts: [Int] = []
        private var reconciledNodeNameSets: [[String]] = []
        private var nextListenerPort: Int
        private var lastSubscriptionConfigured = false
        private var lastMode: OutboundProxyMode = .disabled
        private var globalEffectiveProxySettingsCallCount = 0

        init(
            secretStore: SecretStore,
            availableNodeNames: [String] = ["Tokyo"],
            currentNodeName: String? = nil,
            effectiveProxySettingsValue: OutboundProxySettings = .init(
                scheme: .http,
                host: "127.0.0.1",
                port: ManagedProxyRuntime.defaultMixedPort
            ),
            initialListenerPort: Int = 18_900
        ) {
            self.secretStore = secretStore
            self.availableNodeNames = availableNodeNames
            self.currentNodeName = currentNodeName ?? availableNodeNames.first ?? "Tokyo"
            self.globalEffectiveProxySettingsValue = effectiveProxySettingsValue
            self.nextListenerPort = initialListenerPort
        }

        func snapshot(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot {
            self.lastMode = config.outboundProxyMode
            return try self.makeSnapshot(config: config, subscriptionURL: subscriptionURL)
        }

        func applyConfiguration(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot {
            self.lastMode = config.outboundProxyMode
            return try self.makeSnapshot(config: config, subscriptionURL: subscriptionURL)
        }

        func effectiveProxySettings(
            config: AppConfig,
            subscriptionURL: String?
        ) async throws -> OutboundProxySettings {
            self.lastMode = config.outboundProxyMode
            self.globalEffectiveProxySettingsCallCount += 1
            _ = try self.makeSnapshot(config: config, subscriptionURL: subscriptionURL)
            return self.globalEffectiveProxySettingsValue
        }

        func effectiveProxySettingsForAccountNode(
            name: String,
            config: AppConfig,
            subscriptionURL: String?
        ) async throws -> OutboundProxySettings {
            self.lastMode = config.outboundProxyMode
            _ = try self.makeSnapshot(config: config, subscriptionURL: subscriptionURL)
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.availableNodeNames.contains(trimmedName) else {
                throw ManagedProxyAccountNodeResolutionError.nodeUnavailable(trimmedName)
            }
            guard let port = self.activeAccountNodePorts[trimmedName] else {
                throw ManagedProxyAccountNodeResolutionError.listenerUnavailable(trimmedName)
            }
            self.resolvedAccountNodeNames.append(trimmedName)
            self.resolvedAccountNodePorts.append(port)
            return OutboundProxySettings(scheme: .http, host: "127.0.0.1", port: port)
        }

        func updateSubscription(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot {
            self.lastMode = config.outboundProxyMode
            return try self.makeSnapshot(config: config, subscriptionURL: subscriptionURL)
        }

        func selectNode(
            name: String,
            config: AppConfig,
            subscriptionURL: String?
        ) async throws -> ManagedProxySnapshot {
            let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (self.availableNodeNames.first ?? "Tokyo") : name
            self.selectedNodeNames.append(resolvedName)
            self.currentNodeName = resolvedName
            return try self.makeSnapshot(
                config: config,
                subscriptionURL: subscriptionURL
            )
        }

        func healthcheck(
            nodeName: String?,
            config: AppConfig,
            subscriptionURL: String?
        ) async throws -> ManagedProxySnapshot {
            self.lastMode = config.outboundProxyMode
            if let nodeName, nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                self.currentNodeName = nodeName
            }
            return try self.makeSnapshot(
                config: config,
                subscriptionURL: subscriptionURL
            )
        }

        func reconcileAccountNodeListeners(
            nodeNames: [String],
            config: AppConfig,
            subscriptionURL: String?
        ) async throws {
            self.lastMode = config.outboundProxyMode
            let normalizedURL = try ManagedProxyRuntime.validatedSubscriptionURL(subscriptionURL)
            self.lastSubscriptionConfigured = normalizedURL != nil
            let normalized = nodeNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { lhs, rhs in
                    lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
            self.desiredAccountNodeNames = normalized
            self.reconciledNodeNameSets.append(normalized)

            self.persistedAccountNodePorts = self.persistedAccountNodePorts.filter { normalized.contains($0.key) }
            for nodeName in normalized where self.persistedAccountNodePorts[nodeName] == nil {
                self.persistedAccountNodePorts[nodeName] = self.nextListenerPort
                self.nextListenerPort += 1
            }
            self.rebuildActiveAccountNodePorts()
        }

        func stop() async {
            self.lastSubscriptionConfigured = false
            self.activeAccountNodePorts = [:]
        }

        func setAvailableNodeNames(_ names: [String]) {
            self.availableNodeNames = names
            if names.contains(self.currentNodeName) == false, let first = names.first {
                self.currentNodeName = first
            }
            self.rebuildActiveAccountNodePorts()
        }

        func snapshotSelectedNodeNames() -> [String] {
            self.selectedNodeNames
        }

        func snapshotActiveAccountNodePorts() -> [String: Int] {
            self.activeAccountNodePorts
        }

        func snapshotReconciledNodeNameSets() -> [[String]] {
            self.reconciledNodeNameSets
        }

        func snapshotResolvedAccountNodeNames() -> [String] {
            self.resolvedAccountNodeNames
        }

        func snapshotResolvedAccountNodePorts() -> [Int] {
            self.resolvedAccountNodePorts
        }

        func snapshotGlobalEffectiveProxySettingsCallCount() -> Int {
            self.globalEffectiveProxySettingsCallCount
        }

        private func rebuildActiveAccountNodePorts() {
            guard self.lastSubscriptionConfigured else {
                self.activeAccountNodePorts = [:]
                return
            }
            self.activeAccountNodePorts = self.persistedAccountNodePorts.filter { key, _ in
                self.availableNodeNames.contains(key)
            }
        }

        private func makeSnapshot(
            config: AppConfig,
            subscriptionURL: String?
        ) throws -> ManagedProxySnapshot {
            let normalizedURL = try ManagedProxyRuntime.validatedSubscriptionURL(subscriptionURL)
            self.lastSubscriptionConfigured = normalizedURL != nil
            self.rebuildActiveAccountNodePorts()
            guard let normalizedURL else {
                return ManagedProxySnapshot(
                    mode: config.outboundProxyMode,
                    subscriptionConfigured: false,
                    subscriptionURL: nil,
                    healthcheckURL: config.managedProxySummary.healthcheckURL,
                    runtimeState: .stopped,
                    controllerReachable: false,
                    lastError: "订阅地址未配置。"
                )
            }

            let secret = try self.secretStore.mihomoControllerSecret()
            let trimmedPinnedNode = config.managedProxySummary.selectedNodeName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedPinnedNode = trimmedPinnedNode.isEmpty ? nil : trimmedPinnedNode
            return ManagedProxySnapshot(
                mode: config.outboundProxyMode,
                subscriptionConfigured: true,
                subscriptionURL: normalizedURL,
                healthcheckURL: config.managedProxySummary.healthcheckURL,
                runtimeState: .running,
                controllerReachable: true,
                mixedPort: ManagedProxyRuntime.defaultMixedPort,
                controllerPort: ManagedProxyRuntime.defaultControllerPort,
                currentNodeName: self.currentNodeName,
                pinnedNodeName: resolvedPinnedNode,
                pinnedNodeAvailable: resolvedPinnedNode == nil || self.availableNodeNames.contains(resolvedPinnedNode!),
                listeners: [
                    ManagedProxyListener(
                        kind: .mixedPort,
                        listenHost: "127.0.0.1",
                        port: ManagedProxyRuntime.defaultMixedPort,
                        nodeName: self.currentNodeName
                    ),
                ] + self.activeAccountNodePorts.keys.sorted().compactMap { nodeName in
                    guard let port = self.activeAccountNodePorts[nodeName] else { return nil }
                    return ManagedProxyListener(
                        kind: .nodeListener,
                        listenHost: "127.0.0.1",
                        port: port,
                        nodeName: nodeName
                    )
                },
                nodes: self.availableNodeNames.enumerated().map { index, name in
                    ManagedProxyNode(
                        name: name,
                        type: index == 0 ? "ss" : "vmess",
                        isCurrent: name == self.currentNodeName,
                        isPinned: resolvedPinnedNode == name,
                        alive: secret.isEmpty == false,
                        lastDelayMS: index == 0 ? 68 : 84,
                        lastHealthcheckAt: 1_710_000_100
                    )
                }
            )
        }
    }
    #endif

    private struct Harness {
        var dataDirectory: URL
        var controller: DaemonController
        var service: DaemonHTTPService
        var config: AppConfig
    }

    private enum MockStreamTermination {
        case throwError(String)
        case prematureEOF
    }

    private struct MockStreamError: LocalizedError {
        let message: String

        var errorDescription: String? { self.message }
    }

    private actor UpstreamHitCounter {
        private var quotaAccountResponses = 0
        private var fallbackAccountResponses = 0

        func incrementQuotaAccountResponses() {
            self.quotaAccountResponses += 1
        }

        func incrementFallbackAccountResponses() {
            self.fallbackAccountResponses += 1
        }

        func snapshot() -> (quotaAccountResponses: Int, fallbackAccountResponses: Int) {
            (self.quotaAccountResponses, self.fallbackAccountResponses)
        }
    }

    private actor ConcurrentRequestProbe {
        private var activeHits = 0
        private var maxActiveHits = 0
        private var totalHits = 0

        func begin() {
            self.activeHits += 1
            self.totalHits += 1
            self.maxActiveHits = max(self.maxActiveHits, self.activeHits)
        }

        func end() {
            self.activeHits -= 1
        }

        func reset() {
            self.activeHits = 0
            self.maxActiveHits = 0
            self.totalHits = 0
        }

        func snapshot() -> (totalHits: Int, maxActiveHits: Int) {
            (self.totalHits, self.maxActiveHits)
        }
    }

    private actor APIKeyRoutingState {
        enum Mode {
            case success(text: String)
            case failure(message: String)
        }

        enum Outcome {
            case success(String)
            case failure(String)
        }

        private let firstMode: Mode
        private let secondMode: Mode
        private var firstHits = 0
        private var secondHits = 0

        init(firstMode: Mode, secondMode: Mode) {
            self.firstMode = firstMode
            self.secondMode = secondMode
        }

        func handle(authorization: String) -> Outcome {
            switch authorization {
            case "Bearer sk-route-first":
                self.firstHits += 1
                return self.outcome(for: self.firstMode)
            case "Bearer sk-route-second":
                self.secondHits += 1
                return self.outcome(for: self.secondMode)
            default:
                return .failure("unexpected authorization")
            }
        }

        func snapshot() -> (firstHits: Int, secondHits: Int) {
            (self.firstHits, self.secondHits)
        }

        func reset() {
            self.firstHits = 0
            self.secondHits = 0
        }

        private func outcome(for mode: Mode) -> Outcome {
            switch mode {
            case .success(let text):
                return .success(text)
            case .failure(let message):
                return .failure(message)
            }
        }
    }

    private actor AliyunCodingPlanProbe {
        private var modelsHits = 0
        private var chatHits = 0
        private var requestBodies: [String] = []
        private var lastAuthorization = ""
        private var lastUserAgent = ""

        func recordModelsHit() {
            self.modelsHits += 1
        }

        func recordChatHit(body: String, authorization: String, userAgent: String) {
            self.chatHits += 1
            self.requestBodies.append(body)
            self.lastAuthorization = authorization
            self.lastUserAgent = userAgent
        }

        func snapshot() -> (
            modelsHits: Int,
            chatHits: Int,
            requestBodies: [String],
            lastAuthorization: String,
            lastUserAgent: String
        ) {
            (
                self.modelsHits,
                self.chatHits,
                self.requestBodies,
                self.lastAuthorization,
                self.lastUserAgent
            )
        }
    }

    private actor GeminiCompatibilityProbe {
        private var modelsHits = 0
        private var chatHits = 0
        private var requestBodies: [String] = []
        private var lastAuthorization = ""
        private var chatAuthorizations: [String] = []

        func recordModelsHit(authorization: String?) {
            self.modelsHits += 1
            self.lastAuthorization = authorization ?? ""
        }

        func recordChatHit(body: String, authorization: String?) {
            self.chatHits += 1
            self.requestBodies.append(body)
            self.lastAuthorization = authorization ?? ""
            self.chatAuthorizations.append(authorization ?? "")
        }

        func snapshot() -> (
            modelsHits: Int,
            chatHits: Int,
            requestBodies: [String],
            lastAuthorization: String
        ) {
            (
                self.modelsHits,
                self.chatHits,
                self.requestBodies,
                self.lastAuthorization
            )
        }

        func chatAuthorizationHistory() -> [String] {
            self.chatAuthorizations
        }
    }

    private actor GenericOpenAICompatibilityProbe {
        private var modelsHits = 0
        private var chatHits = 0
        private var responsesHits = 0
        private var chatRequestBodies: [String] = []
        private var responsesRequestBodies: [String] = []
        private var lastAuthorization = ""

        func recordModelsHit(authorization: String?) {
            self.modelsHits += 1
            self.lastAuthorization = authorization ?? ""
        }

        func recordChatHit(body: String, authorization: String?) {
            self.chatHits += 1
            self.chatRequestBodies.append(body)
            self.lastAuthorization = authorization ?? ""
        }

        func recordResponsesHit(body: String, authorization: String?) {
            self.responsesHits += 1
            self.responsesRequestBodies.append(body)
            self.lastAuthorization = authorization ?? ""
        }

        func snapshot() -> (
            modelsHits: Int,
            chatHits: Int,
            responsesHits: Int,
            chatRequestBodies: [String],
            responsesRequestBodies: [String],
            lastAuthorization: String
        ) {
            (
                self.modelsHits,
                self.chatHits,
                self.responsesHits,
                self.chatRequestBodies,
                self.responsesRequestBodies,
                self.lastAuthorization
            )
        }
    }

    private actor GeminiOAuthProbe {
        private var tokenRequestBodies: [String] = []
        private var loadCodeAssistHits = 0
        private var loadCodeAssistBodies: [String] = []
        private var onboardUserHits = 0
        private var onboardUserBodies: [String] = []
        private var operationPollHits = 0
        private var generateHits = 0
        private var streamGenerateHits = 0
        private var countTokensHits = 0
        private var lastAuthorization = ""
        private var generateBodies: [String] = []
        private var streamGenerateBodies: [String] = []
        private var countTokenBodies: [String] = []

        func recordTokenRequest(_ body: String) {
            self.tokenRequestBodies.append(body)
        }

        func recordLoadCodeAssistHit(body: String, authorization: String?) {
            self.loadCodeAssistHits += 1
            self.loadCodeAssistBodies.append(body)
            self.lastAuthorization = authorization ?? ""
        }

        func recordOnboardUserHit(body: String, authorization: String?) {
            self.onboardUserHits += 1
            self.onboardUserBodies.append(body)
            self.lastAuthorization = authorization ?? ""
        }

        func recordOperationPollHit(authorization: String?) {
            self.operationPollHits += 1
            self.lastAuthorization = authorization ?? ""
        }

        func recordGenerateHit(body: String, authorization: String?) {
            self.generateHits += 1
            self.generateBodies.append(body)
            self.lastAuthorization = authorization ?? ""
        }

        func recordStreamGenerateHit(body: String, authorization: String?) {
            self.streamGenerateHits += 1
            self.streamGenerateBodies.append(body)
            self.lastAuthorization = authorization ?? ""
        }

        func recordCountTokensHit(body: String, authorization: String?) {
            self.countTokensHits += 1
            self.countTokenBodies.append(body)
            self.lastAuthorization = authorization ?? ""
        }

        func snapshot() -> (
            tokenRequestBodies: [String],
            loadCodeAssistHits: Int,
            loadCodeAssistBodies: [String],
            onboardUserHits: Int,
            onboardUserBodies: [String],
            operationPollHits: Int,
            generateHits: Int,
            streamGenerateHits: Int,
            countTokensHits: Int,
            lastAuthorization: String,
            generateBodies: [String],
            streamGenerateBodies: [String],
            countTokenBodies: [String]
        ) {
            (
                self.tokenRequestBodies,
                self.loadCodeAssistHits,
                self.loadCodeAssistBodies,
                self.onboardUserHits,
                self.onboardUserBodies,
                self.operationPollHits,
                self.generateHits,
                self.streamGenerateHits,
                self.countTokensHits,
                self.lastAuthorization,
                self.generateBodies,
                self.streamGenerateBodies,
                self.countTokenBodies
            )
        }
    }

    private actor GeminiOAuthResponseSequence {
        private let loadResponses: [String]
        private let operationResponses: [String]
        private var loadIndex = 0
        private var operationIndex = 0

        init(loadResponses: [String], operationResponses: [String]) {
            self.loadResponses = loadResponses
            self.operationResponses = operationResponses
        }

        func nextLoadResponse() -> String {
            let index = min(self.loadIndex, max(self.loadResponses.count - 1, 0))
            self.loadIndex += 1
            return self.loadResponses[index]
        }

        func nextOperationResponse() -> String {
            let index = min(self.operationIndex, max(self.operationResponses.count - 1, 0))
            self.operationIndex += 1
            return self.operationResponses[index]
        }
    }

    private actor ResponsesRequestProbe {
        private var requestBodies: [String] = []
        private var authorizations: [String] = []

        func record(body: String, authorization: String?) {
            self.requestBodies.append(body)
            self.authorizations.append(authorization ?? "")
        }

        func snapshot() -> (requestBodies: [String], authorizations: [String]) {
            (self.requestBodies, self.authorizations)
        }
    }

    private actor AnthropicAPIKeyProbe {
        private var modelsHits = 0
        private var messagesHits = 0
        private var countTokensHits = 0
        private var requestBodies: [String] = []
        private var lastAPIKey: String?
        private var lastAuthorization: String?
        private var lastAnthropicVersion: String?
        private var lastAnthropicBeta: String?

        func recordModelsHit(
            apiKey: String?,
            authorization: String?,
            anthropicVersion: String?,
            anthropicBeta: String?
        ) {
            self.modelsHits += 1
            self.lastAPIKey = apiKey
            self.lastAuthorization = authorization
            self.lastAnthropicVersion = anthropicVersion
            self.lastAnthropicBeta = anthropicBeta
        }

        func recordMessagesHit(
            body: String,
            apiKey: String?,
            authorization: String?,
            anthropicVersion: String?,
            anthropicBeta: String?
        ) {
            self.messagesHits += 1
            self.requestBodies.append(body)
            self.lastAPIKey = apiKey
            self.lastAuthorization = authorization
            self.lastAnthropicVersion = anthropicVersion
            self.lastAnthropicBeta = anthropicBeta
        }

        func recordCountTokensHit(
            body: String,
            apiKey: String?,
            authorization: String?,
            anthropicVersion: String?,
            anthropicBeta: String?
        ) {
            self.countTokensHits += 1
            self.requestBodies.append(body)
            self.lastAPIKey = apiKey
            self.lastAuthorization = authorization
            self.lastAnthropicVersion = anthropicVersion
            self.lastAnthropicBeta = anthropicBeta
        }

        func snapshot() -> (
            modelsHits: Int,
            messagesHits: Int,
            countTokensHits: Int,
            requestBodies: [String],
            lastAPIKey: String?,
            lastAuthorization: String?,
            lastAnthropicVersion: String?,
            lastAnthropicBeta: String?
        ) {
            (
                self.modelsHits,
                self.messagesHits,
                self.countTokensHits,
                self.requestBodies,
                self.lastAPIKey,
                self.lastAuthorization,
                self.lastAnthropicVersion,
                self.lastAnthropicBeta
            )
        }
    }

    private actor PromptCacheProbe {
        private var entries: [(sessionID: String, promptCacheKey: String)] = []

        func record(sessionID: String, promptCacheKey: String) {
            self.entries.append((sessionID: sessionID, promptCacheKey: promptCacheKey))
        }

        func snapshot() -> [(sessionID: String, promptCacheKey: String)] {
            self.entries
        }
    }
}
