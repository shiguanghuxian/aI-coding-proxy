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

enum ClientConfigPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case current
    case proposed

    var id: String { self.rawValue }
}

enum ClientConfigBackupDrawerMode: String, Equatable {
    case list
    case detail
}

enum ClientConfigPreviewFileChangeKind: Equatable, Sendable {
    case readFailed
    case willCreate
    case willUpdate
    case unchanged
}

struct ClientConfigPreviewFilePresentation: Identifiable, Equatable, Sendable {
    var file: ClientConfigFileTextSnapshot
    var changeKind: ClientConfigPreviewFileChangeKind

    var id: String { self.file.path }
}

struct ClientConfigPreviewChangeSummaryCounts: Equatable, Sendable {
    var createCount: Int = 0
    var updateCount: Int = 0
    var unchangedCount: Int = 0
    var failedCount: Int = 0

    var changedFileCount: Int {
        self.createCount + self.updateCount
    }
}

struct ClientConfigPreviewDerivedState: Equatable, Sendable {
    var filePresentations: [ClientConfigPreviewFilePresentation]
}

struct ClientConfigManagerState: Equatable {
    var target: ClientConfigTarget = .codex
    var inspections: [ClientConfigTarget: ClientConfigInspection] = [:]
    var backups: [ClientConfigBackupRecord] = []
    var loadedBackupTargets: Set<ClientConfigTarget> = []
    var selectedProxyAPIKeyIDs: [ClientConfigTarget: String] = [:]
    var operation: ClientConfigManagerOperation = .idle
    var previewMode: ClientConfigPreviewMode = .proposed
    var currentPreviews: [ClientConfigTarget: ClientConfigPreview] = [:]
    var proposedPreviews: [ClientConfigTarget: ClientConfigPreview] = [:]
    var previewRevision = 0
    var derivedPreviewStates: [String: ClientConfigPreviewDerivedState] = [:]
    var changeSummaryCounts: [ClientConfigTarget: ClientConfigPreviewChangeSummaryCounts] = [:]
    var displayTexts: [String: String] = [:]
    var selectedPreviewFilePaths: [String: String] = [:]
    var previewRevealsSecrets = false
    var pendingRestoreBackup: ClientConfigBackupRecord?
    var isRestoreConfirmationPresented = false
    var isBackupDrawerPresented = false
    var backupDrawerMode: ClientConfigBackupDrawerMode = .list
    var backupDetail: ClientConfigBackupDetail?
    var backupDisplayTexts: [String: String] = [:]
    var loadedTargets: Set<ClientConfigTarget> = []
}

struct ClientConfigManagerRenderState: Equatable {
    var target: ClientConfigTarget
    var operation: ClientConfigManagerOperation
    var previewMode: ClientConfigPreviewMode
    var previewRevision: Int
    var previewRevealsSecrets: Bool
    var inspection: ClientConfigInspection
    var filePresentations: [ClientConfigPreviewFilePresentation]
    var selectedPreviewFilePresentation: ClientConfigPreviewFilePresentation?
    var selectedDisplayText: String?
    var selectedTextIdentity: String?
    var changeSummaryText: String
    var changedFileCount: Int
    var isBackupDrawerPresented: Bool
    var backupDrawerMode: ClientConfigBackupDrawerMode
    var backupDetail: ClientConfigBackupDetail?
    var visibleBackups: [ClientConfigBackupRecord]
}

private struct ClientConfigManagerRefreshPayload: Sendable {
    var target: ClientConfigTarget
    var inspection: ClientConfigInspection
    var currentPreview: ClientConfigPreview
    var proposedPreview: ClientConfigPreview
}

@MainActor
extension DesktopAppModel {
    private func updateClientConfigManagerState(_ update: (inout ClientConfigManagerState) -> Void) {
        var state = self.clientConfigManagerState
        update(&state)
        if state != self.clientConfigManagerState {
            self.clientConfigManagerState = state
        }
    }

    var clientConfigManagerTarget: ClientConfigTarget {
        get { self.clientConfigManagerState.target }
        set {
            self.updateClientConfigManagerState { state in
                state.target = newValue
            }
        }
    }

    var clientConfigManagerInspections: [ClientConfigTarget: ClientConfigInspection] {
        get { self.clientConfigManagerState.inspections }
        set {
            self.updateClientConfigManagerState { state in
                state.inspections = newValue
            }
        }
    }

    var clientConfigManagerBackups: [ClientConfigBackupRecord] {
        get { self.clientConfigManagerState.backups }
        set {
            self.updateClientConfigManagerState { state in
                state.backups = newValue
            }
        }
    }

