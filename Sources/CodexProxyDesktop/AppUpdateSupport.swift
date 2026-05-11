#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation

@MainActor
extension DesktopAppModel {
    var appUpdateCurrentVersionText: String {
        RuntimeInfo.displayVersion
    }

    var appUpdateTitle: String {
        self.localized(zh: "软件更新", en: "Software Update")
    }

    var appUpdateSummaryText: String {
        switch self.appUpdateStatus {
        case .idle:
            return self.localized(zh: "检查 GitHub Releases 上的新版本。", en: "Check GitHub Releases for a newer version.")
        case .checking:
            return self.localized(zh: "正在检查最新版本…", en: "Checking for updates…")
        case .upToDate:
            return self.localized(zh: "当前已是最新版本。", en: "You are running the latest version.")
        case .updateAvailable(let package):
            return self.localized(
                zh: "发现新版本 \(package.versionText)，可立即下载并安装。",
                en: "Version \(package.versionText) is available and ready to download."
            )
        case .downloading(_, let progress):
            if let progress {
                return self.localized(
                    zh: "正在下载更新 \(Int(progress * 100))%…",
                    en: "Downloading update \(Int(progress * 100))%…"
                )
            }
            return self.localized(zh: "正在下载更新…", en: "Downloading update…")
        case .readyToInstall(let downloaded):
            return self.localized(
                zh: "新版本 \(downloaded.package.versionText) 已下载，安装会重启应用。",
                en: "Version \(downloaded.package.versionText) is downloaded. Installing will restart the app."
            )
        case .installing(let package):
            return self.localized(
                zh: "正在准备安装 \(package.versionText)…",
                en: "Preparing to install \(package.versionText)…"
            )
        case .failed(let message):
            return message
        }
    }

    var appUpdatePrimaryActionTitle: String {
        switch self.appUpdateStatus {
        case .checking:
            return self.localized(zh: "检查中…", en: "Checking…")
        case .updateAvailable:
            return self.localized(zh: "下载并安装", en: "Download & Install")
        case .downloading:
            return self.localized(zh: "下载中…", en: "Downloading…")
        case .readyToInstall:
            return self.localized(zh: "安装并重启", en: "Install & Relaunch")
        case .installing:
            return self.localized(zh: "安装中…", en: "Installing…")
        case .idle, .upToDate, .failed:
            return self.localized(zh: "检查更新", en: "Check for Updates")
        }
    }

    var appUpdateCanRunPrimaryAction: Bool {
        switch self.appUpdateStatus {
        case .checking, .downloading, .installing:
            return false
        case .idle, .upToDate, .updateAvailable, .readyToInstall, .failed:
            return true
        }
    }

    var appUpdateSecondaryActionTitle: String? {
        switch self.appUpdateStatus {
        case .updateAvailable(let package):
            return package.release.htmlURL == nil ? nil : self.localized(zh: "打开发布页", en: "Open Release Page")
        case .readyToInstall(let downloaded):
            return downloaded.package.release.htmlURL == nil ? nil : self.localized(zh: "打开发布页", en: "Open Release Page")
        default:
            return nil
        }
    }

    var appUpdateStatusPillTone: StatusPill.Tone {
        switch self.appUpdateStatus {
        case .idle:
            return .neutral
        case .checking, .downloading, .installing:
            return .warning
        case .upToDate, .readyToInstall:
            return .success
        case .updateAvailable:
            return .accent
        case .failed:
            return .danger
        }
    }

    var appUpdateStatusPillText: String {
        switch self.appUpdateStatus {
        case .idle:
            return self.text(.statusReady)
        case .checking:
            return self.text(.statusChecking)
        case .upToDate:
            return self.text(.statusCurrent)
        case .updateAvailable:
            return self.localized(zh: "有新版本", en: "Update Available")
        case .downloading:
            return self.localized(zh: "下载中", en: "Downloading")
        case .readyToInstall:
            return self.localized(zh: "待安装", en: "Ready")
        case .installing:
            return self.localized(zh: "安装中", en: "Installing")
        case .failed:
            return self.text(.statusFailed)
        }
    }

