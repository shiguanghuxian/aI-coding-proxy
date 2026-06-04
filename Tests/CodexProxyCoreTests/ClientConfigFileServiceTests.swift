import Foundation
import XCTest
@testable import CodexProxyCore

final class ClientConfigFileServiceTests: XCTestCase {
    func testInspectAllRecognizesMatchedExternalAndMissingConfigurations() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        try Self.write(
            """
            {
              "OPENAI_API_KEY": "sk-local-match",
              "other": "keep"
            }
            """,
            to: context.homeDirectory.appendingPathComponent(".codex/auth.json")
        )
        try Self.write(
            """
            model_provider = "custom"

            [model_providers.custom]
            base_url = "http://127.0.0.1:8787/v1"
            name = "custom"
            requires_openai_auth = true
            wire_api = "responses"
            """,
            to: context.homeDirectory.appendingPathComponent(".codex/config.toml")
        )
        try Self.write(
            """
            {
              "env": {
                "ANTHROPIC_AUTH_TOKEN": "sk-external-claude",
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"
              },
              "model": "opus"
            }
            """,
            to: context.homeDirectory.appendingPathComponent(".claude/settings.json")
        )

        let inspections = context.service.inspectAll(
            availableProxyAPIKeys: [
                ProxyAPIKeyRecord(id: "matched", label: "Matched", key: "sk-local-match", dataSource: .all, enabled: true, createdAt: 1),
                ProxyAPIKeyRecord(id: "other", label: "Other", key: "sk-local-other", dataSource: .all, enabled: true, createdAt: 2),
            ]
        )

        let codex = try XCTUnwrap(inspections[.codex])
        XCTAssertEqual(codex.currentKeyKind, .matched)
        XCTAssertEqual(codex.matchedProxyAPIKeyID, "matched")
        XCTAssertEqual(codex.currentBaseURL, "http://127.0.0.1:8787/v1")
        XCTAssertNil(codex.errorMessage)

        let claude = try XCTUnwrap(inspections[.claudeCode])
        XCTAssertEqual(claude.currentKeyKind, .external)
        XCTAssertEqual(claude.currentBaseURL, "http://127.0.0.1:8787")
        XCTAssertNil(claude.matchedProxyAPIKeyID)