    var clientConfigManagerSelectedProxyAPIKeyIDs: [ClientConfigTarget: String] {
        get { self.clientConfigManagerState.selectedProxyAPIKeyIDs }
        set {
            self.updateClientConfigManagerState { state in
                state.selectedProxyAPIKeyIDs = newValue
            }
        }
    }

    var clientConfigManagerOperation: ClientConfigManagerOperation {
        get { self.clientConfigManagerState.operation }
        set {
            self.updateClientConfigManagerState { state in
                state.operation = newValue
            }
        }
    }

    var clientConfigManagerPreviewMode: ClientConfigPreviewMode {
        get { self.clientConfigManagerState.previewMode }
        set {
            self.updateClientConfigManagerState { state in
                state.previewMode = newValue
                state.previewRevision &+= 1
                self.rebuildClientConfigManagerDerivedPreviewCache(in: &state)
            }
        }
    }

    var clientConfigManagerCurrentPreviews: [ClientConfigTarget: ClientConfigPreview] {
        get { self.clientConfigManagerState.currentPreviews }
        set {
            self.updateClientConfigManagerState { state in
                state.currentPreviews = newValue
                self.rebuildClientConfigManagerDerivedPreviewCache(in: &state)
            }
        }
    }

    var clientConfigManagerProposedPreviews: [ClientConfigTarget: ClientConfigPreview] {
        get { self.clientConfigManagerState.proposedPreviews }
        set {
            self.updateClientConfigManagerState { state in
                state.proposedPreviews = newValue
                self.rebuildClientConfigManagerDerivedPreviewCache(in: &state)
            }
        }
    }

    var clientConfigManagerPreviewRevision: Int {
        get { self.clientConfigManagerState.previewRevision }
        set {
            self.updateClientConfigManagerState { state in
                state.previewRevision = newValue
                self.rebuildClientConfigManagerDerivedPreviewCache(in: &state)
            }
        }
    }

    var clientConfigManagerDerivedPreviewStates: [String: ClientConfigPreviewDerivedState] {
        get { self.clientConfigManagerState.derivedPreviewStates }
        set {
            self.updateClientConfigManagerState { state in
                state.derivedPreviewStates = newValue
            }
        }
    }

    var clientConfigManagerChangeSummaryCounts: [ClientConfigTarget: ClientConfigPreviewChangeSummaryCounts] {
        get { self.clientConfigManagerState.changeSummaryCounts }
        set {
            self.updateClientConfigManagerState { state in
                state.changeSummaryCounts = newValue
            }
        }
    }

    var clientConfigManagerSelectedPreviewFilePaths: [String: String] {
        get { self.clientConfigManagerState.selectedPreviewFilePaths }
        set {
            self.updateClientConfigManagerState { state in
                state.selectedPreviewFilePaths = newValue
            }
        }
    }

    var clientConfigManagerPreviewRevealsSecrets: Bool {
        get { self.clientConfigManagerState.previewRevealsSecrets }
        set {
            self.updateClientConfigManagerState { state in
                state.previewRevealsSecrets = newValue
                state.previewRevision &+= 1
                self.rebuildClientConfigManagerDerivedPreviewCache(in: &state)
                self.rebuildClientConfigManagerBackupDisplayCache(in: &state)
            }
        }
    }

    var clientConfigManagerPendingRestoreBackup: ClientConfigBackupRecord? {
        get { self.clientConfigManagerState.pendingRestoreBackup }
        set {
            self.updateClientConfigManagerState { state in
                state.pendingRestoreBackup = newValue
            }
        }
    }

    var isClientConfigManagerRestoreConfirmationPresented: Bool {
        get { self.clientConfigManagerState.isRestoreConfirmationPresented }
        set {
            self.updateClientConfigManagerState { state in
                state.isRestoreConfirmationPresented = newValue
            }
        }
    }

    var isClientConfigBackupDrawerPresented: Bool {
        get { self.clientConfigManagerState.isBackupDrawerPresented }
        set {
            self.updateClientConfigManagerState { state in
                state.isBackupDrawerPresented = newValue
            }
        }
    }

    var clientConfigBackupDrawerMode: ClientConfigBackupDrawerMode {
        get { self.clientConfigManagerState.backupDrawerMode }
        set {
            self.updateClientConfigManagerState { state in
                state.backupDrawerMode = newValue
            }
        }
    }

    var clientConfigManagerBackupDetail: ClientConfigBackupDetail? {
        get { self.clientConfigManagerState.backupDetail }
        set {
            self.updateClientConfigManagerState { state in
                state.backupDetail = newValue
                self.rebuildClientConfigManagerBackupDisplayCache(in: &state)
            }
        }
    }

    var clientConfigManagerWindowTitle: String {
        self.localized(zh: "Codex/Claude 配置管理", en: "Codex/Claude Config Manager")
    }

