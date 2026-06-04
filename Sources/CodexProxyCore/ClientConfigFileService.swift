import Foundation

public enum ClientConfigTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode = "claude_code"
    case gemini

    public var id: String { self.rawValue }
}

public enum ClientConfigBackupReason: String, Codable, Sendable, Equatable {
    case beforeApply = "before_apply"
    case beforeRestore = "before_restore"
}

private enum ClaudeProjectRouteManagedEnv {
    static let customModelOption = "ANTHROPIC_CUSTOM_MODEL_OPTION"
    static let customModelOptionName = "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"
    static let customModelOptionDescription = "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"

    static let keys: Set<String> = [
        Self.customModelOption,
        Self.customModelOptionName,
        Self.customModelOptionDescription,
    ]
}

public enum ClientConfigCurrentKeyKind: String, Codable, Sendable, Equatable {
    case missing
    case matched
    case external
}

public struct ClientConfigManagedFileState: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var exists: Bool

    public var id: String { self.path }

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

public struct ClientConfigInspection: Codable, Sendable, Equatable {
    public var target: ClientConfigTarget
    public var files: [ClientConfigManagedFileState]
    public var currentBaseURL: String?
    public var currentAPIKey: String?
    public var currentKeyKind: ClientConfigCurrentKeyKind
    public var matchedProxyAPIKeyID: String?
    public var matchedProxyAPIKeyLabel: String?
    public var errorMessage: String?

    public init(
        target: ClientConfigTarget,
        files: [ClientConfigManagedFileState],
        currentBaseURL: String? = nil,
        currentAPIKey: String? = nil,
        currentKeyKind: ClientConfigCurrentKeyKind = .missing,
        matchedProxyAPIKeyID: String? = nil,
        matchedProxyAPIKeyLabel: String? = nil,
        errorMessage: String? = nil
    ) {
        self.target = target
        self.files = files
        self.currentBaseURL = currentBaseURL
        self.currentAPIKey = currentAPIKey
        self.currentKeyKind = currentKeyKind
        self.matchedProxyAPIKeyID = matchedProxyAPIKeyID
        self.matchedProxyAPIKeyLabel = matchedProxyAPIKeyLabel
        self.errorMessage = errorMessage
    }
}

public struct ClientConfigEndpointBundle: Codable, Sendable, Equatable {
    public var openAIBaseURL: String
    public var anthropicBaseURL: String
    public var geminiBaseURL: String

    public init(
        openAIBaseURL: String,
        anthropicBaseURL: String,
        geminiBaseURL: String
    ) {
        self.openAIBaseURL = openAIBaseURL
        self.anthropicBaseURL = anthropicBaseURL
        self.geminiBaseURL = geminiBaseURL
    }
}

public struct ClientConfigBackupRecord: Codable, Sendable, Equatable, Identifiable {
    public struct FileEntry: Codable, Sendable, Equatable, Identifiable {
        public var path: String
        public var existed: Bool
        public var posixPermissions: Int?
        public var modifiedAtUnix: Int64?
        public var storedFileName: String?

        public var id: String { self.path }

        public init(
            path: String,
            existed: Bool,
            posixPermissions: Int?,
            modifiedAtUnix: Int64?,
            storedFileName: String?
        ) {
            self.path = path
            self.existed = existed
            self.posixPermissions = posixPermissions
            self.modifiedAtUnix = modifiedAtUnix
            self.storedFileName = storedFileName
        }
    }

    public var id: String
    public var target: ClientConfigTarget
    public var reason: ClientConfigBackupReason
    public var createdAt: Int64
    public var proxyAPIKeyID: String?
    public var proxyAPIKeyLabel: String?
    public var files: [FileEntry]

    public init(
        id: String,
        target: ClientConfigTarget,
        reason: ClientConfigBackupReason,
        createdAt: Int64,
        proxyAPIKeyID: String?,
        proxyAPIKeyLabel: String?,
        files: [FileEntry]
    ) {
        self.id = id
        self.target = target
        self.reason = reason
        self.createdAt = createdAt
        self.proxyAPIKeyID = proxyAPIKeyID
        self.proxyAPIKeyLabel = proxyAPIKeyLabel
        self.files = files
    }
}

public enum ClientConfigTextLanguage: String, Codable, Sendable, Equatable {
    case json
    case toml
    case dotenv
    case text
}

public struct ClientConfigFileTextSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var exists: Bool
    public var content: String
    public var language: ClientConfigTextLanguage
    public var errorMessage: String?

    public var id: String { self.path }

    public init(
        path: String,
        exists: Bool,
        content: String,
        language: ClientConfigTextLanguage,
        errorMessage: String? = nil
    ) {
        self.path = path
        self.exists = exists
        self.content = content
        self.language = language
        self.errorMessage = errorMessage
    }
}

public struct ClientConfigPreview: Codable, Sendable, Equatable {
    public var target: ClientConfigTarget
    public var files: [ClientConfigFileTextSnapshot]

    public init(target: ClientConfigTarget, files: [ClientConfigFileTextSnapshot]) {
        self.target = target
        self.files = files
    }
}

public struct ClientConfigBackupDetail: Codable, Sendable, Equatable, Identifiable {
    public var record: ClientConfigBackupRecord
    public var files: [ClientConfigFileTextSnapshot]

    public var id: String { self.record.id }

    public init(record: ClientConfigBackupRecord, files: [ClientConfigFileTextSnapshot]) {
        self.record = record
        self.files = files
    }
}

public final class ClientConfigFileService: @unchecked Sendable {
    private static let codexProjectRouteModelCatalogFileName = "codex-proxy-model-catalog.json"

    private struct CapturedManagedFile {
        var url: URL
        var existed: Bool
        var data: Data?
        var posixPermissions: Int?
        var modifiedAt: Date?
    }

    private struct DesiredConfiguration {
        var apiKey: String
        var baseURL: String
    }

    private struct ResolvedConfiguration {
        var currentAPIKey: String?
        var currentBaseURL: String?
    }

    private let dataDirectory: URL
    private let homeDirectoryURL: URL
    private let writeFileHandler: ((URL, Data, Int16) throws -> Void)?