    var appUpdateLatestVersionText: String {
        switch self.appUpdateStatus {
        case .upToDate(let release):
            return release.versionText
        case .updateAvailable(let package), .downloading(let package, _), .installing(let package):
            return package.versionText
        case .readyToInstall(let downloaded):
            return downloaded.package.versionText
        case .idle, .checking, .failed:
            return self.text(.statusUnknown)
        }
    }

    var appUpdateReleaseNotesPreview: String? {
        let notes: String
        switch self.appUpdateStatus {
        case .updateAvailable(let package), .downloading(let package, _), .installing(let package):
            notes = package.releaseNotes
        case .readyToInstall(let downloaded):
            notes = downloaded.package.releaseNotes
        case .upToDate(let release):
            notes = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        case .idle, .checking, .failed:
            return nil
        }

        guard notes.isEmpty == false else { return nil }
        return Helpers.truncate(notes.replacingOccurrences(of: "\r\n", with: "\n"), limit: 420)
    }

    func updateAutomaticUpdateChecksEnabled(_ isEnabled: Bool) {
        guard self.preferences.automaticUpdateChecksEnabled != isEnabled else { return }
        self.updatePreferences(showSuccessNotice: false) { preferences in
            preferences.automaticUpdateChecksEnabled = isEnabled
        }
    }

    func runAppUpdatePrimaryAction() {
        switch self.appUpdateStatus {
        case .updateAvailable(let package):
            self.startDownloadAndInstall(package: package, shouldPromptBeforeInstall: false)
        case .readyToInstall(let downloaded):
            self.installDownloadedUpdate(downloaded)
        case .idle, .upToDate, .failed:
            self.checkForAppUpdates(isAutomatic: false)
        case .checking, .downloading, .installing:
            return
        }
    }

