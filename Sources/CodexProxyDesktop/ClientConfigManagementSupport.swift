#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation

enum ClientConfigManagerOperation: Equatable {
    case idle
    case loading
    case applying(ClientConfigTarget)
    case restoring(String)
}

enum ClientConfigPreviewMode: String, CaseIterable, Identifiable {
    case current
    case proposed

    var id: String { self.rawValue }
}

enum ClientConfigBackupDrawerMode: String, Equatable {
    case list
    case detail
}

enum ClientConfigPreviewFileChangeKind: Equatable {
    case readFailed
    case willCreate
    case willUpdate
    case unchanged
}

struct ClientConfigPreviewFilePresentation: Identifiable, Equatable {
    var file: ClientConfigFileTextSnapshot
    var changeKind: ClientConfigPreviewFileChangeKind

    var id: String { self.file.path }
}

@MainActor
extension DesktopAppModel {
    var clientConfigManagerWindowTitle: String {
        self.localized(zh: "客户端配置管理", en: "Client Config Manager")
    }

    var actionOpenClientConfigManager: String {
        self.localized(zh: "本机配置管理", en: "Configure Local Clients")
    }

    var clientConfigManagerAvailableProxyAPIKeys: [ProxyAPIKeyRecord] {
        self.configuredProxyAPIKeys.filter(\.enabled)
    }

    var clientConfigManagerEndpointBundle: ClientConfigEndpointBundle {
        ClientConfigEndpointBundle(
            openAIBaseURL: self.openAICompatibleBaseURL,
            anthropicBaseURL: self.anthropicBaseURL,
            geminiBaseURL: self.geminiBaseURL
        )
    }

    var isClientConfigManagerBusy: Bool {
        self.clientConfigManagerOperation != .idle
    }

    var clientConfigManagerVisibleBackups: [ClientConfigBackupRecord] {
        self.clientConfigManagerBackups.filter { $0.target == self.clientConfigManagerTarget }
    }

    var clientConfigManagerVisiblePreview: ClientConfigPreview {
        self.clientConfigManagerPreview(for: self.clientConfigManagerTarget, mode: self.clientConfigManagerPreviewMode)
    }

    var clientConfigManagerVisibleFilePresentations: [ClientConfigPreviewFilePresentation] {
        self.clientConfigManagerVisiblePreview.files.map { file in
            ClientConfigPreviewFilePresentation(
                file: file,
                changeKind: self.clientConfigManagerFileChangeKind(
                    target: self.clientConfigManagerTarget,
                    path: file.path
                )
            )
        }
    }

    var clientConfigManagerSelectedPreviewFile: ClientConfigFileTextSnapshot? {
        let preview = self.clientConfigManagerVisiblePreview
        let selectionKey = self.clientConfigManagerPreviewSelectionKey(
            target: preview.target,
            mode: self.clientConfigManagerPreviewMode
        )
        if let selectedPath = self.clientConfigManagerSelectedPreviewFilePaths[selectionKey],
           let matched = preview.files.first(where: { $0.path == selectedPath })
        {
            return matched
        }
        return preview.files.first
    }

    var clientConfigManagerSelectedPreviewFilePresentation: ClientConfigPreviewFilePresentation? {
        guard let file = self.clientConfigManagerSelectedPreviewFile else { return nil }
        return ClientConfigPreviewFilePresentation(
            file: file,
            changeKind: self.clientConfigManagerFileChangeKind(
                target: self.clientConfigManagerTarget,
                path: file.path
            )
        )
    }

    var clientConfigManagerChangedFileCount: Int {
        self.clientConfigManagerProposedPreviews[self.clientConfigManagerTarget]?.files.reduce(0) { partial, file in
            let changeKind = self.clientConfigManagerFileChangeKind(
                target: self.clientConfigManagerTarget,
                path: file.path
            )
            switch changeKind {
            case .willCreate, .willUpdate:
                return partial + 1
            case .readFailed, .unchanged:
                return partial
            }
        } ?? 0
    }