        let gemini = try XCTUnwrap(inspections[.gemini])
        XCTAssertEqual(gemini.currentKeyKind, .missing)
        XCTAssertEqual(gemini.files.map(\.exists), [false, false])
        XCTAssertNil(gemini.errorMessage)
    }

    func testApplyCodexConfigurationOnlyUpdatesManagedFields() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let authURL = context.homeDirectory.appendingPathComponent(".codex/auth.json")
        let configURL = context.homeDirectory.appendingPathComponent(".codex/config.toml")

        try Self.write(
            """
            {
              "OPENAI_API_KEY": "sk-old",
              "other": "keep"
            }
            """,
            to: authURL
        )
        try Self.write(
            """
            model = "gpt-5.5"
            model_provider = "legacy"

            [model_providers.custom]
            base_url = "http://legacy.example/v1"
            name = "legacy"
            requires_openai_auth = false
            wire_api = "chat_completions"
            timeout = 30

            [projects."/tmp/project"]
            trust_level = "trusted"
            """,
            to: configURL
        )

        _ = try context.service.applyConfiguration(
            target: .codex,
            proxyAPIKey: Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-new"),
            endpoints: Self.endpoints
        )

        let authObject = try Self.jsonObject(at: authURL)
        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, "sk-local-new")
        XCTAssertEqual(authObject["auth_mode"] as? String, "apikey")
        XCTAssertEqual(authObject["other"] as? String, "keep")

        let configText = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(configText.contains(#"model = "gpt-5.5""#))
        XCTAssertTrue(configText.contains(#"model_provider = "custom""#))
        XCTAssertTrue(configText.contains(#"base_url = "http://127.0.0.1:8787/v1""#))
        XCTAssertTrue(configText.contains(#"name = "custom""#))
        XCTAssertTrue(configText.contains(#"requires_openai_auth = true"#))
        XCTAssertTrue(configText.contains(#"wire_api = "responses""#))
        XCTAssertTrue(configText.contains(#"timeout = 30"#))
        XCTAssertTrue(configText.contains(#"[projects."/tmp/project"]"#))
    }

    func testApplyClaudeConfigurationOnlyUpdatesManagedEnvFields() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let settingsURL = context.homeDirectory.appendingPathComponent(".claude/settings.json")
        try Self.write(
            """
            {
              "env": {
                "ANTHROPIC_AUTH_TOKEN": "sk-old",
                "ANTHROPIC_BASE_URL": "http://legacy.example",
                "OTHER_VAR": "preserve"
              },
              "model": "opus",
              "includeCoAuthoredBy": false
            }
            """,
            to: settingsURL
        )

        _ = try context.service.applyConfiguration(
            target: .claudeCode,
            proxyAPIKey: Self.proxyKey(id: "claude", label: "Claude", key: "sk-local-claude"),
            endpoints: Self.endpoints
        )

        let object = try Self.jsonObject(at: settingsURL)
        let env = try XCTUnwrap(object["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-local-claude")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:8787")
        XCTAssertEqual(env["OTHER_VAR"] as? String, "preserve")
        XCTAssertEqual(object["model"] as? String, "opus")
        XCTAssertEqual(object["includeCoAuthoredBy"] as? Bool, false)
    }

    func testApplyCodexConfigurationClearsLegacyChatGPTAuthState() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let authURL = context.homeDirectory.appendingPathComponent(".codex/auth.json")
        try Self.write(
            """
            {
              "OPENAI_API_KEY": "sk-old",
              "auth_mode": "chatgpt",
              "last_refresh": "2026-04-27T12:00:00Z",
              "tokens": {
                "access_token": "chatgpt-access-token",
                "refresh_token": "chatgpt-refresh-token",
                "id_token": "chatgpt-id-token",
                "account_id": "acct-old"
              },
              "other": "keep"
            }
            """,
            to: authURL
        )

        _ = try context.service.applyConfiguration(
            target: .codex,
            proxyAPIKey: Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-new"),
            endpoints: Self.endpoints
        )

        let authObject = try Self.jsonObject(at: authURL)
        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, "sk-local-new")
        XCTAssertEqual(authObject["auth_mode"] as? String, "apikey")
        XCTAssertNil(authObject["tokens"])
        XCTAssertNil(authObject["last_refresh"])
        XCTAssertEqual(authObject["other"] as? String, "keep")
    }

    func testApplyGeminiConfigurationKeepsExtraEnvAndSetsSelectedType() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let envURL = context.homeDirectory.appendingPathComponent(".gemini/.env")
        let settingsURL = context.homeDirectory.appendingPathComponent(".gemini/settings.json")
        try Self.write(
            """
            GEMINI_MODEL=gemini-2.5-flash-lite
            GOOGLE_GEMINI_BASE_URL=http://legacy.example
            GEMINI_API_KEY=sk-old
            """,
            to: envURL
        )
        try Self.write(
            """
            {
              "security": {
                "auth": {
                  "selectedType": "oauth-personal"
                }
              },
              "general": {
                "previewFeatures": false
              }
            }
            """,
            to: settingsURL
        )

        _ = try context.service.applyConfiguration(
            target: .gemini,
            proxyAPIKey: Self.proxyKey(id: "gemini", label: "Gemini", key: "sk-local-gemini"),
            endpoints: Self.endpoints
        )

        let envText = try String(contentsOf: envURL, encoding: .utf8)
        XCTAssertTrue(envText.contains("GEMINI_MODEL=gemini-2.5-flash-lite"))
        XCTAssertTrue(envText.contains("GEMINI_API_KEY=sk-local-gemini"))
        XCTAssertTrue(envText.contains("GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:8787"))

        let settingsObject = try Self.jsonObject(at: settingsURL)
        let security = try XCTUnwrap(settingsObject["security"] as? [String: Any])
        let auth = try XCTUnwrap(security["auth"] as? [String: Any])
        let general = try XCTUnwrap(settingsObject["general"] as? [String: Any])
        XCTAssertEqual(auth["selectedType"] as? String, "gemini-api-key")
        XCTAssertEqual(general["previewFeatures"] as? Bool, false)
    }

    func testRestoreBackupRemovesFilesCreatedByApplyWhenOriginalFilesWereMissing() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let authURL = context.homeDirectory.appendingPathComponent(".codex/auth.json")
        let configURL = context.homeDirectory.appendingPathComponent(".codex/config.toml")

        let backup = try context.service.applyConfiguration(
            target: .codex,
            proxyAPIKey: Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-new"),
            endpoints: Self.endpoints
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertEqual(backup.files.map(\.existed), [false, false])

        _ = try context.service.restoreBackup(id: backup.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertEqual(context.service.listBackups(target: .codex).count, 2)
    }

    func testApplyConfigurationRollsBackWhenAWriteFailsMidway() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let authURL = context.homeDirectory.appendingPathComponent(".codex/auth.json")
        let configURL = context.homeDirectory.appendingPathComponent(".codex/config.toml")
        try Self.write(#"{"OPENAI_API_KEY":"sk-original"}"#, to: authURL)
        try Self.write(
            """
            model_provider = "legacy"

            [model_providers.custom]
            base_url = "http://legacy.example/v1"
            name = "legacy"
            requires_openai_auth = false
            wire_api = "chat_completions"
            """,
            to: configURL
        )

        var writeCount = 0
        let failingService = ClientConfigFileService(
            dataDirectory: context.dataDirectory,
            homeDirectoryURL: context.homeDirectory,
            writeFileHandler: { url, data, posixMode in
                writeCount += 1
                if writeCount == 2 {
                    throw ProxyError.message("Injected write failure")
                }
                try Helpers.writeFile(url, data: data, posixMode: posixMode)
            }
        )

        XCTAssertThrowsError(
            try failingService.applyConfiguration(
                target: .codex,
                proxyAPIKey: Self.proxyKey(id: "primary", label: "Primary", key: "sk-local-new"),
                endpoints: Self.endpoints
            )
        )

        let authObject = try Self.jsonObject(at: authURL)
        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, "sk-original")

        let configText = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(configText.contains(#"model_provider = "legacy""#))
        XCTAssertTrue(configText.contains(#"base_url = "http://legacy.example/v1""#))
    }

    func testPreviewCurrentConfigurationReadsManagedTextFiles() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        try Self.write(#"{"OPENAI_API_KEY":"sk-current"}"#, to: context.homeDirectory.appendingPathComponent(".codex/auth.json"))
        try Self.write(
            """
            model_provider = "custom"

            [model_providers.custom]
            base_url = "http://current.example/v1"
            """,
            to: context.homeDirectory.appendingPathComponent(".codex/config.toml")
        )

        let preview = context.service.previewCurrentConfiguration(target: .codex)

        XCTAssertEqual(preview.target, .codex)
        XCTAssertEqual(preview.files.map(\.exists), [true, true])
        XCTAssertEqual(preview.files.map(\.language), [.json, .toml])
        XCTAssertTrue(preview.files[0].content.contains("sk-current"))
        XCTAssertTrue(preview.files[1].content.contains("http://current.example/v1"))
        XCTAssertNil(preview.files[0].errorMessage)
    }

    func testPreviewProposedConfigurationDoesNotWriteFilesOrCreateBackup() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let authURL = context.homeDirectory.appendingPathComponent(".codex/auth.json")
        let configURL = context.homeDirectory.appendingPathComponent(".codex/config.toml")

        let preview = try context.service.previewProposedConfiguration(
            target: .codex,
            proxyAPIKey: Self.proxyKey(id: "primary", label: "Primary", key: "sk-preview"),
            endpoints: Self.endpoints
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertTrue(context.service.listBackups(target: .codex).isEmpty)
        XCTAssertTrue(preview.files[0].content.contains("sk-preview"))
        XCTAssertTrue(preview.files[1].content.contains(#"base_url = "http://127.0.0.1:8787/v1""#))
    }

    func testApplyCodexProjectRouteConfigurationWritesProjectModelAndModelCatalog() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectURL = context.homeDirectory.appendingPathComponent("Projects/HeavyWork", isDirectory: true)
        let configURL = projectURL.appendingPathComponent(".codex/config.toml")
        let catalogURL = projectURL.appendingPathComponent(".codex/codex-proxy-model-catalog.json")
        try Self.write(
            """
            model = "old-model"
            approval_policy = "never"

            [tools]
            web_search = true
            """,
            to: configURL
        )
        let rule = CodexProjectRouteRule(
            label: "Heavy",
            projectPath: projectURL.path,
            routeModel: "cp-route-heavy",
            targetModel: "deepseek-reasoner",
            proxyAPIKeyID: "heavy-key"
        )

        let proposed = context.service.previewProposedCodexProjectRoute(rule)
        XCTAssertEqual(proposed.files.map(\.path), [configURL.path, catalogURL.path])
        XCTAssertTrue(proposed.files[0].content.contains(#"model = "cp-route-heavy""#))
        XCTAssertTrue(proposed.files[0].content.contains(#"model_catalog_json = "\#(catalogURL.path)""#))
        XCTAssertTrue(proposed.files[1].content.contains(#""slug" : "cp-route-heavy""#))
        XCTAssertTrue(proposed.files[1].content.contains(#""context_window" : 128000"#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.dataDirectory.appendingPathComponent("client-config-backups").path))

        let backup = try context.service.applyCodexProjectRouteConfiguration(rule)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        let catalogObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let models = try XCTUnwrap(catalogObject["models"] as? [[String: Any]])
        let model = try XCTUnwrap(models.first)
        let reasoningLevels = try XCTUnwrap(model["supported_reasoning_levels"] as? [[String: Any]])

        XCTAssertEqual(backup.files.map(\.path), [configURL.path, catalogURL.path])
        XCTAssertTrue(text.contains(#"model = "cp-route-heavy""#))
        XCTAssertTrue(text.contains(#"model_catalog_json = "\#(catalogURL.path)""#))
        XCTAssertTrue(text.contains(#"approval_policy = "never""#))
        XCTAssertTrue(text.contains("[tools]"))
        XCTAssertEqual(model["slug"] as? String, "cp-route-heavy")
        XCTAssertEqual(model["display_name"] as? String, "Heavy")
        XCTAssertEqual(model["default_reasoning_level"] as? String, "medium")
        XCTAssertEqual(model["context_window"] as? Int, 128_000)
        XCTAssertEqual(model["max_context_window"] as? Int, 128_000)
        XCTAssertEqual(model["shell_type"] as? String, "shell_command")
        XCTAssertEqual(model["visibility"] as? String, "list")
        XCTAssertEqual(model["priority"] as? Int, 0)
        XCTAssertEqual(reasoningLevels.compactMap { $0["effort"] as? String }, ["low", "medium", "high"])
    }

    func testClearCodexProjectRouteConfigurationRemovesManagedModelCatalogOnly() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectURL = context.homeDirectory.appendingPathComponent("Projects/HeavyWork", isDirectory: true)
        let configURL = projectURL.appendingPathComponent(".codex/config.toml")
        let catalogURL = projectURL.appendingPathComponent(".codex/codex-proxy-model-catalog.json")
        try Self.write(
            """
            model = "cp-route-heavy"
            model_catalog_json = "\(catalogURL.path)"
            approval_policy = "never"

            [tools]
            model = "tool-model"
            web_search = true
            """,
            to: configURL
        )
        try Self.write(
            """
            {
              "models": [
                { "slug": "cp-route-heavy" }
              ]
            }
            """,
            to: catalogURL
        )
        let rule = CodexProjectRouteRule(
            label: "Heavy",
            projectPath: projectURL.path,
            routeModel: "cp-route-heavy",
            targetModel: "deepseek-reasoner",
            proxyAPIKeyID: "heavy-key"
        )

        let backup = try context.service.clearCodexProjectRouteConfiguration(rule)
        let text = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertEqual(backup.files.map(\.path), [configURL.path, catalogURL.path])
        XCTAssertFalse(text.contains(#"model = "cp-route-heavy""#))
        XCTAssertFalse(text.contains("model_catalog_json"))
        XCTAssertTrue(text.contains(#"approval_policy = "never""#))
        XCTAssertTrue(text.contains("[tools]"))
        XCTAssertTrue(text.contains(#"model = "tool-model""#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    func testClearCodexProjectRouteConfigurationKeepsCustomModelCatalogReference() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectURL = context.homeDirectory.appendingPathComponent("Projects/CustomCatalogWork", isDirectory: true)
        let configURL = projectURL.appendingPathComponent(".codex/config.toml")
        let managedCatalogURL = projectURL.appendingPathComponent(".codex/codex-proxy-model-catalog.json")
        let customCatalogURL = projectURL.appendingPathComponent(".codex/custom-model-catalog.json")
        try Self.write(
            """
            model = "cp-route-heavy"
            model_catalog_json = "\(customCatalogURL.path)"
            approval_policy = "never"
            """,
            to: configURL
        )
        try Self.write(#"{"models":[{"slug":"custom"}]}"#, to: customCatalogURL)
        let rule = CodexProjectRouteRule(
            label: "Heavy",
            projectPath: projectURL.path,
            routeModel: "cp-route-heavy",
            targetModel: "deepseek-reasoner",
            proxyAPIKeyID: "heavy-key"
        )

        let backup = try context.service.clearCodexProjectRouteConfiguration(rule)
        let text = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertEqual(backup.files.map(\.path), [configURL.path, managedCatalogURL.path])
        XCTAssertFalse(text.contains(#"model = "cp-route-heavy""#))
        XCTAssertTrue(text.contains(#"model_catalog_json = "\#(customCatalogURL.path)""#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: customCatalogURL.path))
    }

    func testClearCodexProjectRouteConfigurationCreatesEmptyConfigWhenMissing() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectURL = context.homeDirectory.appendingPathComponent("Projects/EmptyWork", isDirectory: true)
        let configURL = projectURL.appendingPathComponent(".codex/config.toml")
        let catalogURL = projectURL.appendingPathComponent(".codex/codex-proxy-model-catalog.json")
        let rule = CodexProjectRouteRule(
            label: "Empty",
            projectPath: projectURL.path,
            routeModel: "cp-route-empty",
            targetModel: "gpt-5",
            proxyAPIKeyID: "empty-key"
        )

        let backup = try context.service.clearCodexProjectRouteConfiguration(rule)
        let text = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertEqual(backup.files.map(\.path), [configURL.path, catalogURL.path])
        XCTAssertEqual(text, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testApplyClaudeProjectRouteConfigurationWritesSelectedSettingsScope() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectURL = context.homeDirectory.appendingPathComponent("Projects/ClaudeWork", isDirectory: true)
        let settingsURL = projectURL.appendingPathComponent(".claude/settings.local.json")
        try Self.write(
            """
            {
              "model": "old-model",
              "env": { "FOO": "bar" },
              "permissions": { "allow": ["Bash(ls)"] }
            }
            """,
            to: settingsURL
        )
        let rule = CodexProjectRouteRule(
            client: .claudeCode,
            claudeSettingsScope: .local,
            label: "Claude Local",
            projectPath: projectURL.path,
            routeModel: "cp-route-claude",
            targetModel: "claude-sonnet-4-5",
            proxyAPIKeyID: "claude-key"
        )

        let proposed = context.service.previewProposedProjectRoute(rule)
        XCTAssertTrue(proposed.files.first?.content.contains("cp-route-claude") == true)
        XCTAssertTrue(proposed.files.first?.content.contains("ANTHROPIC_CUSTOM_MODEL_OPTION") == true)
        XCTAssertTrue(proposed.files.first?.content.contains("ANTHROPIC_CUSTOM_MODEL_OPTION_NAME") == true)
        XCTAssertTrue(proposed.files.first?.content.contains("ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION") == true)

        let backup = try context.service.applyProjectRouteConfiguration(rule)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let env = try XCTUnwrap(object["env"] as? [String: Any])
        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])

        XCTAssertEqual(backup.files.map(\.path), [settingsURL.path])
        XCTAssertEqual(object["model"] as? String, "cp-route-claude")
        XCTAssertEqual(env["FOO"] as? String, "bar")
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_MODEL_OPTION"] as? String, "cp-route-claude")
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"] as? String, "项目路由：Claude Local")
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"] as? String, "由 Codex Proxy 项目路由转发到绑定账号")
        XCTAssertNotNil(permissions["allow"])
        XCTAssertFalse(proposed.files.first?.content.contains("ANTHROPIC_AUTH_TOKEN") == true)
    }

    func testClearClaudeProjectRouteConfigurationRemovesTopLevelModelAndManagedCustomModelEnvOnly() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        let projectURL = context.homeDirectory.appendingPathComponent("Projects/ClaudeShared", isDirectory: true)
        let settingsURL = projectURL.appendingPathComponent(".claude/settings.json")
        try Self.write(
            """
            {
              "model": "cp-route-claude",
              "env": {
                "FOO": "bar",
                "ANTHROPIC_CUSTOM_MODEL_OPTION": "cp-route-claude",
                "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "项目路由：Claude Shared",
                "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "由 Codex Proxy 项目路由转发到绑定账号"
              },
              "permissions": { "allow": ["Bash(ls)"] }
            }
            """,
            to: settingsURL
        )
        let rule = CodexProjectRouteRule(
            client: .claudeCode,
            claudeSettingsScope: .shared,
            label: "Claude Shared",
            projectPath: projectURL.path,
            routeModel: "cp-route-claude",
            targetModel: "claude-sonnet-4-5",
            proxyAPIKeyID: "claude-key"
        )

        let backup = try context.service.clearProjectRouteConfiguration(rule)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let env = try XCTUnwrap(object["env"] as? [String: Any])
        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])

        XCTAssertEqual(backup.files.map(\.path), [settingsURL.path])
        XCTAssertNil(object["model"])
        XCTAssertEqual(env["FOO"] as? String, "bar")
        XCTAssertNil(env["ANTHROPIC_CUSTOM_MODEL_OPTION"])
        XCTAssertNil(env["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"])
        XCTAssertNil(env["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"])
        XCTAssertNotNil(permissions["allow"])
    }

    func testLoadBackupDetailReadsExistingAndMissingFiles() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        try Self.write(
            """
            GEMINI_API_KEY=sk-old
            GOOGLE_GEMINI_BASE_URL=http://old.example
            """,
            to: context.homeDirectory.appendingPathComponent(".gemini/.env")
        )

        let backup = try context.service.applyConfiguration(
            target: .gemini,
            proxyAPIKey: Self.proxyKey(id: "primary", label: "Primary", key: "sk-backed-up"),
            endpoints: Self.endpoints
        )

        let detail = try context.service.loadBackupDetail(id: backup.id)

        XCTAssertEqual(detail.record.id, backup.id)
        XCTAssertEqual(detail.files.map(\.exists), [true, false])
        XCTAssertTrue(detail.files[0].content.contains("sk-old"))
        XCTAssertEqual(detail.files[1].content, "")
        XCTAssertNil(detail.files[0].errorMessage)
    }

    func testPreviewCurrentConfigurationReportsInvalidJSONPerFile() throws {
        let context = try Self.makeContext()
        defer { context.cleanup() }

        try Self.write("{not-json", to: context.homeDirectory.appendingPathComponent(".claude/settings.json"))

        let preview = context.service.previewCurrentConfiguration(target: .claudeCode)

        XCTAssertEqual(preview.files.count, 1)
        XCTAssertTrue(preview.files[0].exists)
        XCTAssertTrue(preview.files[0].content.contains("{not-json"))
        XCTAssertNotNil(preview.files[0].errorMessage)
    }
}

private extension ClientConfigFileServiceTests {
    struct TestContext {
        let homeDirectory: URL
        let dataDirectory: URL
        let service: ClientConfigFileService

        func cleanup() {
            try? FileManager.default.removeItem(at: self.homeDirectory)
            try? FileManager.default.removeItem(at: self.dataDirectory)
        }
    }

    static let endpoints = ClientConfigEndpointBundle(
        openAIBaseURL: "http://127.0.0.1:8787/v1",
        anthropicBaseURL: "http://127.0.0.1:8787",
        geminiBaseURL: "http://127.0.0.1:8787"
    )

    static func makeContext() throws -> TestContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        return TestContext(
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

    static func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