    var actionOpenClientConfigManager: String {
        self.localized(zh: "Codex/Claude 配置管理", en: "Codex/Claude Config Manager")
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

    var clientConfigManagerRenderState: ClientConfigManagerRenderState {
        let state = self.clientConfigManagerState
        let target = state.target
        let mode = state.previewMode
        let inspection = self.clientConfigManagerInspection(for: target)
        let preview = self.clientConfigManagerPreview(for: target, mode: mode, in: state)
        let selectionKey = Self.clientConfigManagerPreviewSelectionKey(target: target, mode: mode)
        let selectedPath = state.selectedPreviewFilePaths[selectionKey]
        let selectedFile = selectedPath.flatMap { path in
            preview.files.first(where: { $0.path == path })
        } ?? preview.files.first
        let selectedPresentation = selectedFile.map { file in
            ClientConfigPreviewFilePresentation(
                file: file,
                changeKind: Self.clientConfigManagerFileChangeKind(
                    target: target,
                    path: file.path,
                    currentPreviews: state.currentPreviews,
                    proposedPreviews: state.proposedPreviews
                )
            )
        }
        let selectedDisplayText = selectedFile.map { file in
            let key = Self.clientConfigManagerPreviewTextKey(
                target: target,
                mode: mode,
                path: file.path,
                revealsSecrets: state.previewRevealsSecrets
            )
            return state.displayTexts[key]
                ?? Self.clientConfigManagerDisplayContent(for: file, revealsSecrets: state.previewRevealsSecrets)
        }
        let selectedTextIdentity = selectedFile.map { file in
            Self.clientConfigManagerPreviewTextIdentity(
                previewRevision: state.previewRevision,
                target: target,
                mode: mode,
                path: file.path,
                revealsSecrets: state.previewRevealsSecrets
            )
        }
        let visibleBackups = state.backups.filter { $0.target == target }

        return ClientConfigManagerRenderState(
            target: target,
            operation: state.operation,
            previewMode: mode,
            previewRevision: state.previewRevision,
            previewRevealsSecrets: state.previewRevealsSecrets,
            inspection: inspection,
            filePresentations: self.clientConfigManagerVisibleFilePresentations,
            selectedPreviewFilePresentation: selectedPresentation,
            selectedDisplayText: selectedDisplayText,
            selectedTextIdentity: selectedTextIdentity,
            changeSummaryText: self.clientConfigManagerChangeSummaryText,
            changedFileCount: self.clientConfigManagerChangedFileCount,
            isBackupDrawerPresented: state.isBackupDrawerPresented,
            backupDrawerMode: state.backupDrawerMode,
            backupDetail: state.backupDetail,
            visibleBackups: visibleBackups
        )
    }

    var clientConfigManagerVisibleBackups: [ClientConfigBackupRecord] {
        self.clientConfigManagerBackups.filter { $0.target == self.clientConfigManagerTarget }
    }

    var clientConfigManagerVisiblePreview: ClientConfigPreview {
        self.clientConfigManagerPreview(for: self.clientConfigManagerTarget, mode: self.clientConfigManagerPreviewMode)
    }

    var clientConfigManagerVisibleFilePresentations: [ClientConfigPreviewFilePresentation] {
        let key = Self.clientConfigManagerPreviewSelectionKey(
            target: self.clientConfigManagerTarget,
            mode: self.clientConfigManagerPreviewMode
        )
        if let cached = self.clientConfigManagerDerivedPreviewStates[key] {
            return cached.filePresentations
        }
        return Self.clientConfigManagerFilePresentations(
            target: self.clientConfigManagerTarget,
            preview: self.clientConfigManagerVisiblePreview,
            currentPreviews: self.clientConfigManagerCurrentPreviews,
            proposedPreviews: self.clientConfigManagerProposedPreviews
        )
    }

    var clientConfigManagerSelectedPreviewFile: ClientConfigFileTextSnapshot? {
        let preview = self.clientConfigManagerVisiblePreview
        let selectionKey = Self.clientConfigManagerPreviewSelectionKey(
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
        if let cached = self.clientConfigManagerVisibleFilePresentations.first(where: { $0.file.path == file.path }) {
            return cached
        }
        return ClientConfigPreviewFilePresentation(
            file: file,
            changeKind: self.clientConfigManagerFileChangeKind(target: self.clientConfigManagerTarget, path: file.path)
        )
    }

    var clientConfigManagerChangedFileCount: Int {
        if let counts = self.clientConfigManagerChangeSummaryCounts[self.clientConfigManagerTarget] {
            return counts.changedFileCount
        }
        return Self.clientConfigManagerChangeSummaryCounts(
            target: self.clientConfigManagerTarget,
            currentPreviews: self.clientConfigManagerCurrentPreviews,
            proposedPreviews: self.clientConfigManagerProposedPreviews
        ).changedFileCount
    }

    var clientConfigManagerChangeSummaryText: String {
        let counts = self.clientConfigManagerChangeSummaryCounts[self.clientConfigManagerTarget]
            ?? Self.clientConfigManagerChangeSummaryCounts(
                target: self.clientConfigManagerTarget,
                currentPreviews: self.clientConfigManagerCurrentPreviews,
                proposedPreviews: self.clientConfigManagerProposedPreviews
            )
        var parts: [String] = []
        if counts.createCount > 0 {
            parts.append(self.localized(zh: "\(counts.createCount) 个将创建", en: "\(counts.createCount) to create"))
        }
        if counts.updateCount > 0 {
            parts.append(self.localized(zh: "\(counts.updateCount) 个将更新", en: "\(counts.updateCount) to update"))
        }
        if counts.unchangedCount > 0 {
            parts.append(self.localized(zh: "\(counts.unchangedCount) 个无变化", en: "\(counts.unchangedCount) unchanged"))
        }
        if counts.failedCount > 0 {
            parts.append(self.localized(zh: "\(counts.failedCount) 个读取失败", en: "\(counts.failedCount) read failed"))
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
                    ClientConfigManagedFileState(path: $0.path, exists: false)
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
                zh: "当前没有启用中的本地 API Key。请先到代理页启用至少一把 Key。",
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
            zh: "写入到 \(self.clientConfigManagerTitle(for: resolvedTarget))",
            en: "Write To \(self.clientConfigManagerTitle(for: resolvedTarget))"
        )
    }

    var clientConfigManagerRevealFilesButtonTitle: String {
        self.localized(zh: "打开配置文件位置", en: "Reveal Config Files")
    }

    var clientConfigManagerViewBackupsButtonTitle: String {
        self.localized(zh: "查看可回退备份", en: "View Restorable Backups")
    }

    var clientConfigManagerRefreshStatusButtonTitle: String {
        self.localized(zh: "重新检测配置状态", en: "Refresh Config Status")
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
        self.updateClientConfigManagerState { state in
            state.selectedProxyAPIKeyIDs[resolvedTarget] = id
            state.previewRevision &+= 1
        }
        Task { await self.refreshClientConfigManagerState(showLoading: false, target: resolvedTarget, force: true) }
    }

    func clientConfigManagerSelectTarget(_ target: ClientConfigTarget) {
        self.updateClientConfigManagerState { state in
            state.target = target
            self.ensureClientConfigManagerSelection(for: target, in: &state)
        }
        Task { await self.refreshClientConfigManagerState(showLoading: false, target: target, force: false) }
    }

    func clientConfigManagerSelectPreviewFile(_ path: String?) {
        let key = Self.clientConfigManagerPreviewSelectionKey(
            target: self.clientConfigManagerTarget,
            mode: self.clientConfigManagerPreviewMode
        )
        self.updateClientConfigManagerState { state in
            state.selectedPreviewFilePaths[key] = path
        }
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
        let previewKey = Self.clientConfigManagerPreviewTextKey(
            target: self.clientConfigManagerTarget,
            mode: self.clientConfigManagerPreviewMode,
            path: file.path,
            revealsSecrets: self.clientConfigManagerPreviewRevealsSecrets
        )
        if let cached = self.clientConfigManagerState.displayTexts[previewKey] {
            return cached
        }
        if let detail = self.clientConfigManagerBackupDetail {
            let backupKey = Self.clientConfigManagerBackupTextKey(
                backupID: detail.id,
                path: file.path,
                revealsSecrets: self.clientConfigManagerPreviewRevealsSecrets
            )
            if let cached = self.clientConfigManagerState.backupDisplayTexts[backupKey] {
                return cached
            }
        }
        return Self.clientConfigManagerDisplayContent(
            for: file,
            revealsSecrets: self.clientConfigManagerPreviewRevealsSecrets
        )
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

    func enterClientConfigPageIfNeeded() {
        let target = self.clientConfigManagerTarget
        self.updateClientConfigManagerState { state in
            self.ensureClientConfigManagerSelection(for: target, in: &state)
        }
        if self.clientConfigManagerState.loadedTargets.contains(target) == false {
            Task { await self.refreshClientConfigManagerState(showLoading: true, target: target, force: false) }
        }
    }

    func openClientConfigManagerWindow() {
        if self.clientConfigManagerWindowController == nil {
            self.clientConfigManagerWindowController = self.clientConfigManagerWindowFactory(self)
        }
        self.updateClientConfigManagerState { state in
            self.ensureClientConfigManagerSelection(for: state.target, in: &state)
        }
        self.isClientConfigManagerPresented = true
        self.clientConfigManagerWindowController?.showWindow()
        Task { await self.refreshClientConfigManagerState(showLoading: true, target: self.clientConfigManagerTarget, force: false) }
    }

    func dismissClientConfigManagerWindow() {
        self.isClientConfigManagerPresented = false
        self.clientConfigManagerWindowController?.closeWindow()
    }

    func handleClientConfigManagerWindowDidClose() {
        self.isClientConfigManagerPresented = false
    }

    func presentClientConfigBackupDrawer() {
        let target = self.clientConfigManagerTarget
        self.updateClientConfigManagerState { state in
            state.backupDrawerMode = .list
            state.isBackupDrawerPresented = true
        }
        Task { await self.loadClientConfigManagerBackupsIfNeeded(target: target, force: false) }
    }

    func loadClientConfigManagerBackupsIfNeeded(
        target: ClientConfigTarget? = nil,
        force: Bool = false
    ) async {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        if force == false, self.clientConfigManagerState.loadedBackupTargets.contains(resolvedTarget) {
            return
        }

        self.clientConfigManagerBackupLoadGeneration &+= 1
        let generation = self.clientConfigManagerBackupLoadGeneration
        let service = self.clientConfigFileService
        let records = await Task.detached(priority: .utility) {
            service.listBackups(target: resolvedTarget)
        }.value

        guard generation == self.clientConfigManagerBackupLoadGeneration else {
            return
        }

        self.updateClientConfigManagerState { state in
            var merged = state.backups.filter { $0.target != resolvedTarget }
            merged.append(contentsOf: records)
            state.backups = merged.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id > $1.id
            }
            state.loadedBackupTargets.insert(resolvedTarget)
        }
    }

    func dismissClientConfigBackupDrawer() {
        self.updateClientConfigManagerState { state in
            state.isBackupDrawerPresented = false
            state.backupDrawerMode = .list
            state.backupDetail = nil
            state.backupDisplayTexts = [:]
        }
    }

    func returnToClientConfigBackupList() {
        self.updateClientConfigManagerState { state in
            state.backupDrawerMode = .list
            state.backupDetail = nil
            state.backupDisplayTexts = [:]
            state.isBackupDrawerPresented = true
        }
    }

    func refreshClientConfigManagerState(
        showLoading: Bool = false,
        target: ClientConfigTarget? = nil,
        force: Bool = true
    ) async {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        if force == false, self.clientConfigManagerState.loadedTargets.contains(resolvedTarget) {
            return
        }
        self.clientConfigManagerRefreshGeneration &+= 1
        let generation = self.clientConfigManagerRefreshGeneration
        if showLoading {
            self.updateClientConfigManagerState { state in
                state.operation = .loading
            }
        }

        let service = self.clientConfigFileService
        let availableProxyAPIKeys = self.clientConfigManagerAvailableProxyAPIKeys
        let selectedProxyAPIKeyIDs = self.clientConfigManagerSelectedProxyAPIKeyIDs
        let endpoints = self.clientConfigManagerEndpointBundle
        let missingKeyErrorMessage = self.localized(
            zh: "当前没有可用的本地 API Key。",
            en: "There is no enabled local API key."
        )
        let payload = await Task.detached(priority: .userInitiated) {
            Self.buildClientConfigManagerRefreshPayload(
                service: service,
                target: resolvedTarget,
                availableProxyAPIKeys: availableProxyAPIKeys,
                selectedProxyAPIKeyIDs: selectedProxyAPIKeyIDs,
                endpoints: endpoints,
                missingKeyErrorMessage: missingKeyErrorMessage
            )
        }.value

        guard generation == self.clientConfigManagerRefreshGeneration else {
            return
        }

        self.updateClientConfigManagerState { state in
            state.inspections[payload.target] = payload.inspection
            state.currentPreviews[payload.target] = payload.currentPreview
            state.proposedPreviews[payload.target] = payload.proposedPreview
            state.loadedTargets.insert(payload.target)
            self.ensureClientConfigManagerSelection(for: payload.target, in: &state)
            self.ensureClientConfigManagerPreviewSelection(target: payload.target, mode: .current, in: &state)
            self.ensureClientConfigManagerPreviewSelection(target: payload.target, mode: .proposed, in: &state)
            self.rebuildClientConfigManagerDerivedPreviewCache(in: &state)
            state.previewRevision &+= 1
            if showLoading, state.operation == .loading {
                state.operation = .idle
            }
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
            await self.refreshClientConfigManagerState(target: target, force: true)
            await self.loadClientConfigManagerBackupsIfNeeded(target: target, force: true)
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
            await self.refreshClientConfigManagerState(target: backup.target, force: true)
            await self.loadClientConfigManagerBackupsIfNeeded(target: backup.target, force: true)
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
        self.clientConfigManagerBackupLoadGeneration &+= 1
        let generation = self.clientConfigManagerBackupLoadGeneration
        let service = self.clientConfigFileService

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try service.loadBackupDetail(id: backup.id) }
            }.value

            guard generation == self.clientConfigManagerBackupLoadGeneration else {
                return
            }

            switch result {
            case .success(let detail):
                self.updateClientConfigManagerState { state in
                    state.backupDetail = detail
                    state.backupDrawerMode = .detail
                    state.isBackupDrawerPresented = true
                    self.rebuildClientConfigManagerBackupDisplayCache(in: &state)
                }
            case .failure(let error):
                self.present(error: error, context: .saveSettings)
            }
        }
    }