    var clientConfigManagerChangeSummaryText: String {
        let target = self.clientConfigManagerTarget
        let files = self.clientConfigManagerProposedPreviews[target]?.files ?? []
        let kinds = files.map { self.clientConfigManagerFileChangeKind(target: target, path: $0.path) }
        let createCount = kinds.filter { $0 == .willCreate }.count
        let updateCount = kinds.filter { $0 == .willUpdate }.count
        let unchangedCount = kinds.filter { $0 == .unchanged }.count
        let failedCount = kinds.filter { $0 == .readFailed }.count

        var parts: [String] = []
        if createCount > 0 {
            parts.append(self.localized(zh: "\(createCount) 个将创建", en: "\(createCount) to create"))
        }
        if updateCount > 0 {
            parts.append(self.localized(zh: "\(updateCount) 个将更新", en: "\(updateCount) to update"))
        }
        if unchangedCount > 0 {
            parts.append(self.localized(zh: "\(unchangedCount) 个无变化", en: "\(unchangedCount) unchanged"))
        }
        if failedCount > 0 {
            parts.append(self.localized(zh: "\(failedCount) 个读取失败", en: "\(failedCount) read failed"))
        }
        return parts.isEmpty ? self.localized(zh: "暂无可比较文件", en: "No comparable files") : parts.joined(separator: " · ")
    }

    func clientConfigManagerTitle(for target: ClientConfigTarget) -> String {
        switch target {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        case .gemini:
            return "Gemini"
        }
    }

    func clientConfigManagerInspection(for target: ClientConfigTarget) -> ClientConfigInspection {
        self.clientConfigManagerInspections[target]
            ?? ClientConfigInspection(
                target: target,
                files: self.clientConfigFileService.managedFileURLs(for: target).map {
                    ClientConfigManagedFileState(path: $0.path, exists: FileManager.default.fileExists(atPath: $0.path))
                }
            )
    }

    func clientConfigManagerSelectedProxyAPIKeyRecord(
        for target: ClientConfigTarget? = nil
    ) -> ProxyAPIKeyRecord? {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        if let selectedID = self.clientConfigManagerSelectedProxyAPIKeyIDs[resolvedTarget],
           let matched = self.clientConfigManagerAvailableProxyAPIKeys.first(where: { $0.id == selectedID })
        {
            return matched
        }
        return self.clientConfigManagerAvailableProxyAPIKeys.first
    }

    var clientConfigManagerCanApplyCurrentSelection: Bool {
        self.clientConfigManagerSelectedProxyAPIKeyRecord() != nil && !self.isClientConfigManagerBusy
    }

    var clientConfigManagerApplyUnavailableReason: String? {
        if self.clientConfigManagerAvailableProxyAPIKeys.isEmpty {
            return self.localized(
                zh: "当前没有启用中的本地 API Key。请先到 Proxy 页启用至少一把 Key。",
                en: "There are no enabled local API keys. Enable at least one key on the Proxy page first."
            )
        }
        if self.clientConfigManagerSelectedProxyAPIKeyRecord() == nil {
            return self.localized(
                zh: "请选择一把要写入客户端配置的本地 Key。",
                en: "Choose the local key that should be written into the client config."
            )
        }
        if self.isClientConfigManagerBusy {
            return self.localized(
                zh: "当前操作还在进行中，请稍等。",
                en: "An operation is already running. Please wait."
            )
        }
        return nil
    }

    var clientConfigManagerCurrentSelectionStatusText: String {
        let inspection = self.clientConfigManagerInspection(for: self.clientConfigManagerTarget)
        if let reason = self.clientConfigManagerApplyUnavailableReason {
            return reason
        }
        if let selectedID = self.clientConfigManagerSelectedProxyAPIKeyRecord()?.id,
           inspection.currentKeyKind == .matched,
           inspection.matchedProxyAPIKeyID == selectedID
        {
            return self.localized(
                zh: "当前客户端已经在使用这把本地 Key。",
                en: "This client is already using the selected local key."
            )
        }
        return self.localized(
            zh: "确认下方预览后，点击应用会写入真实配置文件并自动创建备份。",
            en: "After reviewing the preview below, Apply writes the real config files and creates a backup automatically."
        )
    }

