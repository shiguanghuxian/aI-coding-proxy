#if os(macOS)
import AppKit
import Foundation

enum AppUpdateInstallerError: LocalizedError, Equatable {
    case currentAppUnavailable
    case currentAppNotWritable(String)
    case invalidPackage
    case extractedAppNotFound
    case multipleExtractedApps
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .currentAppUnavailable:
            return "The current app bundle could not be located."
        case .currentAppNotWritable(let path):
            return "The app cannot be updated in place because its folder is not writable: \(path)"
        case .invalidPackage:
            return "The downloaded update package is not a valid zip archive."
        case .extractedAppNotFound:
            return "The update package did not contain AI Coding Proxy.app."
        case .multipleExtractedApps:
            return "The update package contained more than one app bundle."
        case .launchFailed(let detail):
            return "Could not start the update installer: \(detail)"
        }
    }
}

struct AppUpdatePreparedInstallation: Sendable, Equatable {
    let downloadedPackage: AppUpdateDownloadedPackage
    let scriptURL: URL
    let currentAppURL: URL
    let extractedAppURL: URL
    let backupURL: URL
}

@MainActor
protocol AppUpdateInstalling {
    func prepareInstallation(
        downloadedPackage: AppUpdateDownloadedPackage,
        currentAppURL: URL?
    ) async throws -> AppUpdatePreparedInstallation

    func launchInstallation(_ installation: AppUpdatePreparedInstallation) async throws
}

struct AppUpdateInstaller: AppUpdateInstalling {
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let processIdentifierProvider: @Sendable () -> Int32

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processIdentifierProvider: @escaping @Sendable () -> Int32 = { ProcessInfo.processInfo.processIdentifier }
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.processIdentifierProvider = processIdentifierProvider
    }

    func prepareInstallation(
        downloadedPackage: AppUpdateDownloadedPackage,
        currentAppURL providedCurrentAppURL: URL? = Bundle.main.bundleURL
    ) async throws -> AppUpdatePreparedInstallation {
        guard let currentAppURL = Self.normalizedAppBundleURL(providedCurrentAppURL) else {
            throw AppUpdateInstallerError.currentAppUnavailable
        }

        let parentDirectory = currentAppURL.deletingLastPathComponent()
        guard self.fileManager.isWritableFile(atPath: parentDirectory.path) else {
            throw AppUpdateInstallerError.currentAppNotWritable(parentDirectory.path)
        }

        let workDirectory = self.temporaryDirectory
            .appendingPathComponent("ai-coding-proxy-install-\(UUID().uuidString)", isDirectory: true)
        let extractDirectory = workDirectory.appendingPathComponent("expanded", isDirectory: true)
        try self.fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

        try await Self.runProcess("/usr/bin/ditto", ["-x", "-k", downloadedPackage.fileURL.path, extractDirectory.path])
        let extractedAppURL = try self.findExtractedApp(in: extractDirectory)
        let backupURL = parentDirectory.appendingPathComponent(
            "\(currentAppURL.deletingPathExtension().lastPathComponent).previous-update-\(Self.timestamp()).app"
        )
        let scriptURL = workDirectory.appendingPathComponent("install-update.sh")
        try self.writeInstallerScript(
            scriptURL: scriptURL,
            currentAppURL: currentAppURL,
            extractedAppURL: extractedAppURL,
            backupURL: backupURL
        )

        return AppUpdatePreparedInstallation(
            downloadedPackage: downloadedPackage,
            scriptURL: scriptURL,
            currentAppURL: currentAppURL,
            extractedAppURL: extractedAppURL,
            backupURL: backupURL
        )
    }

    func launchInstallation(_ installation: AppUpdatePreparedInstallation) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            installation.scriptURL.path,
            String(self.processIdentifierProvider()),
        ]
        do {
            try process.run()
        } catch {
            throw AppUpdateInstallerError.launchFailed(error.localizedDescription)
        }
    }

    private func findExtractedApp(in extractDirectory: URL) throws -> URL {
        guard let enumerator = self.fileManager.enumerator(
            at: extractDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AppUpdateInstallerError.invalidPackage
        }

        var appURLs: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "app" else { continue }
            appURLs.append(url)
            enumerator.skipDescendants()
        }

        guard appURLs.isEmpty == false else {
            throw AppUpdateInstallerError.extractedAppNotFound
        }
        guard appURLs.count == 1 else {
            throw AppUpdateInstallerError.multipleExtractedApps
        }
        let appURL = appURLs[0]
        guard appURL.lastPathComponent == "AI Coding Proxy.app" else {
            throw AppUpdateInstallerError.extractedAppNotFound
        }
        guard self.fileManager.fileExists(
            atPath: appURL.appendingPathComponent("Contents/MacOS/CodexProxyDesktop").path
        ) else {
            throw AppUpdateInstallerError.invalidPackage
        }
        return appURL
    }

    private func writeInstallerScript(
        scriptURL: URL,
        currentAppURL: URL,
        extractedAppURL: URL,
        backupURL: URL
    ) throws {
        let script = """
        #!/bin/bash
        set -euo pipefail

        CURRENT_PID="$1"
        CURRENT_APP=\(Self.shellQuoted(currentAppURL.path))
        NEW_APP=\(Self.shellQuoted(extractedAppURL.path))
        BACKUP_APP=\(Self.shellQuoted(backupURL.path))

        while /bin/kill -0 "$CURRENT_PID" >/dev/null 2>&1; do
          /bin/sleep 0.25
        done

        if [[ ! -d "$NEW_APP" ]]; then
          /usr/bin/osascript -e 'display alert "AI Coding Proxy 更新失败" message "下载的更新包中没有找到新的应用。"' >/dev/null 2>&1 || true
          exit 1
        fi

        rm -rf "$BACKUP_APP"
        if [[ -d "$CURRENT_APP" ]]; then
          /bin/mv "$CURRENT_APP" "$BACKUP_APP"
        fi

        if /bin/mv "$NEW_APP" "$CURRENT_APP"; then
          /usr/bin/open "$CURRENT_APP"
          rm -rf "$BACKUP_APP"
          exit 0
        fi

        rm -rf "$CURRENT_APP"
        if [[ -d "$BACKUP_APP" ]]; then
          /bin/mv "$BACKUP_APP" "$CURRENT_APP"
          /usr/bin/open "$CURRENT_APP"
        fi
        /usr/bin/osascript -e 'display alert "AI Coding Proxy 更新失败" message "替换应用时遇到问题，已尝试恢复旧版本。"' >/dev/null 2>&1 || true
        exit 1
        """
        try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
        try self.fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static func normalizedAppBundleURL(_ url: URL?) -> URL? {
        guard var url else { return nil }
        while url.pathExtension != "app" {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
        return url
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stderr = Pipe()
            process.standardError = stderr
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: AppUpdateInstallerError.launchFailed(detail))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