    private func ensureClientConfigManagerSelection(for target: ClientConfigTarget) {
        self.updateClientConfigManagerState { state in
            self.ensureClientConfigManagerSelection(for: target, in: &state)
        }
    }

    private func ensureClientConfigManagerSelection(
        for target: ClientConfigTarget,
        in state: inout ClientConfigManagerState
    ) {
        if let selectedID = state.selectedProxyAPIKeyIDs[target],
           self.clientConfigManagerAvailableProxyAPIKeys.contains(where: { $0.id == selectedID })
        {
            return
        }
        state.selectedProxyAPIKeyIDs[target] = self.clientConfigManagerAvailableProxyAPIKeys.first?.id
    }

    private func clientConfigManagerPreview(for target: ClientConfigTarget, mode: ClientConfigPreviewMode) -> ClientConfigPreview {
        self.clientConfigManagerPreview(for: target, mode: mode, in: self.clientConfigManagerState)
    }

    private func clientConfigManagerPreview(
        for target: ClientConfigTarget,
        mode: ClientConfigPreviewMode,
        in state: ClientConfigManagerState
    ) -> ClientConfigPreview {
        switch mode {
        case .current:
            return state.currentPreviews[target] ?? self.emptyClientConfigManagerPreview(for: target)
        case .proposed:
            return state.proposedPreviews[target] ?? self.emptyClientConfigManagerPreview(for: target)
        }
    }