    func clientConfigManagerApplyButtonTitle(for target: ClientConfigTarget? = nil) -> String {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        return self.localized(
            zh: "应用到 \(self.clientConfigManagerTitle(for: resolvedTarget))",
            en: "Apply To \(self.clientConfigManagerTitle(for: resolvedTarget))"
        )
    }

    func clientConfigManagerEndpointText(for target: ClientConfigTarget? = nil) -> String {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        switch resolvedTarget {
        case .codex:
            return self.clientConfigManagerEndpointBundle.openAIBaseURL
        case .claudeCode:
            return self.clientConfigManagerEndpointBundle.anthropicBaseURL
        case .gemini:
            return self.clientConfigManagerEndpointBundle.geminiBaseURL
        }
    }

    func clientConfigManagerSelectProxyAPIKey(_ id: String?, for target: ClientConfigTarget? = nil) {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        self.clientConfigManagerSelectedProxyAPIKeyIDs[resolvedTarget] = id
        self.refreshClientConfigManagerPreview(target: resolvedTarget)
    }

    func clientConfigManagerSelectPreviewFile(_ path: String?) {
        let key = self.clientConfigManagerPreviewSelectionKey(
            target: self.clientConfigManagerTarget,
            mode: self.clientConfigManagerPreviewMode
        )
        self.clientConfigManagerSelectedPreviewFilePaths[key] = path
    }

    func clientConfigManagerCurrentKeyStatusText(for inspection: ClientConfigInspection) -> String {
        if let errorMessage = inspection.errorMessage, !errorMessage.isEmpty {
            return self.localized(zh: "读取失败", en: "Read Failed")
        }
        switch inspection.currentKeyKind {
        case .missing:
            return self.text(.statusUnavailable)
        case .matched:
            let label = inspection.matchedProxyAPIKeyLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return label.isEmpty ? self.localized(zh: "已匹配", en: "Matched") : label
        case .external:
            return self.localized(zh: "外部 / 未知 Key", en: "External / Unknown Key")
        }
    }

    func clientConfigManagerCurrentKeyDisplayValue(for inspection: ClientConfigInspection) -> String {
        let trimmed = inspection.currentAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else { return self.text(.statusUnavailable) }
        return RequestLogPresentation.maskedAPIKey(trimmed)
    }

    func clientConfigManagerFileSummary(for inspection: ClientConfigInspection) -> String {
        let existingCount = inspection.files.filter(\.exists).count
        return self.localized(
            zh: "\(existingCount) / \(inspection.files.count) 个文件存在",
            en: "\(existingCount) / \(inspection.files.count) managed files exist"
        )
    }

    func clientConfigManagerBackupSummary(for backup: ClientConfigBackupRecord) -> String {
        let reason = self.clientConfigManagerBackupReasonText(backup.reason)
        let timestamp = FixedDisplayDateTimeFormat.string(fromUnixSeconds: backup.createdAt)
        let keyLabel = backup.proxyAPIKeyLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if keyLabel.isEmpty {
            return "\(timestamp) · \(reason)"
        }
        return "\(timestamp) · \(reason) · \(keyLabel)"
    }

    func clientConfigManagerBackupReasonText(_ reason: ClientConfigBackupReason) -> String {
        switch reason {
        case .beforeApply:
            return self.localized(zh: "应用前备份", en: "Pre-apply Backup")
        case .beforeRestore:
            return self.localized(zh: "还原前备份", en: "Pre-restore Backup")
        }
    }

    func clientConfigManagerPreviewModeText(_ mode: ClientConfigPreviewMode) -> String {
        switch mode {
        case .current:
            return self.localized(zh: "当前配置", en: "Current")
        case .proposed:
            return self.localized(zh: "应用后预览", en: "Proposed")
        }
    }