    public init(
        dataDirectory: URL = Paths.defaultDataDirectory(),
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        writeFileHandler: ((URL, Data, Int16) throws -> Void)? = nil
    ) {
        self.dataDirectory = dataDirectory
        self.homeDirectoryURL = homeDirectoryURL
        self.writeFileHandler = writeFileHandler
    }

    public func backupDirectoryURL() -> URL {
        Paths.clientConfigBackupsDirectoryURL(in: self.dataDirectory)
    }

    public func managedFileURLs(for target: ClientConfigTarget) -> [URL] {
        switch target {
        case .codex:
            return [
                self.homeDirectoryURL.appendingPathComponent(".codex/auth.json"),
                self.homeDirectoryURL.appendingPathComponent(".codex/config.toml"),
            ]
        case .claudeCode:
            return [
                self.homeDirectoryURL.appendingPathComponent(".claude/settings.json"),
            ]
        case .gemini:
            return [
                self.homeDirectoryURL.appendingPathComponent(".gemini/.env"),
                self.homeDirectoryURL.appendingPathComponent(".gemini/settings.json"),
            ]
        }
    }

    public func codexProjectConfigURL(projectPath: String) -> URL {
        let normalizedPath = CodexProjectRouteRule.normalizedProjectPath(projectPath)
        return URL(fileURLWithPath: normalizedPath, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    public func claudeProjectConfigURL(projectPath: String, scope: ClaudeProjectSettingsScope) -> URL {
        let normalizedPath = CodexProjectRouteRule.normalizedProjectPath(projectPath)
        let filename = scope == .local ? "settings.local.json" : "settings.json"
        return URL(fileURLWithPath: normalizedPath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(filename)
    }

    public func inspectAll(
        availableProxyAPIKeys: [ProxyAPIKeyRecord]
    ) -> [ClientConfigTarget: ClientConfigInspection] {
        var inspections: [ClientConfigTarget: ClientConfigInspection] = [:]
        for target in ClientConfigTarget.allCases {
            inspections[target] = self.inspect(target: target, availableProxyAPIKeys: availableProxyAPIKeys)
        }
        return inspections
    }

    public func listBackups(target: ClientConfigTarget? = nil) -> [ClientConfigBackupRecord] {
        let root = self.backupDirectoryURL()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { directoryURL in
            let metadataURL = directoryURL.appendingPathComponent("metadata.json")
            guard
                let data = try? Data(contentsOf: metadataURL),
                let record = try? Helpers.readJSON(ClientConfigBackupRecord.self, from: data)
            else {
                return nil
            }
            guard target == nil || record.target == target else { return nil }
            return record
        }
        .sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id > $1.id
        }
    }

    public func previewCurrentConfiguration(target: ClientConfigTarget) -> ClientConfigPreview {
        ClientConfigPreview(
            target: target,
            files: self.managedFileURLs(for: target).map { self.currentTextSnapshot(url: $0) }
        )
    }

    public func previewProposedConfiguration(
        target: ClientConfigTarget,
        proxyAPIKey: ProxyAPIKeyRecord,
        endpoints: ClientConfigEndpointBundle
    ) throws -> ClientConfigPreview {
        let desired = try self.desiredConfiguration(proxyAPIKey: proxyAPIKey, target: target, endpoints: endpoints)
        let files: [ClientConfigFileTextSnapshot]
        switch target {
        case .codex:
            let urls = self.managedFileURLs(for: .codex)
            files = [
                self.proposedTextSnapshot(url: urls[0]) {
                    try self.updatedCodexAuthData(url: urls[0], apiKey: desired.apiKey)
                },
                self.proposedTextSnapshot(url: urls[1]) {
                    try self.updatedCodexConfigData(url: urls[1], baseURL: desired.baseURL)
                },
            ]
        case .claudeCode:
            let settingsURL = self.managedFileURLs(for: .claudeCode)[0]
            files = [
                self.proposedTextSnapshot(url: settingsURL) {
                    try self.updatedClaudeSettingsData(
                        url: settingsURL,
                        apiKey: desired.apiKey,
                        baseURL: desired.baseURL
                    )
                },
            ]
        case .gemini:
            let urls = self.managedFileURLs(for: .gemini)
            files = [
                self.proposedTextSnapshot(url: urls[0]) {
                    self.updatedGeminiEnvData(
                        url: urls[0],
                        apiKey: desired.apiKey,
                        baseURL: desired.baseURL
                    )
                },
                self.proposedTextSnapshot(url: urls[1]) {
                    try self.updatedGeminiSettingsData(url: urls[1])
                },
            ]
        }
        return ClientConfigPreview(target: target, files: files)
    }

    public func previewCurrentCodexProjectRoute(_ rule: CodexProjectRouteRule) -> ClientConfigPreview {
        self.previewCurrentProjectRoute(rule)
    }

    public func previewProposedCodexProjectRoute(_ rule: CodexProjectRouteRule) -> ClientConfigPreview {
        self.previewProposedProjectRoute(rule)
    }

    public func previewCurrentProjectRoute(_ rule: CodexProjectRouteRule) -> ClientConfigPreview {
        ClientConfigPreview(
            target: rule.client == .codex ? .codex : .claudeCode,
            files: self.projectRouteConfigURLs(rule).map { self.currentTextSnapshot(url: $0) }
        )
    }

    public func previewProposedProjectRoute(_ rule: CodexProjectRouteRule) -> ClientConfigPreview {
        return ClientConfigPreview(
            target: rule.client == .codex ? .codex : .claudeCode,
            files: self.projectRouteProposedTextSnapshots(rule)
        )
    }

    public func loadBackupDetail(id: String) throws -> ClientConfigBackupDetail {
        let record = try self.loadBackup(id: id)
        let backupDirectory = self.backupDirectoryURL().appendingPathComponent(record.id, isDirectory: true)
        let filesDirectory = backupDirectory.appendingPathComponent("files", isDirectory: true)
        let files = record.files.map { entry in
            self.backupTextSnapshot(entry: entry, filesDirectory: filesDirectory)
        }
        return ClientConfigBackupDetail(record: record, files: files)
    }

    @discardableResult
    public func applyConfiguration(
        target: ClientConfigTarget,
        proxyAPIKey: ProxyAPIKeyRecord,
        endpoints: ClientConfigEndpointBundle
    ) throws -> ClientConfigBackupRecord {
        let desired = try self.desiredConfiguration(proxyAPIKey: proxyAPIKey, target: target, endpoints: endpoints)

        let backup = try self.createBackup(
            target: target,
            reason: .beforeApply,
            proxyAPIKey: proxyAPIKey
        )

        do {
            try self.writeConfiguration(target: target, desired: desired)
            return backup
        } catch let applyError {
            do {
                try self.restoreBackupRecord(backup)
            } catch let rollbackError {
                throw ProxyError.message(
                    "\(applyError.localizedDescription)|Rollback failed: \(rollbackError.localizedDescription)"
                )
            }
            throw applyError
        }
    }

    @discardableResult
    public func applyCodexProjectRouteConfiguration(_ rule: CodexProjectRouteRule) throws -> ClientConfigBackupRecord {
        try self.applyProjectRouteConfiguration(rule)
    }

    @discardableResult
    public func clearCodexProjectRouteConfiguration(_ rule: CodexProjectRouteRule) throws -> ClientConfigBackupRecord {
        try self.clearProjectRouteConfiguration(rule)
    }

    @discardableResult
    public func applyProjectRouteConfiguration(_ rule: CodexProjectRouteRule) throws -> ClientConfigBackupRecord {
        let normalizedRule = try self.normalizedProjectRouteRule(rule)
        let urls = self.projectRouteConfigURLs(normalizedRule)
        let backup = try self.createBackup(
            target: normalizedRule.client == .codex ? .codex : .claudeCode,
            reason: .beforeApply,
            proxyAPIKey: nil,
            urls: urls
        )

        do {
            try self.writeProjectRouteConfiguration(rule: normalizedRule)
            return backup
        } catch let applyError {
            do {
                try self.restoreBackupRecord(backup)
            } catch let rollbackError {
                throw ProxyError.message(
                    "\(applyError.localizedDescription)|Rollback failed: \(rollbackError.localizedDescription)"
                )
            }
            throw applyError
        }
    }

    @discardableResult
    public func clearProjectRouteConfiguration(_ rule: CodexProjectRouteRule) throws -> ClientConfigBackupRecord {
        let normalizedRule = try self.normalizedProjectRouteRule(rule)
        let urls = self.projectRouteConfigURLs(normalizedRule)
        let backup = try self.createBackup(
            target: normalizedRule.client == .codex ? .codex : .claudeCode,
            reason: .beforeApply,
            proxyAPIKey: nil,
            urls: urls
        )

        do {
            try self.clearProjectRouteConfigurationFiles(rule: normalizedRule)
            return backup
        } catch let applyError {
            do {
                try self.restoreBackupRecord(backup)
            } catch let rollbackError {
                throw ProxyError.message(
                    "\(applyError.localizedDescription)|Rollback failed: \(rollbackError.localizedDescription)"
                )
            }
            throw applyError
        }
    }

    @discardableResult
    public func restoreBackup(id: String) throws -> ClientConfigBackupRecord {
        let backup = try self.loadBackup(id: id)
        let rollbackBackup = try self.createBackup(
            target: backup.target,
            reason: .beforeRestore,
            proxyAPIKey: nil
        )

        do {
            try self.restoreBackupRecord(backup)
            return rollbackBackup
        } catch let restoreError {
            do {
                try self.restoreBackupRecord(rollbackBackup)
            } catch let rollbackError {
                throw ProxyError.message(
                    "\(restoreError.localizedDescription)|Restore rollback failed: \(rollbackError.localizedDescription)"
                )
            }
            throw restoreError
        }
    }

    public func inspect(
        target: ClientConfigTarget,
        availableProxyAPIKeys: [ProxyAPIKeyRecord]
    ) -> ClientConfigInspection {
        let fileStates = self.managedFileURLs(for: target).map {
            ClientConfigManagedFileState(path: $0.path, exists: FileManager.default.fileExists(atPath: $0.path))
        }

        do {
            let resolved = try self.readCurrentConfiguration(target: target)
            let trimmedKey = resolved.currentAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let matched = availableProxyAPIKeys.first {
                $0.key.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedKey && trimmedKey.isEmpty == false
            }
            let keyKind: ClientConfigCurrentKeyKind
            if trimmedKey.isEmpty {
                keyKind = .missing
            } else if matched != nil {
                keyKind = .matched
            } else {
                keyKind = .external
            }

            return ClientConfigInspection(
                target: target,
                files: fileStates,
                currentBaseURL: Self.cleanedString(resolved.currentBaseURL),
                currentAPIKey: Self.cleanedString(resolved.currentAPIKey),
                currentKeyKind: keyKind,
                matchedProxyAPIKeyID: matched?.id,
                matchedProxyAPIKeyLabel: matched?.label.trimmingCharacters(in: .whitespacesAndNewlines),
                errorMessage: nil
            )
        } catch {
            return ClientConfigInspection(
                target: target,
                files: fileStates,
                currentBaseURL: nil,
                currentAPIKey: nil,
                currentKeyKind: .missing,
                matchedProxyAPIKeyID: nil,
                matchedProxyAPIKeyLabel: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func createBackup(
        target: ClientConfigTarget,
        reason: ClientConfigBackupReason,
        proxyAPIKey: ProxyAPIKeyRecord?
    ) throws -> ClientConfigBackupRecord {
        try self.createBackup(
            target: target,
            reason: reason,
            proxyAPIKey: proxyAPIKey,
            urls: self.managedFileURLs(for: target)
        )
    }

    private func createBackup(
        target: ClientConfigTarget,
        reason: ClientConfigBackupReason,
        proxyAPIKey: ProxyAPIKeyRecord?,
        urls: [URL]
    ) throws -> ClientConfigBackupRecord {
        let root = self.backupDirectoryURL()
        try Helpers.ensureDirectory(root)

        let timestamp = Helpers.now()
        let directoryName = "\(timestamp)-\(UUID().uuidString)"
        let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
        let filesDirectoryURL = directoryURL.appendingPathComponent("files", isDirectory: true)

        try Helpers.ensureDirectory(directoryURL)
        try Helpers.ensureDirectory(filesDirectoryURL)

        let captured = try self.captureManagedFiles(urls: urls)
        var entries: [ClientConfigBackupRecord.FileEntry] = []

        for (index, file) in captured.enumerated() {
            let storedFileName: String?
            if file.existed, let data = file.data {
                let name = String(format: "file-%02d.bin", index)
                try Helpers.writeFile(filesDirectoryURL.appendingPathComponent(name), data: data)
                storedFileName = name
            } else {
                storedFileName = nil
            }

            entries.append(
                ClientConfigBackupRecord.FileEntry(
                    path: file.url.path,
                    existed: file.existed,
                    posixPermissions: file.posixPermissions,
                    modifiedAtUnix: file.modifiedAt.map { Int64($0.timeIntervalSince1970) },
                    storedFileName: storedFileName
                )
            )
        }

        let record = ClientConfigBackupRecord(
            id: directoryName,
            target: target,
            reason: reason,
            createdAt: timestamp,
            proxyAPIKeyID: proxyAPIKey?.id,
            proxyAPIKeyLabel: Self.cleanedString(proxyAPIKey?.label),
            files: entries
        )
        let metadataData = try Helpers.encodeJSON(record, pretty: true)
        try Helpers.writeFile(directoryURL.appendingPathComponent("metadata.json"), data: metadataData)
        return record
    }

    private func loadBackup(id: String) throws -> ClientConfigBackupRecord {
        let metadataURL = self.backupDirectoryURL()
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ProxyError.message("Backup `\(id)` was not found.")
        }
        let data = try Data(contentsOf: metadataURL)
        return try Helpers.readJSON(ClientConfigBackupRecord.self, from: data)
    }

    private func currentTextSnapshot(url: URL) -> ClientConfigFileTextSnapshot {
        let language = self.textLanguage(for: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ClientConfigFileTextSnapshot(
                path: url.path,
                exists: false,
                content: "",
                language: language
            )
        }

        do {
            let data = try Data(contentsOf: url)
            let content = try self.textContent(from: data, fileName: url.lastPathComponent)
            try self.validateTextSnapshotContent(content, language: language, fileName: url.lastPathComponent)
            return ClientConfigFileTextSnapshot(
                path: url.path,
                exists: true,
                content: content,
                language: language
            )
        } catch {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return ClientConfigFileTextSnapshot(
                path: url.path,
                exists: true,
                content: content,
                language: language,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func proposedTextSnapshot(
        url: URL,
        dataProvider: () throws -> Data
    ) -> ClientConfigFileTextSnapshot {
        let language = self.textLanguage(for: url)
        do {
            let data = try dataProvider()
            let content = try self.textContent(from: data, fileName: url.lastPathComponent)
            try self.validateTextSnapshotContent(content, language: language, fileName: url.lastPathComponent)
            return ClientConfigFileTextSnapshot(
                path: url.path,
                exists: true,
                content: content,
                language: language
            )
        } catch {
            return ClientConfigFileTextSnapshot(
                path: url.path,
                exists: FileManager.default.fileExists(atPath: url.path),
                content: "",
                language: language,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func backupTextSnapshot(
        entry: ClientConfigBackupRecord.FileEntry,
        filesDirectory: URL
    ) -> ClientConfigFileTextSnapshot {
        let url = URL(fileURLWithPath: entry.path)
        let language = self.textLanguage(for: url)
        guard entry.existed else {
            return ClientConfigFileTextSnapshot(
                path: entry.path,
                exists: false,
                content: "",
                language: language
            )
        }
        guard let storedFileName = entry.storedFileName else {
            return ClientConfigFileTextSnapshot(
                path: entry.path,
                exists: true,
                content: "",
                language: language,
                errorMessage: "Backup is missing file data for \(entry.path)."
            )
        }

        do {
            let data = try Data(contentsOf: filesDirectory.appendingPathComponent(storedFileName))
            let content = try self.textContent(from: data, fileName: url.lastPathComponent)
            try self.validateTextSnapshotContent(content, language: language, fileName: url.lastPathComponent)
            return ClientConfigFileTextSnapshot(
                path: entry.path,
                exists: true,
                content: content,
                language: language
            )
        } catch {
            return ClientConfigFileTextSnapshot(
                path: entry.path,
                exists: true,
                content: "",
                language: language,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func captureManagedFiles(for target: ClientConfigTarget) throws -> [CapturedManagedFile] {
        try self.captureManagedFiles(urls: self.managedFileURLs(for: target))
    }

    private func captureManagedFiles(urls: [URL]) throws -> [CapturedManagedFile] {
        try urls.map { url in
            let exists = FileManager.default.fileExists(atPath: url.path)
            let attributes = exists ? (try? FileManager.default.attributesOfItem(atPath: url.path)) : nil
            let data = exists ? try Data(contentsOf: url) : nil
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
            let modifiedAt = attributes?[.modificationDate] as? Date

            return CapturedManagedFile(
                url: url,
                existed: exists,
                data: data,
                posixPermissions: permissions,
                modifiedAt: modifiedAt
            )
        }
    }

    private func restoreBackupRecord(_ record: ClientConfigBackupRecord) throws {
        let backupDirectory = self.backupDirectoryURL().appendingPathComponent(record.id, isDirectory: true)
        let filesDirectory = backupDirectory.appendingPathComponent("files", isDirectory: true)

        for entry in record.files {
            let fileURL = URL(fileURLWithPath: entry.path)
            if entry.existed == false {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                continue
            }

            guard let storedFileName = entry.storedFileName else {
                throw ProxyError.message("Backup `\(record.id)` is missing file data for \(entry.path).")
            }

            let data = try Data(contentsOf: filesDirectory.appendingPathComponent(storedFileName))
            try self.writeFile(fileURL, data: data, posixMode: Int16(entry.posixPermissions ?? 0o600))

            var attributes: [FileAttributeKey: Any] = [:]
            if let permissions = entry.posixPermissions {
                attributes[.posixPermissions] = NSNumber(value: permissions)
            }
            if let modifiedAtUnix = entry.modifiedAtUnix {
                attributes[.modificationDate] = Date(timeIntervalSince1970: TimeInterval(modifiedAtUnix))
            }
            if attributes.isEmpty == false {
                try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
            }
        }
    }

    private func writeConfiguration(
        target: ClientConfigTarget,
        desired: DesiredConfiguration
    ) throws {
        switch target {
        case .codex:
            try self.writeCodexConfiguration(desired: desired)
        case .claudeCode:
            try self.writeClaudeConfiguration(desired: desired)
        case .gemini:
            try self.writeGeminiConfiguration(desired: desired)
        }
    }

    private func writeCodexConfiguration(desired: DesiredConfiguration) throws {
        let urls = self.managedFileURLs(for: .codex)
        let authURL = urls[0]
        let configURL = urls[1]

        let authData = try self.updatedCodexAuthData(url: authURL, apiKey: desired.apiKey)
        let configData = try self.updatedCodexConfigData(url: configURL, baseURL: desired.baseURL)

        try self.writeFile(authURL, data: authData, posixMode: 0o600)
        try self.writeFile(configURL, data: configData, posixMode: 0o600)
    }

    private func writeClaudeConfiguration(desired: DesiredConfiguration) throws {
        let settingsURL = self.managedFileURLs(for: .claudeCode)[0]
        let settingsData = try self.updatedClaudeSettingsData(
            url: settingsURL,
            apiKey: desired.apiKey,
            baseURL: desired.baseURL
        )
        try self.writeFile(settingsURL, data: settingsData, posixMode: 0o600)
    }

    private func writeGeminiConfiguration(desired: DesiredConfiguration) throws {
        let urls = self.managedFileURLs(for: .gemini)
        let envURL = urls[0]
        let settingsURL = urls[1]

        let envData = self.updatedGeminiEnvData(
            url: envURL,
            apiKey: desired.apiKey,
            baseURL: desired.baseURL
        )
        let settingsData = try self.updatedGeminiSettingsData(url: settingsURL)

        try self.writeFile(envURL, data: envData, posixMode: 0o600)
        try self.writeFile(settingsURL, data: settingsData, posixMode: 0o600)
    }

    private func normalizedProjectRouteRule(_ rule: CodexProjectRouteRule) throws -> CodexProjectRouteRule {
        let normalizedRule = CodexProjectRouteRule(
            id: rule.id,
            client: rule.client,
            claudeSettingsScope: rule.claudeSettingsScope,
            label: rule.label,
            projectPath: rule.projectPath,
            routeModel: rule.routeModel,
            targetModel: rule.targetModel,
            proxyAPIKeyID: rule.proxyAPIKeyID,
            enabled: rule.enabled,
            createdAt: rule.createdAt
        )
        guard normalizedRule.projectPath.isEmpty == false else {
            throw ProxyError.message("项目目录不能为空")
        }
        guard normalizedRule.routeModel.isEmpty == false else {
            throw ProxyError.message("项目路由模型不能为空")
        }
        return normalizedRule
    }

    private func projectRouteConfigURL(_ rule: CodexProjectRouteRule) -> URL {
        switch rule.client {
        case .codex:
            return self.codexProjectConfigURL(projectPath: rule.projectPath)
        case .claudeCode:
            return self.claudeProjectConfigURL(projectPath: rule.projectPath, scope: rule.claudeSettingsScope)
        }
    }

    private func projectRouteConfigURLs(_ rule: CodexProjectRouteRule) -> [URL] {
        let configURL = self.projectRouteConfigURL(rule)
        switch rule.client {
        case .codex:
            return [configURL, self.codexProjectRouteModelCatalogURL(configURL: configURL)]
        case .claudeCode:
            return [configURL]
        }
    }

    private func codexProjectRouteModelCatalogURL(configURL: URL) -> URL {
        configURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.codexProjectRouteModelCatalogFileName)
    }

    private func projectRouteProposedTextSnapshots(_ rule: CodexProjectRouteRule) -> [ClientConfigFileTextSnapshot] {
        let configURL = self.projectRouteConfigURL(rule)
        switch rule.client {
        case .codex:
            let catalogURL = self.codexProjectRouteModelCatalogURL(configURL: configURL)
            return [
                self.proposedTextSnapshot(url: configURL) {
                    try self.updatedCodexProjectConfigData(url: configURL, rule: rule)
                },
                self.proposedTextSnapshot(url: catalogURL) {
                    try self.codexProjectRouteModelCatalogData(rule: rule)
                },
            ]
        case .claudeCode:
            return [
                self.proposedTextSnapshot(url: configURL) {
                    try self.updatedClaudeProjectSettingsData(url: configURL, rule: rule)
                },
            ]
        }
    }

    private func writeProjectRouteConfiguration(rule: CodexProjectRouteRule) throws {
        let configURL = self.projectRouteConfigURL(rule)
        switch rule.client {
        case .codex:
            let catalogURL = self.codexProjectRouteModelCatalogURL(configURL: configURL)
            let configData = try self.updatedCodexProjectConfigData(url: configURL, rule: rule)
            let catalogData = try self.codexProjectRouteModelCatalogData(rule: rule)
            try self.writeFile(configURL, data: configData, posixMode: 0o600)
            try self.writeFile(catalogURL, data: catalogData, posixMode: 0o600)
        case .claudeCode:
            let data = try self.updatedClaudeProjectSettingsData(url: configURL, rule: rule)
            try self.writeFile(configURL, data: data, posixMode: 0o600)
        }
    }

    private func clearProjectRouteConfigurationFiles(rule: CodexProjectRouteRule) throws {
        let configURL = self.projectRouteConfigURL(rule)
        switch rule.client {
        case .codex:
            let catalogURL = self.codexProjectRouteModelCatalogURL(configURL: configURL)
            let data = self.clearedCodexProjectConfigData(url: configURL, catalogURL: catalogURL)
            try self.writeFile(configURL, data: data, posixMode: 0o600)
            try self.removeCodexProjectRouteModelCatalogIfManaged(url: catalogURL, rule: rule)
        case .claudeCode:
            let data = try self.clearedClaudeProjectSettingsData(url: configURL)
            try self.writeFile(configURL, data: data, posixMode: 0o600)
        }
    }

    private func readCurrentConfiguration(target: ClientConfigTarget) throws -> ResolvedConfiguration {
        switch target {
        case .codex:
            return try self.readCodexConfiguration()
        case .claudeCode:
            return try self.readClaudeConfiguration()
        case .gemini:
            return try self.readGeminiConfiguration()
        }
    }

    private func readCodexConfiguration() throws -> ResolvedConfiguration {
        let urls = self.managedFileURLs(for: .codex)
        let authURL = urls[0]
        let configURL = urls[1]

        let apiKey: String?
        if FileManager.default.fileExists(atPath: authURL.path) {
            let object = try self.jsonObject(from: authURL)
            apiKey = object["OPENAI_API_KEY"] as? String
        } else {
            apiKey = nil
        }

        let baseURL: String?
        if FileManager.default.fileExists(atPath: configURL.path) {
            let text = try String(contentsOf: configURL, encoding: .utf8)
            baseURL = self.tomlValue(inSection: "[model_providers.custom]", key: "base_url", text: text)
        } else {
            baseURL = nil
        }

        return ResolvedConfiguration(
            currentAPIKey: apiKey,
            currentBaseURL: baseURL
        )
    }

    private func readClaudeConfiguration() throws -> ResolvedConfiguration {
        let settingsURL = self.managedFileURLs(for: .claudeCode)[0]
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return ResolvedConfiguration(currentAPIKey: nil, currentBaseURL: nil)
        }

        let object = try self.jsonObject(from: settingsURL)
        let env = object["env"] as? [String: Any] ?? [:]
        return ResolvedConfiguration(
            currentAPIKey: env["ANTHROPIC_AUTH_TOKEN"] as? String,
            currentBaseURL: env["ANTHROPIC_BASE_URL"] as? String
        )
    }

    private func readGeminiConfiguration() throws -> ResolvedConfiguration {
        let urls = self.managedFileURLs(for: .gemini)
        let envURL = urls[0]
        let settingsURL = urls[1]

        if FileManager.default.fileExists(atPath: settingsURL.path) {
            _ = try self.jsonObject(from: settingsURL)
        }

        guard FileManager.default.fileExists(atPath: envURL.path) else {
            return ResolvedConfiguration(currentAPIKey: nil, currentBaseURL: nil)
        }

        let text = (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""
        let env = self.dotEnvDictionary(from: text)
        return ResolvedConfiguration(
            currentAPIKey: env["GEMINI_API_KEY"],
            currentBaseURL: env["GOOGLE_GEMINI_BASE_URL"]
        )
    }

    private func updatedCodexAuthData(url: URL, apiKey: String) throws -> Data {
        var object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            object = try self.jsonObject(from: url)
        } else {
            object = [:]
        }
        Self.removeCodexManagedAuthFields(from: &object)
        object["auth_mode"] = "apikey"
        object["OPENAI_API_KEY"] = apiKey
        return try self.jsonData(from: object)
    }

    private func updatedCodexConfigData(url: URL, baseURL: String) throws -> Data {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let withProvider = self.upsertTopLevelAssignment(
            in: existing,
            key: "model_provider",
            value: "\"custom\""
        )
        let updated = self.upsertSectionAssignments(
            in: withProvider,
            sectionHeader: "[model_providers.custom]",
            orderedAssignments: [
                ("base_url", "\"\(self.tomlEscaped(baseURL))\""),
                ("name", "\"custom\""),
                ("requires_openai_auth", "true"),
                ("wire_api", "\"responses\""),
            ]
        )
        return Data(updated.utf8)
    }

    private func updatedCodexProjectConfigData(url: URL, rule: CodexProjectRouteRule) throws -> Data {
        let normalizedRouteModel = rule.routeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRouteModel.isEmpty == false else {
            throw ProxyError.message("项目路由模型不能为空")
        }
        let catalogURL = self.codexProjectRouteModelCatalogURL(configURL: url)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let withModel = self.upsertTopLevelAssignment(
            in: existing,
            key: "model",
            value: "\"\(self.tomlEscaped(normalizedRouteModel))\""
        )
        let updated = self.upsertTopLevelAssignment(
            in: withModel,
            key: "model_catalog_json",
            value: "\"\(self.tomlEscaped(catalogURL.path))\""
        )
        return Data(updated.utf8)
    }

    private func clearedCodexProjectConfigData(url: URL, catalogURL: URL) -> Data {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var updated = self.removeTopLevelAssignment(in: existing, key: "model")
        if self.topLevelTOMLValue(key: "model_catalog_json", text: updated) == catalogURL.path {
            updated = self.removeTopLevelAssignment(in: updated, key: "model_catalog_json")
        }
        return Data(updated.utf8)
    }

    private func codexProjectRouteModelCatalogData(rule: CodexProjectRouteRule) throws -> Data {
        let normalizedRouteModel = rule.routeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRouteModel.isEmpty == false else {
            throw ProxyError.message("项目路由模型不能为空")
        }
        let normalizedLabel = rule.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = normalizedLabel.isEmpty ? normalizedRouteModel : normalizedLabel
        let targetModel = rule.targetModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = targetModel.isEmpty
            ? "Codex Proxy project route"
            : "Codex Proxy project route forwarding to \(targetModel)"
        let model: [String: Any] = [
            "slug": normalizedRouteModel,
            "display_name": displayName,
            "description": description,
            "default_reasoning_level": "medium",
            "supported_reasoning_levels": [
                ["effort": "low", "description": "Fast responses with lighter reasoning"],
                ["effort": "medium", "description": "Balances speed and reasoning depth"],
                ["effort": "high", "description": "Greater reasoning depth"],
            ],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": 0,
            "base_instructions": "",
            "model_messages": [
                "instructions_template": "{{ personality }}",
                "instructions_variables": [:],
            ],
            "supports_reasoning_summaries": true,
            "default_reasoning_summary": "none",
            "support_verbosity": true,
            "default_verbosity": "low",
            "apply_patch_tool_type": "freeform",
            "web_search_tool_type": "text_and_image",
            "truncation_policy": [
                "mode": "tokens",
                "limit": 10_000,
            ],
            "supports_parallel_tool_calls": true,
            "supports_image_detail_original": true,
            "context_window": 128_000,
            "max_context_window": 128_000,
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [],
            "input_modalities": ["text", "image"],
            "supports_search_tool": true,
        ]
        return try self.jsonData(from: ["models": [model]])
    }

    private func removeCodexProjectRouteModelCatalogIfManaged(url: URL, rule: CodexProjectRouteRule) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard self.codexProjectRouteModelCatalogIsManaged(url: url, rule: rule) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func codexProjectRouteModelCatalogIsManaged(url: URL, rule: CodexProjectRouteRule) -> Bool {
        guard let object = try? self.jsonObject(from: url),
              let models = object["models"] as? [[String: Any]]
        else {
            return false
        }
        let routeModel = rule.routeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.contains { ($0["slug"] as? String) == routeModel }
    }

    private func updatedClaudeProjectSettingsData(url: URL, rule: CodexProjectRouteRule) throws -> Data {
        let normalizedRouteModel = rule.routeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRouteModel.isEmpty == false else {
            throw ProxyError.message("项目路由模型不能为空")
        }
        var object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            object = try self.jsonObject(from: url)
        } else {
            object = [:]
        }
        object["model"] = normalizedRouteModel
        var env = object["env"] as? [String: Any] ?? [:]
        env[ClaudeProjectRouteManagedEnv.customModelOption] = normalizedRouteModel
        env[ClaudeProjectRouteManagedEnv.customModelOptionName] = rule.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Codex Proxy Project Route"
            : "项目路由：\(rule.label.trimmingCharacters(in: .whitespacesAndNewlines))"
        env[ClaudeProjectRouteManagedEnv.customModelOptionDescription] = "由 Codex Proxy 项目路由转发到绑定账号"
        object["env"] = env
        return try self.jsonData(from: object)
    }

    private func clearedClaudeProjectSettingsData(url: URL) throws -> Data {
        var object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            object = try self.jsonObject(from: url)
        } else {
            object = [:]
        }
        object.removeValue(forKey: "model")
        if var env = object["env"] as? [String: Any] {
            for key in ClaudeProjectRouteManagedEnv.keys {
                env.removeValue(forKey: key)
            }
            object["env"] = env
        }
        return try self.jsonData(from: object)
    }

    private func updatedClaudeSettingsData(
        url: URL,
        apiKey: String,
        baseURL: String
    ) throws -> Data {
        var object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            object = try self.jsonObject(from: url)
        } else {
            object = [:]
        }
        var env = object["env"] as? [String: Any] ?? [:]
        env["ANTHROPIC_AUTH_TOKEN"] = apiKey
        env["ANTHROPIC_BASE_URL"] = baseURL
        object["env"] = env
        return try self.jsonData(from: object)
    }

    private func updatedGeminiEnvData(
        url: URL,
        apiKey: String,
        baseURL: String
    ) -> Data {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = self.upsertDotEnvVariables(
            in: existing,
            orderedVariables: [
                ("GEMINI_API_KEY", apiKey),
                ("GOOGLE_GEMINI_BASE_URL", baseURL),
            ]
        )
        return Data(updated.utf8)
    }

    private func updatedGeminiSettingsData(url: URL) throws -> Data {
        var object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            object = try self.jsonObject(from: url)
        } else {
            object = [:]
        }
        var security = object["security"] as? [String: Any] ?? [:]
        var auth = security["auth"] as? [String: Any] ?? [:]
        auth["selectedType"] = "gemini-api-key"
        security["auth"] = auth
        object["security"] = security
        return try self.jsonData(from: object)
    }

    private func jsonObject(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProxyError.message("\(url.lastPathComponent) is not a JSON object.")
        }
        return object
    }

    private func jsonData(from object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ProxyError.message("The updated JSON payload is invalid.")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func dotEnvDictionary(from text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false, line.hasPrefix("#") == false else { continue }
            guard let separatorIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false else { continue }
            values[key] = value
        }
        return values
    }

    private func upsertDotEnvVariables(
        in text: String,
        orderedVariables: [(String, String)]
    ) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var insertedKeys = Set<String>()
        var missing: [(String, String)] = []

        for (key, value) in orderedVariables {
            var replaced = false
            lines = lines.compactMap { line in
                guard Self.dotEnvLine(line, matches: key) else { return line }
                if replaced {
                    return nil
                }
                replaced = true
                insertedKeys.insert(key)
                return "\(key)=\(value)"
            }
            if replaced == false {
                missing.append((key, value))
            }
        }

        if lines.isEmpty == false, lines.last?.isEmpty == false, missing.isEmpty == false {
            lines.append("")
        }

        for (key, value) in missing where insertedKeys.contains(key) == false {
            lines.append("\(key)=\(value)")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.newlines) + "\n"
    }

    private func tomlValue(
        inSection targetSection: String,
        key: String,
        text: String
    ) -> String? {
        var currentSection: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isTOMLSectionHeader(line) {
                currentSection = line
                continue
            }
            guard currentSection == targetSection else { continue }
            guard let assignment = Self.parseTOMLAssignment(line), assignment.key == key else { continue }
            return Self.unquotedTOMLValue(assignment.value)
        }
        return nil
    }

    private func topLevelTOMLValue(
        key: String,
        text: String
    ) -> String? {
        var currentSection: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isTOMLSectionHeader(line) {
                currentSection = line
                continue
            }
            guard currentSection == nil else { continue }
            guard let assignment = Self.parseTOMLAssignment(line), assignment.key == key else { continue }
            return Self.unquotedTOMLValue(assignment.value)
        }
        return nil
    }

    private func upsertTopLevelAssignment(
        in text: String,
        key: String,
        value: String
    ) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var updatedLines: [String] = []
        var currentSection: String?
        var replaced = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isTOMLSectionHeader(trimmed) {
                if replaced == false {
                    updatedLines.append("\(key) = \(value)")
                    updatedLines.append("")
                    replaced = true
                }
                currentSection = trimmed
                updatedLines.append(line)
                continue
            }

            if currentSection == nil,
               let assignment = Self.parseTOMLAssignment(trimmed),
               assignment.key == key
            {
                if replaced == false {
                    updatedLines.append("\(key) = \(value)")
                    replaced = true
                }
                continue
            }

            updatedLines.append(line)
        }

        if replaced == false {
            if updatedLines.isEmpty == false, updatedLines.last?.isEmpty == false {
                updatedLines.append("")
            }
            updatedLines.append("\(key) = \(value)")
        }

        return updatedLines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.newlines) + "\n"
    }