    func clientConfigManagerFileChangeKind(
        target: ClientConfigTarget? = nil,
        path: String
    ) -> ClientConfigPreviewFileChangeKind {
        let resolvedTarget = target ?? self.clientConfigManagerTarget
        return Self.clientConfigManagerFileChangeKind(
            target: resolvedTarget,
            path: path,
            currentPreviews: self.clientConfigManagerCurrentPreviews,
            proposedPreviews: self.clientConfigManagerProposedPreviews
        )
    }

    private func ensureClientConfigManagerPreviewSelections() {
        for target in ClientConfigTarget.allCases {
            self.ensureClientConfigManagerPreviewSelection(target: target, mode: .current)
            self.ensureClientConfigManagerPreviewSelection(target: target, mode: .proposed)
        }
    }

    private func rebuildClientConfigManagerDerivedPreviewCache() {
        self.updateClientConfigManagerState { state in
            self.rebuildClientConfigManagerDerivedPreviewCache(in: &state)
        }
    }

    private func rebuildClientConfigManagerDerivedPreviewCache(in state: inout ClientConfigManagerState) {
        var states: [String: ClientConfigPreviewDerivedState] = [:]
        var summaryCounts: [ClientConfigTarget: ClientConfigPreviewChangeSummaryCounts] = [:]
        var displayTexts: [String: String] = [:]
        let targets = Set(state.currentPreviews.keys)
            .union(state.proposedPreviews.keys)
            .union(state.loadedTargets)
            .union([state.target])

        for target in targets {
            summaryCounts[target] = Self.clientConfigManagerChangeSummaryCounts(
                target: target,
                currentPreviews: state.currentPreviews,
                proposedPreviews: state.proposedPreviews
            )
            for mode in ClientConfigPreviewMode.allCases {
                let preview = self.clientConfigManagerPreview(for: target, mode: mode, in: state)
                let key = Self.clientConfigManagerPreviewSelectionKey(target: target, mode: mode)
                states[key] = ClientConfigPreviewDerivedState(
                    filePresentations: Self.clientConfigManagerFilePresentations(
                        target: target,
                        preview: preview,
                        currentPreviews: state.currentPreviews,
                        proposedPreviews: state.proposedPreviews
                    )
                )
                for file in preview.files {
                    displayTexts[
                        Self.clientConfigManagerPreviewTextKey(
                            target: target,
                            mode: mode,
                            path: file.path,
                            revealsSecrets: state.previewRevealsSecrets
                        )
                    ] = Self.clientConfigManagerDisplayContent(
                        for: file,
                        revealsSecrets: state.previewRevealsSecrets
                    )
                }
            }
        }

        state.derivedPreviewStates = states
        state.changeSummaryCounts = summaryCounts
        state.displayTexts = displayTexts
    }