    func clientConfigManagerPreviewFileStatusText(_ file: ClientConfigFileTextSnapshot) -> String {
        if file.errorMessage?.isEmpty == false {
            return self.localized(zh: "读取失败", en: "Read Failed")
        }
        return file.exists
            ? self.localized(zh: "已存在", en: "Exists")
            : self.localized(zh: "不存在", en: "Missing")
    }

    func clientConfigManagerPreviewFileStatusTone(_ file: ClientConfigFileTextSnapshot) -> StatusPill.Tone {
        if file.errorMessage?.isEmpty == false {
            return .danger
        }
        return file.exists ? .success : .warning
    }

    func clientConfigManagerFileChangeKindText(_ kind: ClientConfigPreviewFileChangeKind) -> String {
        switch kind {
        case .readFailed:
            return self.localized(zh: "读取失败", en: "Read Failed")
        case .willCreate:
            return self.localized(zh: "将创建", en: "Will Create")
        case .willUpdate:
            return self.localized(zh: "将更新", en: "Will Update")
        case .unchanged:
            return self.localized(zh: "无变化", en: "Unchanged")
        }
    }

    func clientConfigManagerFileChangeKindTone(_ kind: ClientConfigPreviewFileChangeKind) -> StatusPill.Tone {
        switch kind {
        case .readFailed:
            return .danger
        case .willCreate:
            return .success
        case .willUpdate:
            return .accent
        case .unchanged:
            return .neutral
        }
    }

    func clientConfigManagerFileChangeKindSymbol(_ kind: ClientConfigPreviewFileChangeKind) -> String {
        switch kind {
        case .readFailed:
            return "exclamationmark.triangle.fill"
        case .willCreate:
            return "doc.badge.plus"
        case .willUpdate:
            return "square.and.pencil"
        case .unchanged:
            return "checkmark.circle.fill"
        }
    }

    func clientConfigManagerDisplayContent(for file: ClientConfigFileTextSnapshot) -> String {
        if let errorMessage = file.errorMessage, !errorMessage.isEmpty, file.content.isEmpty {
            return errorMessage
        }
        guard self.clientConfigManagerPreviewRevealsSecrets == false else {
            return file.content
        }
        return Self.maskedClientConfigContent(file.content)
    }

    func clientConfigManagerApplySuccessTitle(for target: ClientConfigTarget) -> String {
        self.localized(
            zh: "\(self.clientConfigManagerTitle(for: target)) 配置已应用",
            en: "\(self.clientConfigManagerTitle(for: target)) configuration applied"
        )
    }

    func clientConfigManagerApplySuccessDetail(
        for target: ClientConfigTarget,
        proxyAPIKey: ProxyAPIKeyRecord
    ) -> String {
        let keyLabel = self.proxyAPIKeyDisplayLabel(proxyAPIKey)
        return self.localized(
            zh: "已把本地 Key “\(keyLabel)” 和代理地址写入 \(self.clientConfigManagerTitle(for: target))。",
            en: "Wrote local key “\(keyLabel)” and the proxy endpoint into \(self.clientConfigManagerTitle(for: target))."
        )
    }

    func clientConfigManagerRestoreSuccessTitle(for target: ClientConfigTarget) -> String {
        self.localized(
            zh: "\(self.clientConfigManagerTitle(for: target)) 配置已还原",
            en: "\(self.clientConfigManagerTitle(for: target)) configuration restored"
        )
    }

    func clientConfigManagerRestoreSuccessDetail(for backup: ClientConfigBackupRecord) -> String {
        let timestamp = FixedDisplayDateTimeFormat.string(fromUnixSeconds: backup.createdAt)
        return self.localized(
            zh: "已从 \(timestamp) 的备份恢复受管文件。",
            en: "Restored managed files from the backup created at \(timestamp)."
        )
    }