    private func removeTopLevelAssignment(
        in text: String,
        key: String
    ) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var updatedLines: [String] = []
        var currentSection: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isTOMLSectionHeader(trimmed) {
                currentSection = trimmed
                updatedLines.append(line)
                continue
            }

            if currentSection == nil,
               let assignment = Self.parseTOMLAssignment(trimmed),
               assignment.key == key
            {
                continue
            }

            updatedLines.append(line)
        }

        let updated = updatedLines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.newlines)
        return updated.isEmpty ? "" : updated + "\n"
    }

    private func upsertSectionAssignments(
        in text: String,
        sectionHeader: String,
        orderedAssignments: [(String, String)]
    ) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let sectionStart = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == sectionHeader
        }) else {
            if lines.isEmpty == false, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(sectionHeader)
            lines.append(contentsOf: orderedAssignments.map { "\($0.0) = \($0.1)" })
            return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.newlines) + "\n"
        }

        var sectionEnd = lines.count
        if sectionStart + 1 < lines.count {
            if let nextSection = lines[(sectionStart + 1)...].firstIndex(where: {
                Self.isTOMLSectionHeader($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }) {
                sectionEnd = nextSection
            }
        }

        let originalSectionBody = Array(lines[(sectionStart + 1)..<sectionEnd])
        let remainingAssignments = Dictionary(uniqueKeysWithValues: orderedAssignments)
        var pending = orderedAssignments.map(\.0)
        var updatedBody: [String] = []

        for line in originalSectionBody {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let assignment = Self.parseTOMLAssignment(trimmed),
                  remainingAssignments[assignment.key] != nil
            else {
                updatedBody.append(line)
                continue
            }

            if pending.contains(assignment.key) {
                let value = remainingAssignments[assignment.key] ?? assignment.value
                updatedBody.append("\(assignment.key) = \(value)")
                pending.removeAll { $0 == assignment.key }
            }
        }

        if updatedBody.isEmpty == false, updatedBody.last?.isEmpty == false, pending.isEmpty == false {
            updatedBody.append("")
        }

        for key in pending {
            if let value = remainingAssignments[key] {
                updatedBody.append("\(key) = \(value)")
            }
        }

        lines.replaceSubrange((sectionStart + 1)..<sectionEnd, with: updatedBody)
        return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.newlines) + "\n"
    }

    private func writeFile(_ url: URL, data: Data, posixMode: Int16) throws {
        if let writeFileHandler = self.writeFileHandler {
            try writeFileHandler(url, data, posixMode)
        } else {
            try Helpers.writeFile(url, data: data, posixMode: posixMode)
        }
    }

    private func desiredConfiguration(
        proxyAPIKey: ProxyAPIKeyRecord,
        target: ClientConfigTarget,
        endpoints: ClientConfigEndpointBundle
    ) throws -> DesiredConfiguration {
        let desired = DesiredConfiguration(
            apiKey: proxyAPIKey.key.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: self.baseURL(for: target, endpoints: endpoints)
        )
        guard desired.apiKey.isEmpty == false else {
            throw ProxyError.message("The selected local API key is empty.")
        }
        guard desired.baseURL.isEmpty == false else {
            throw ProxyError.message("The target base URL is empty.")
        }
        return desired
    }

    private func baseURL(
        for target: ClientConfigTarget,
        endpoints: ClientConfigEndpointBundle
    ) -> String {
        switch target {
        case .codex:
            return endpoints.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        case .claudeCode:
            return endpoints.anthropicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        case .gemini:
            return endpoints.geminiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func textLanguage(for url: URL) -> ClientConfigTextLanguage {
        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        case "toml":
            return .toml
        case "env":
            return .dotenv
        default:
            if url.lastPathComponent == ".env" {
                return .dotenv
            }
            return .text
        }
    }

    private func textContent(from data: Data, fileName: String) throws -> String {
        guard let content = String(data: data, encoding: .utf8) else {
            throw ProxyError.message("\(fileName) is not valid UTF-8 text.")
        }
        return content
    }

    private func validateTextSnapshotContent(
        _ content: String,
        language: ClientConfigTextLanguage,
        fileName: String
    ) throws {
        guard language == .json else { return }
        let data = Data(content.utf8)
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ProxyError.message("\(fileName) is not a JSON object.")
        }
    }

    private func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unquotedTOMLValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.hasPrefix("\""),
              trimmed.hasSuffix("\"")
        else {
            return trimmed
        }
        let start = trimmed.index(after: trimmed.startIndex)
        let end = trimmed.index(before: trimmed.endIndex)
        return String(trimmed[start..<end])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseTOMLAssignment(_ line: String) -> (key: String, value: String)? {
        guard line.isEmpty == false, line.hasPrefix("#") == false else { return nil }
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return nil }
        let valueStart = line.index(after: separator)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, value)
    }

    private static func isTOMLSectionHeader(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]")
    }

    private static func dotEnvLine(_ line: String, matches key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") == false else { return false }
        guard let separator = trimmed.firstIndex(of: "=") else { return false }
        let lhs = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs == key
    }

    private static func removeCodexManagedAuthFields(from object: inout [String: Any]) {
        let managedKeys = [
            "OPENAI_API_KEY",
            "access_token",
            "refresh_token",
            "id_token",
            "account_id",
            "last_refresh",
            "auth_mode",
            "tokens",
            "provider_preset",
            "provider_family",
            "upstream_base_url",
            "upstream_base_url_mode",
            "upstream_adapter",
            "base_url",
            "baseURL",
            "OPENAI_BASE_URL",
            "openai_base_url",
            "agent_identity",
            "agent_private_key",
            "email",
            "plan_type",
        ]
        for key in managedKeys {
            object.removeValue(forKey: key)
        }
    }

    private static func cleanedString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