    private func rebuildClientConfigManagerBackupDisplayCache(in state: inout ClientConfigManagerState) {
        guard let detail = state.backupDetail else {
            state.backupDisplayTexts = [:]
            return
        }
        var displayTexts: [String: String] = [:]
        for file in detail.files {
            displayTexts[
                Self.clientConfigManagerBackupTextKey(
                    backupID: detail.id,
                    path: file.path,
                    revealsSecrets: state.previewRevealsSecrets
                )
            ] = Self.clientConfigManagerDisplayContent(
                for: file,
                revealsSecrets: state.previewRevealsSecrets
            )
        }
        state.backupDisplayTexts = displayTexts
    }

    nonisolated private static func buildClientConfigManagerRefreshPayload(
        service: ClientConfigFileService,
        target: ClientConfigTarget,
        availableProxyAPIKeys: [ProxyAPIKeyRecord],
        selectedProxyAPIKeyIDs: [ClientConfigTarget: String],
        endpoints: ClientConfigEndpointBundle,
        missingKeyErrorMessage: String
    ) -> ClientConfigManagerRefreshPayload {
        let currentPreview = service.previewCurrentConfiguration(target: target)
        let proposedPreview: ClientConfigPreview
        if let selectedProxyAPIKey = Self.selectedClientConfigProxyAPIKey(
            target: target,
            availableProxyAPIKeys: availableProxyAPIKeys,
            selectedProxyAPIKeyIDs: selectedProxyAPIKeyIDs
        ) {
            do {
                proposedPreview = try service.previewProposedConfiguration(
                    target: target,
                    proxyAPIKey: selectedProxyAPIKey,
                    endpoints: endpoints
                )
            } catch {
                proposedPreview = Self.errorClientConfigManagerPreview(
                    service: service,
                    target: target,
                    errorMessage: error.localizedDescription
                )
            }
        } else {
            proposedPreview = Self.errorClientConfigManagerPreview(
                service: service,
                target: target,
                errorMessage: missingKeyErrorMessage
            )
        }

        return ClientConfigManagerRefreshPayload(
            target: target,
            inspection: service.inspect(target: target, availableProxyAPIKeys: availableProxyAPIKeys),
            currentPreview: currentPreview,
            proposedPreview: proposedPreview
        )
    }