    func openClientConfigManagerWindow() {
        if self.clientConfigManagerWindowController == nil {
            self.clientConfigManagerWindowController = self.clientConfigManagerWindowFactory(self)
        }
        self.ensureClientConfigManagerSelection(for: self.clientConfigManagerTarget)
        self.isClientConfigManagerPresented = true
        self.clientConfigManagerWindowController?.showWindow()
        Task { await self.refreshClientConfigManagerState(showLoading: true) }
    }

    func dismissClientConfigManagerWindow() {
        self.isClientConfigManagerPresented = false
        self.clientConfigManagerWindowController?.closeWindow()
    }

    func handleClientConfigManagerWindowDidClose() {
        self.isClientConfigManagerPresented = false
    }

    func presentClientConfigBackupDrawer() {
        self.clientConfigBackupDrawerMode = .list
        self.isClientConfigBackupDrawerPresented = true
    }

    func dismissClientConfigBackupDrawer() {
        self.isClientConfigBackupDrawerPresented = false
        self.clientConfigBackupDrawerMode = .list
        self.clientConfigManagerBackupDetail = nil
    }

    func returnToClientConfigBackupList() {
        self.clientConfigBackupDrawerMode = .list
        self.clientConfigManagerBackupDetail = nil
        self.isClientConfigBackupDrawerPresented = true
    }

    func refreshClientConfigManagerState(showLoading: Bool = false) async {
        if showLoading {
            self.clientConfigManagerOperation = .loading
        }

        let inspections = self.clientConfigFileService.inspectAll(
            availableProxyAPIKeys: self.clientConfigManagerAvailableProxyAPIKeys
        )
        let backups = self.clientConfigFileService.listBackups()
        self.clientConfigManagerInspections = inspections
        self.clientConfigManagerBackups = backups
        self.ensureClientConfigManagerSelection(for: self.clientConfigManagerTarget)
        self.refreshClientConfigManagerPreviews()

        if showLoading, self.clientConfigManagerOperation == .loading {
            self.clientConfigManagerOperation = .idle
        }
    }

    func applyClientConfigManagerSelection() async {
        guard let selectedProxyAPIKey = self.clientConfigManagerSelectedProxyAPIKeyRecord() else {
            self.publishBanner(
                .warning,
                title: self.text(.errorConfigurationFailed),
                detail: self.localized(zh: "当前没有可用的本地 API Key 可应用。", en: "There is no enabled local API key available to apply.")
            )
            return
        }

        let target = self.clientConfigManagerTarget
        self.clientConfigManagerOperation = .applying(target)
        defer { self.clientConfigManagerOperation = .idle }

        do {
            _ = try self.clientConfigFileService.applyConfiguration(
                target: target,
                proxyAPIKey: selectedProxyAPIKey,
                endpoints: self.clientConfigManagerEndpointBundle
            )
            await self.refreshClientConfigManagerState()
            self.publishBanner(
                .success,
                title: self.clientConfigManagerApplySuccessTitle(for: target),
                detail: self.clientConfigManagerApplySuccessDetail(for: target, proxyAPIKey: selectedProxyAPIKey)
            )
        } catch {
            self.present(error: error, context: .saveSettings)
        }
    }

    func restoreClientConfigBackup(_ backup: ClientConfigBackupRecord) async {
        self.clientConfigManagerOperation = .restoring(backup.id)
        defer { self.clientConfigManagerOperation = .idle }

        do {
            _ = try self.clientConfigFileService.restoreBackup(id: backup.id)
            await self.refreshClientConfigManagerState()
            self.publishBanner(
                .success,
                title: self.clientConfigManagerRestoreSuccessTitle(for: backup.target),
                detail: self.clientConfigManagerRestoreSuccessDetail(for: backup)
            )
        } catch {
            self.present(error: error, context: .saveSettings)
        }
    }

    func requestClientConfigBackupRestore(_ backup: ClientConfigBackupRecord) {
        self.clientConfigManagerPendingRestoreBackup = backup
        self.isClientConfigManagerRestoreConfirmationPresented = true
    }

    func cancelClientConfigBackupRestore() {
        self.isClientConfigManagerRestoreConfirmationPresented = false
        self.clientConfigManagerPendingRestoreBackup = nil
    }