    func openAppUpdateReleasePage() {
        let url: URL?
        switch self.appUpdateStatus {
        case .updateAvailable(let package), .downloading(let package, _), .installing(let package):
            url = package.release.htmlURL
        case .readyToInstall(let downloaded):
            url = downloaded.package.release.htmlURL
        case .upToDate(let release):
            url = release.htmlURL
        case .idle, .checking, .failed:
            url = URL(string: "https://github.com/shiguanghuxian/aI-coding-proxy/releases")
        }

        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func checkForAppUpdates(isAutomatic: Bool) {
        guard self.canStartUpdateCheck(isAutomatic: isAutomatic) else { return }
        self.appUpdateTask?.cancel()
        self.appUpdateStatus = .checking

        let now = self.appUpdateNowProvider()
        if isAutomatic {
            self.updatePreferences(showSuccessNotice: false) { preferences in
                preferences.lastUpdateCheckAt = now
            }
        }

        self.appUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.appUpdateService.checkForUpdate(
                    currentVersion: RuntimeInfo.releaseVersion,
                    architecture: .current
                )
                self.handleAppUpdateCheckResult(result, isAutomatic: isAutomatic)
            } catch {
                self.handleAppUpdateFailure(error, isAutomatic: isAutomatic)
            }
        }
    }

    func checkForAppUpdatesIfNeededOnLaunch() {
        guard self.preferences.automaticUpdateChecksEnabled else { return }
        guard self.shouldRunAutomaticUpdateCheck(now: self.appUpdateNowProvider()) else { return }
        self.checkForAppUpdates(isAutomatic: true)
    }

    func shouldRunAutomaticUpdateCheck(now: Date) -> Bool {
        guard let lastCheck = self.preferences.lastUpdateCheckAt else { return true }
        return now.timeIntervalSince(lastCheck) >= self.appUpdateAutoCheckInterval
    }

    private func canStartUpdateCheck(isAutomatic: Bool) -> Bool {
        switch self.appUpdateStatus {
        case .checking, .downloading, .installing:
            return false
        default:
            return isAutomatic ? self.preferences.automaticUpdateChecksEnabled : true
        }
    }

    private func handleAppUpdateCheckResult(_ result: AppUpdateCheckResult, isAutomatic: Bool) {
        switch result {
        case .upToDate(let release):
            self.appUpdateStatus = .upToDate(release)
            if isAutomatic == false {
                self.publishBanner(
                    .success,
                    title: self.localized(zh: "当前已是最新版本", en: "You are up to date"),
                    detail: self.localized(
                        zh: "当前版本 \(RuntimeInfo.displayVersion)，最新版本 \(release.versionText)。",
                        en: "Current version \(RuntimeInfo.displayVersion), latest version \(release.versionText)."
                    )
                )
            }
        case .updateAvailable(let package):
            self.appUpdateStatus = .updateAvailable(package)
            self.presentUpdateAvailablePrompt(package)
        }
    }

    private func handleAppUpdateFailure(_ error: Error, isAutomatic: Bool) {
        let message = self.localizedUpdateErrorMessage(error)
        self.appUpdateStatus = .failed(message)
        if isAutomatic == false {
            self.publishBanner(
                .error,
                title: self.localized(zh: "检查更新失败", en: "Update check failed"),
                detail: message
            )
        }
    }

    private func localizedUpdateErrorMessage(_ error: Error) -> String {
        if let updateError = error as? AppUpdateServiceError,
           case .invalidHTTPStatus(let httpError) = updateError {
            return self.localizedHTTPUpdateErrorMessage(httpError)
        }

        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else {
            return self.localized(zh: "请稍后再试，或打开 GitHub Releases 手动下载。", en: "Try again later, or open GitHub Releases to download manually.")
        }
        return raw
    }

    private func localizedHTTPUpdateErrorMessage(_ error: AppUpdateHTTPError) -> String {
        if error.statusCode == 403, error.isRateLimited {
            let retryText: String
            if let retryDate = error.retryDate {
                retryText = self.localized(
                    zh: "可在 \(FixedDisplayDateTimeFormat.string(from: retryDate)) 后重试。",
                    en: "Try again after \(FixedDisplayDateTimeFormat.string(from: retryDate))."
                )
            } else {
                retryText = self.localized(zh: "请稍后再试。", en: "Try again later.")
            }

            return self.joinUpdateErrorLines([
                self.localized(
                    zh: "GitHub API 访问频率受限，暂时无法检查更新。",
                    en: "GitHub API rate limit was reached, so updates cannot be checked right now."
                ),
                retryText,
                self.localized(
                    zh: "你也可以打开 GitHub Releases 页面手动下载最新版本。",
                    en: "You can also open GitHub Releases and download the latest version manually."
                ),
                self.updateHTTPDiagnosticLine(error),
            ])
        }

        if error.statusCode == 403 {
            return self.joinUpdateErrorLines([
                self.localized(
                    zh: "当前网络出口被 GitHub 拒绝，可能需要切换代理、网络，或稍后重试。",
                    en: "GitHub rejected the current network route. Try switching proxy/network or retry later."
                ),
                self.localized(
                    zh: "如果浏览器能打开发布页，也可以先手动下载更新包。",
                    en: "If the release page opens in your browser, you can download the update package manually."
                ),
                self.updateHTTPDiagnosticLine(error),
            ])
        }

        return self.joinUpdateErrorLines([
            self.localized(
                zh: "GitHub 返回 HTTP \(error.statusCode)，暂时无法检查更新。",
                en: "GitHub returned HTTP \(error.statusCode), so the update check could not finish."
            ),
            self.updateHTTPDiagnosticLine(error),
        ])
    }

    private func updateHTTPDiagnosticLine(_ error: AppUpdateHTTPError) -> String? {
        var parts: [String] = []
        if let message = error.message?.trimmingCharacters(in: .whitespacesAndNewlines), message.isEmpty == false {
            parts.append(message)
        }
        if let requestID = error.requestID?.trimmingCharacters(in: .whitespacesAndNewlines), requestID.isEmpty == false {
            parts.append("GitHub Request ID: \(requestID)")
        }
        guard parts.isEmpty == false else { return nil }
        return parts.joined(separator: "\n")
    }

    private func joinUpdateErrorLines(_ lines: [String?]) -> String {
        lines.compactMap { line in
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n\n")
    }

    private func presentUpdateAvailablePrompt(_ package: AppUpdatePackage) {
        switch self.confirmInstallUpdate(package) {
        case .install:
            self.startDownloadAndInstall(package: package, shouldPromptBeforeInstall: false)
        case .openReleasePage:
            self.openAppUpdateReleasePage()
        case .later:
            return
        }
    }

    private func confirmInstallUpdate(_ package: AppUpdatePackage) -> AppUpdatePromptDecision {
        if let confirmInstallUpdateHandler {
            return confirmInstallUpdateHandler(package)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = self.localized(
            zh: "AI Coding Proxy \(package.versionText) 可用",
            en: "AI Coding Proxy \(package.versionText) is available"
        )
        alert.informativeText = self.updatePromptInformativeText(for: package)
        alert.addButton(withTitle: self.localized(zh: "下载并安装", en: "Download & Install"))
        alert.addButton(withTitle: self.localized(zh: "稍后提醒", en: "Later"))
        if package.release.htmlURL != nil {
            alert.addButton(withTitle: self.localized(zh: "打开发布页", en: "Open Release Page"))
        }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return .install
        }
        if response == .alertThirdButtonReturn {
            return .openReleasePage
        }
        return .later
    }

    private func updatePromptInformativeText(for package: AppUpdatePackage) -> String {
        var lines = [
            self.localized(
                zh: "当前版本：\(RuntimeInfo.displayVersion)",
                en: "Current version: \(RuntimeInfo.displayVersion)"
            ),
            self.localized(
                zh: "最新版本：\(package.versionText)",
                en: "Latest version: \(package.versionText)"
            ),
            self.localized(
                zh: "安装包：\(package.asset.formattedSize)",
                en: "Package: \(package.asset.formattedSize)"
            ),
        ]
        if let publishedAt = package.release.publishedAt {
            lines.append(
                self.localized(
                    zh: "发布时间：\(FixedDisplayDateTimeFormat.string(from: publishedAt))",
                    en: "Published: \(FixedDisplayDateTimeFormat.string(from: publishedAt))"
                )
            )
        }
        let notes = Helpers.truncate(package.releaseNotes, limit: 320)
        if notes.isEmpty == false {
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    private func startDownloadAndInstall(package: AppUpdatePackage, shouldPromptBeforeInstall: Bool) {
        self.appUpdateTask?.cancel()
        self.appUpdateStatus = .downloading(package, progress: nil)
        self.appUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let downloaded = try await self.appUpdateService.download(package: package) { progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading(let currentPackage, _) = self?.appUpdateStatus,
                              currentPackage == package
                        else {
                            return
                        }
                        self?.appUpdateStatus = .downloading(package, progress: progress)
                    }
                }
                self.appUpdateStatus = .readyToInstall(downloaded)
                if shouldPromptBeforeInstall {
                    self.presentUpdateAvailablePrompt(package)
                } else {
                    self.installDownloadedUpdate(downloaded)
                }
            } catch {
                self.handleAppUpdateFailure(error, isAutomatic: false)
            }
        }
    }

    private func installDownloadedUpdate(_ downloaded: AppUpdateDownloadedPackage) {
        self.appUpdateTask?.cancel()
        self.appUpdateStatus = .installing(downloaded.package)
        self.appUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let installation = try await self.appUpdateInstaller.prepareInstallation(
                    downloadedPackage: downloaded,
                    currentAppURL: self.appUpdateCurrentAppURLProvider()
                )
                try await self.appUpdateInstaller.launchInstallation(installation)
                self.appUpdateTerminateHandler()
            } catch {
                self.handleAppUpdateFailure(error, isAutomatic: false)
            }
        }
    }
}
#endif