    nonisolated private static func selectedClientConfigProxyAPIKey(
        target: ClientConfigTarget,
        availableProxyAPIKeys: [ProxyAPIKeyRecord],
        selectedProxyAPIKeyIDs: [ClientConfigTarget: String]
    ) -> ProxyAPIKeyRecord? {
        if let selectedID = selectedProxyAPIKeyIDs[target],
           let matched = availableProxyAPIKeys.first(where: { $0.id == selectedID })
        {
            return matched
        }
        return availableProxyAPIKeys.first
    }

    nonisolated private static func clientConfigManagerFilePresentations(
        target: ClientConfigTarget,
        preview: ClientConfigPreview,
        currentPreviews: [ClientConfigTarget: ClientConfigPreview],
        proposedPreviews: [ClientConfigTarget: ClientConfigPreview]
    ) -> [ClientConfigPreviewFilePresentation] {
        preview.files.map { file in
            ClientConfigPreviewFilePresentation(
                file: file,
                changeKind: Self.clientConfigManagerFileChangeKind(
                    target: target,
                    path: file.path,
                    currentPreviews: currentPreviews,
                    proposedPreviews: proposedPreviews
                )
            )
        }
    }

    nonisolated private static func clientConfigManagerChangeSummaryCounts(
        target: ClientConfigTarget,
        currentPreviews: [ClientConfigTarget: ClientConfigPreview],
        proposedPreviews: [ClientConfigTarget: ClientConfigPreview]
    ) -> ClientConfigPreviewChangeSummaryCounts {
        var counts = ClientConfigPreviewChangeSummaryCounts()
        for file in proposedPreviews[target]?.files ?? [] {
            switch Self.clientConfigManagerFileChangeKind(
                target: target,
                path: file.path,
                currentPreviews: currentPreviews,
                proposedPreviews: proposedPreviews
            ) {
            case .willCreate:
                counts.createCount += 1
            case .willUpdate:
                counts.updateCount += 1
            case .unchanged:
                counts.unchangedCount += 1
            case .readFailed:
                counts.failedCount += 1
            }
        }
        return counts
    }