    func confirmClientConfigBackupRestore() async {
        guard let backup = self.clientConfigManagerPendingRestoreBackup else { return }
        self.isClientConfigManagerRestoreConfirmationPresented = false
        self.clientConfigManagerPendingRestoreBackup = nil
        await self.restoreClientConfigBackup(backup)
    }

    func revealClientConfigManagedFiles() {
        self.revealClientConfigURLs(self.clientConfigFileService.managedFileURLs(for: self.clientConfigManagerTarget))
    }

    func revealClientConfigBackupDirectory() {
        let url = self.clientConfigFileService.backupDirectoryURL()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = NSWorkspace.shared.open(url)
        } else {
            _ = NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func openClientConfigBackupViewer(_ backup: ClientConfigBackupRecord) {
        do {
            let detail = try self.clientConfigFileService.loadBackupDetail(id: backup.id)
            self.clientConfigManagerBackupDetail = detail
            self.clientConfigBackupDrawerMode = .detail
            self.isClientConfigBackupDrawerPresented = true
        } catch {
            self.present(error: error, context: .saveSettings)
        }
    }

    private func ensureClientConfigManagerSelection(for target: ClientConfigTarget) {
        if let selectedID = self.clientConfigManagerSelectedProxyAPIKeyIDs[target],
           self.clientConfigManagerAvailableProxyAPIKeys.contains(where: { $0.id == selectedID })
        {
            return
        }
        self.clientConfigManagerSelectedProxyAPIKeyIDs[target] = self.clientConfigManagerAvailableProxyAPIKeys.first?.id
    }

    private func clientConfigManagerPreview(for target: ClientConfigTarget, mode: ClientConfigPreviewMode) -> ClientConfigPreview {
        switch mode {
        case .current:
            return self.clientConfigManagerCurrentPreviews[target] ?? self.emptyClientConfigManagerPreview(for: target)
        case .proposed:
            return self.clientConfigManagerProposedPreviews[target] ?? self.emptyClientConfigManagerPreview(for: target)
        }
    }

    func clientConfigManagerFileChangeKind(
        target: ClientConfigTarget? = nil,
        path: String
    ) -> ClientConfigPreviewFileChangeKind {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        let current = self.clientConfigManagerCurrentPreviews[resolvedTarget]?.files.first { $0.path == path }
        let proposed = self.clientConfigManagerProposedPreviews[resolvedTarget]?.files.first { $0.path == path }

        if current?.errorMessage?.isEmpty == false || proposed?.errorMessage?.isEmpty == false {
            return .readFailed
        }
        guard let proposed else {
            return .readFailed
        }
        if current?.exists != true, proposed.exists {
            return .willCreate
        }
        guard let current else {
            return proposed.exists ? .willCreate : .unchanged
        }
        if current.exists != proposed.exists || current.content != proposed.content {
            return .willUpdate
        }
        return .unchanged
    }

    private func refreshClientConfigManagerPreviews() {
        for target in ClientConfigTarget.allCases {
            self.refreshClientConfigManagerPreview(target: target)
        }
    }

    private func refreshClientConfigManagerPreview(target: ClientConfigTarget) {
        self.clientConfigManagerCurrentPreviews[target] = self.clientConfigFileService.previewCurrentConfiguration(target: target)
        if let selectedProxyAPIKey = self.clientConfigManagerSelectedProxyAPIKeyRecord(for: target) {
            do {
                self.clientConfigManagerProposedPreviews[target] = try self.clientConfigFileService.previewProposedConfiguration(
                    target: target,
                    proxyAPIKey: selectedProxyAPIKey,
                    endpoints: self.clientConfigManagerEndpointBundle
                )
            } catch {
                self.clientConfigManagerProposedPreviews[target] = self.errorClientConfigManagerPreview(
                    target: target,
                    errorMessage: error.localizedDescription
                )
            }
        } else {
            self.clientConfigManagerProposedPreviews[target] = self.errorClientConfigManagerPreview(
                target: target,
                errorMessage: self.localized(zh: "当前没有可用的本地 API Key。", en: "There is no enabled local API key.")
            )
        }
        self.ensureClientConfigManagerPreviewSelection(target: target, mode: .current)
        self.ensureClientConfigManagerPreviewSelection(target: target, mode: .proposed)
    }

    private func ensureClientConfigManagerPreviewSelection(target: ClientConfigTarget, mode: ClientConfigPreviewMode) {
        let preview = self.clientConfigManagerPreview(for: target, mode: mode)
        let key = self.clientConfigManagerPreviewSelectionKey(target: target, mode: mode)
        if let selectedPath = self.clientConfigManagerSelectedPreviewFilePaths[key],
           preview.files.contains(where: { $0.path == selectedPath })
        {
            return
        }
        self.clientConfigManagerSelectedPreviewFilePaths[key] = preview.files.first?.path
    }

    private func clientConfigManagerPreviewSelectionKey(
        target: ClientConfigTarget,
        mode: ClientConfigPreviewMode
    ) -> String {
        "\(target.rawValue):\(mode.rawValue)"
    }

    private func emptyClientConfigManagerPreview(for target: ClientConfigTarget) -> ClientConfigPreview {
        ClientConfigPreview(
            target: target,
            files: self.clientConfigFileService.managedFileURLs(for: target).map {
                ClientConfigFileTextSnapshot(
                    path: $0.path,
                    exists: FileManager.default.fileExists(atPath: $0.path),
                    content: "",
                    language: self.clientConfigManagerLanguage(for: $0)
                )
            }
        )
    }

    private func errorClientConfigManagerPreview(
        target: ClientConfigTarget,
        errorMessage: String
    ) -> ClientConfigPreview {
        ClientConfigPreview(
            target: target,
            files: self.clientConfigFileService.managedFileURLs(for: target).map {
                ClientConfigFileTextSnapshot(
                    path: $0.path,
                    exists: FileManager.default.fileExists(atPath: $0.path),
                    content: "",
                    language: self.clientConfigManagerLanguage(for: $0),
                    errorMessage: errorMessage
                )
            }
        )
    }

    private func clientConfigManagerLanguage(for url: URL) -> ClientConfigTextLanguage {
        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        case "toml":
            return .toml
        case "env":
            return .dotenv
        default:
            return url.lastPathComponent == ".env" ? .dotenv : .text
        }
    }