    nonisolated private static func clientConfigManagerFileChangeKind(
        target: ClientConfigTarget,
        path: String,
        currentPreviews: [ClientConfigTarget: ClientConfigPreview],
        proposedPreviews: [ClientConfigTarget: ClientConfigPreview]
    ) -> ClientConfigPreviewFileChangeKind {
        let current = currentPreviews[target]?.files.first { $0.path == path }
        let proposed = proposedPreviews[target]?.files.first { $0.path == path }

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

    nonisolated private static func errorClientConfigManagerPreview(
        service: ClientConfigFileService,
        target: ClientConfigTarget,
        errorMessage: String
    ) -> ClientConfigPreview {
        ClientConfigPreview(
            target: target,
            files: service.managedFileURLs(for: target).map {
                ClientConfigFileTextSnapshot(
                    path: $0.path,
                    exists: false,
                    content: "",
                    language: Self.clientConfigManagerTextLanguage(for: $0),
                    errorMessage: errorMessage
                )
            }
        )
    }

    nonisolated private static func clientConfigManagerTextLanguage(for url: URL) -> ClientConfigTextLanguage {
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

    private func ensureClientConfigManagerPreviewSelection(target: ClientConfigTarget, mode: ClientConfigPreviewMode) {
        self.updateClientConfigManagerState { state in
            self.ensureClientConfigManagerPreviewSelection(target: target, mode: mode, in: &state)
        }
    }

    private func ensureClientConfigManagerPreviewSelection(
        target: ClientConfigTarget,
        mode: ClientConfigPreviewMode,
        in state: inout ClientConfigManagerState
    ) {
        let preview = self.clientConfigManagerPreview(for: target, mode: mode, in: state)
        let key = Self.clientConfigManagerPreviewSelectionKey(target: target, mode: mode)
        if let selectedPath = state.selectedPreviewFilePaths[key],
           preview.files.contains(where: { $0.path == selectedPath })
        {
            return
        }
        state.selectedPreviewFilePaths[key] = preview.files.first?.path
    }

    nonisolated private static func clientConfigManagerPreviewSelectionKey(
        target: ClientConfigTarget,
        mode: ClientConfigPreviewMode
    ) -> String {
        "\(target.rawValue):\(mode.rawValue)"
    }

    nonisolated private static func clientConfigManagerPreviewTextKey(
        target: ClientConfigTarget,
        mode: ClientConfigPreviewMode,
        path: String,
        revealsSecrets: Bool
    ) -> String {
        "preview|\(target.rawValue)|\(mode.rawValue)|\(path)|\(revealsSecrets ? "raw" : "masked")"
    }

    nonisolated private static func clientConfigManagerBackupTextKey(
        backupID: String,
        path: String,
        revealsSecrets: Bool
    ) -> String {
        "backup|\(backupID)|\(path)|\(revealsSecrets ? "raw" : "masked")"
    }

    nonisolated private static func clientConfigManagerPreviewTextIdentity(
        previewRevision: Int,
        target: ClientConfigTarget,
        mode: ClientConfigPreviewMode,
        path: String,
        revealsSecrets: Bool
    ) -> String {
        [
            "preview",
            "\(previewRevision)",
            target.rawValue,
            mode.rawValue,
            path,
            revealsSecrets ? "reveal" : "masked",
        ].joined(separator: "|")
    }

    nonisolated private static func clientConfigManagerDisplayContent(
        for file: ClientConfigFileTextSnapshot,
        revealsSecrets: Bool
    ) -> String {
        if let errorMessage = file.errorMessage, !errorMessage.isEmpty, file.content.isEmpty {
            return errorMessage
        }
        guard revealsSecrets == false else {
            return file.content
        }
        return Self.maskedClientConfigContent(file.content)
    }

    private func emptyClientConfigManagerPreview(for target: ClientConfigTarget) -> ClientConfigPreview {
        ClientConfigPreview(
            target: target,
            files: self.clientConfigFileService.managedFileURLs(for: target).map {
                ClientConfigFileTextSnapshot(
                    path: $0.path,
                    exists: false,
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
                    exists: false,
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

    nonisolated private static func maskedClientConfigContent(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.maskedClientConfigLine(String($0)) }
            .joined(separator: "\n")
    }

    nonisolated private static func maskedClientConfigLine(_ line: String) -> String {
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

    nonisolated private static func maskedDotEnvValue(in line: String, key: String) -> String {
        guard let keyRange = line.range(of: "\(key)=") else { return line }
        let leading = line[..<keyRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard leading.isEmpty else { return line }
        return "\(line[..<keyRange.upperBound])********"
    }

    nonisolated private static func maskedJSONStringValue(in line: String, key: String) -> String {
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