    private func revealClientConfigURLs(_ urls: [URL]) {
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existingURLs.isEmpty == false {
            NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
            return
        }

        if let firstParentDirectory = urls.first?.deletingLastPathComponent() {
            _ = NSWorkspace.shared.open(firstParentDirectory)
        }
    }

    private static func maskedClientConfigContent(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.maskedClientConfigLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func maskedClientConfigLine(_ line: String) -> String {
        let sensitiveKeys = [
            "OPENAI_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
        ]
        var updated = line
        for key in sensitiveKeys {
            updated = Self.maskedDotEnvValue(in: updated, key: key)
            updated = Self.maskedJSONStringValue(in: updated, key: key)
        }
        return updated
    }

    private static func maskedDotEnvValue(in line: String, key: String) -> String {
        guard let keyRange = line.range(of: "\(key)=") else { return line }
        let leading = line[..<keyRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard leading.isEmpty else { return line }
        return "\(line[..<keyRange.upperBound])********"
    }

    private static func maskedJSONStringValue(in line: String, key: String) -> String {
        guard let keyRange = line.range(of: "\"\(key)\"") else { return line }
        let afterKey = line[keyRange.upperBound...]
        guard let colonRange = afterKey.range(of: ":") else { return line }
        let afterColon = line[colonRange.upperBound...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return line }
        let valueStart = line.index(after: openQuote)
        guard let closeQuote = line[valueStart...].firstIndex(of: "\"") else { return line }
        return String(line[..<valueStart]) + "********" + String(line[closeQuote...])
    }
}
#endif
