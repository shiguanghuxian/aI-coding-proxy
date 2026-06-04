#if os(macOS)
import CodexProxyCore
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import Darwin
import Foundation

@MainActor
final class LocalDaemonController {
    enum DiagnosticLogLevel: String {
        case trace
        case debug
        case info
        case notice
        case warning
        case error
        case critical
    }

    enum StartupHealthTimeoutResolution: Equatable {
        case retryGracePeriod
        case fail(String)
    }

    enum ApplyLaunchConfigurationOutcome: Sendable, Equatable {
        case appliedNow
        case savedButRestartRequired
    }

    private nonisolated static let initialHealthCheckAttempts = 12
    private nonisolated static let graceHealthCheckAttempts = 4
    private nonisolated static let exitedBeforeHealthCheckMessage = "Daemon exited before passing its health check."
    private nonisolated static let runningButHealthCheckPendingMessage = "Daemon process is running, but the health endpoint did not become ready in time."
    private nonisolated static let daemonBinarySHA256EnvironmentKey = "CODEX_PROXY_DAEMON_BINARY_SHA256"

    typealias PrepareForLaunchHandler = (AppConfig) async throws -> Void
    typealias ApplyLaunchConfigurationHandler = (AppConfig, Bool) async throws -> ApplyLaunchConfigurationOutcome
    typealias InstallLaunchAgentHandler = (AppConfig) async throws -> Bool
    typealias LaunchctlHandler = ([String], Bool) async throws -> String
    typealias HealthCheckHandler = (AppConfig) async -> Bool
    typealias SleepHandler = (Duration) async -> Void
    typealias StartHandler = (AppConfig) async throws -> Void
    typealias StopHandler = () async throws -> Void
    typealias StatusHandler = () async -> LocalServiceStatus

    let dataDirectory: URL
    let serviceLabel = "io.shiguanghuxian.codex-proxy"
    private let prepareForLaunchHandler: PrepareForLaunchHandler?
    private let applyLaunchConfigurationHandler: ApplyLaunchConfigurationHandler?
    private let installLaunchAgentHandler: InstallLaunchAgentHandler?
    private let launchctlHandler: LaunchctlHandler?
    private let healthCheckHandler: HealthCheckHandler?
    private let sleepHandler: SleepHandler?
    private let startHandler: StartHandler?
    private let stopHandler: StopHandler?
    private let statusHandler: StatusHandler?

    init(
        dataDirectory: URL = Paths.defaultDataDirectory(),
        prepareForLaunchHandler: PrepareForLaunchHandler? = nil,
        applyLaunchConfigurationHandler: ApplyLaunchConfigurationHandler? = nil,
        installLaunchAgentHandler: InstallLaunchAgentHandler? = nil,
        launchctlHandler: LaunchctlHandler? = nil,
        healthCheckHandler: HealthCheckHandler? = nil,
        sleepHandler: SleepHandler? = nil,
        startHandler: StartHandler? = nil,
        stopHandler: StopHandler? = nil,
        statusHandler: StatusHandler? = nil
    ) {
        self.dataDirectory = dataDirectory
        self.prepareForLaunchHandler = prepareForLaunchHandler
        self.applyLaunchConfigurationHandler = applyLaunchConfigurationHandler
        self.installLaunchAgentHandler = installLaunchAgentHandler
        self.launchctlHandler = launchctlHandler
        self.healthCheckHandler = healthCheckHandler
        self.sleepHandler = sleepHandler
        self.startHandler = startHandler
        self.stopHandler = stopHandler
        self.statusHandler = statusHandler
    }

    func daemonBinaryPath(config: AppConfig? = nil) -> String {
        if let configured = config?.daemonBinaryOverride, !configured.isEmpty {
            return configured
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_PROXY_DAEMON_PATH"], !env.isEmpty {
            return env
        }
        let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("codex-proxyd").path
        if let executable, FileManager.default.isExecutableFile(atPath: executable) {
            return executable
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/codex-proxyd")
            .path
    }

    func installLaunchAgent(config: AppConfig) async throws -> Bool {
        if let installLaunchAgentHandler {
            return try await installLaunchAgentHandler(config)
        }

        let dataDirectory = self.dataDirectory
        let serviceLabel = self.serviceLabel
        let daemonBinaryPath = self.daemonBinaryPath(config: config)
        let stdoutPath = self.stdoutLogURL().path
        let stderrPath = self.stderrLogURL().path

        return try await Self.runBlocking {
            try Self.installLaunchAgent(
                dataDirectory: dataDirectory,
                serviceLabel: serviceLabel,
                daemonBinaryPath: daemonBinaryPath,
                stdoutPath: stdoutPath,
                stderrPath: stderrPath,
                config: config
            )
        }
    }

    func prepareForLaunch(config: AppConfig) async throws {
        _ = try await self.applyLaunchConfiguration(config: config, preserveRunningService: false)
    }

    func applyLaunchConfiguration(
        config: AppConfig,
        preserveRunningService: Bool
    ) async throws -> ApplyLaunchConfigurationOutcome {
        if let applyLaunchConfigurationHandler {
            return try await applyLaunchConfigurationHandler(config, preserveRunningService)
        }
        if let prepareForLaunchHandler {
            try await prepareForLaunchHandler(config)
            return .appliedNow
        }

        let didChange = try await self.installLaunchAgent(config: config)
        let status = await self.status()

        let outcome = Self.applyLaunchConfigurationOutcome(
            config: config,
            didChange: didChange,
            status: status,
            preserveRunningService: preserveRunningService
        )
        if outcome == .savedButRestartRequired {
            return outcome
        }

        try await self.reconcileLaunchConfiguration(config: config, didChange: didChange, status: status)
        return outcome
    }

    func start(config: AppConfig) async throws {
        if let startHandler {
            try await startHandler(config)
            return
        }

        _ = try await self.installLaunchAgent(config: config)
        _ = try await self.run("/bin/launchctl", ["bootout", self.serviceTarget()], ignoreFailure: true)
        try await self.bootstrapLaunchAgent(config: config)
        _ = try await self.run("/bin/launchctl", ["kickstart", "-k", self.serviceTarget()])

        guard await self.waitForHealth(config: config, attempts: Self.initialHealthCheckAttempts) else {
            let status = await self.status()
            switch Self.startupHealthTimeoutResolution(for: status) {
            case .fail(let message):
                throw ProxyError.message(message)
            case .retryGracePeriod:
                guard await self.waitForHealth(config: config, attempts: Self.graceHealthCheckAttempts) else {
                    let finalStatus = await self.status()
                    throw ProxyError.message(Self.startupFailureMessage(afterGraceTimeout: finalStatus))
                }
                return
            }
        }
    }

    func stop() async throws {
        if let stopHandler {
            try await stopHandler()
            return
        }
        _ = try await self.run("/bin/launchctl", ["bootout", self.serviceTarget()], ignoreFailure: true)
    }

    func isRunning() async -> Bool {
        await self.status().running
    }

    func sleep(for duration: Duration) async {
        if let sleepHandler {
            await sleepHandler(duration)
        } else {
            try? await Task.sleep(for: duration)
        }
    }

    func status() async -> LocalServiceStatus {
        if let statusHandler {
            return await statusHandler()
        }
        let launchAgentPath = Paths.launchAgentURL().path
        let stdoutPath = self.stdoutLogURL().path
        let stderrPath = self.stderrLogURL().path
        let serviceTarget = self.serviceTarget()

        do {
            return try await Self.runBlocking {
                let installed = FileManager.default.fileExists(atPath: launchAgentPath)
                let launchctlOutput = try Self.runProcess(
                    "/bin/launchctl",
                    ["print", serviceTarget],
                    ignoreFailure: true
                )
                let running = launchctlOutput.contains("state = running")
                let launchctlState = Self.parseLaunchctlState(from: launchctlOutput, installed: installed)
                let lastErrorSummary = Self.lastErrorSummary(
                    launchctlOutput: launchctlOutput,
                    stderrPath: stderrPath
                )

                return LocalServiceStatus(
                    installed: installed,
                    running: running,
                    launchctlState: launchctlState,
                    stdoutPath: stdoutPath,
                    stderrPath: stderrPath,
                    lastErrorSummary: lastErrorSummary
                )
            }
        } catch {
            let installed = FileManager.default.fileExists(atPath: launchAgentPath)
            return LocalServiceStatus(
                installed: installed,
                running: false,
                launchctlState: Self.parseLaunchctlState(from: "", installed: installed),
                stdoutPath: stdoutPath,
                stderrPath: stderrPath,
                lastErrorSummary: error.localizedDescription
            )
        }
    }

    func logs(maxLines: Int = 80) async -> String {
        let stdoutURL = self.stdoutLogURL()
        let stderrURL = self.stderrLogURL()
        return await Self.loadLogs(
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            maxLines: maxLines,
            stdoutLabel: "stdout",
            stderrLabel: "stderr",
            emptyMessage: "No local daemon logs available."
        )
    }

    func managedProxyLogs(maxLines: Int = 80) async -> String {
        return await Self.loadLogs(
            stdoutURL: Paths.mihomoStdoutLogURL(in: self.dataDirectory),
            stderrURL: Paths.mihomoStderrLogURL(in: self.dataDirectory),
            maxLines: maxLines,
            stdoutLabel: "mihomo stdout",
            stderrLabel: "mihomo stderr",
            emptyMessage: "No mihomo logs available."
        )
    }

    private func guiDomain() -> String {
        "gui/\(self.uid())"
    }

    private func serviceTarget() -> String {
        "\(self.guiDomain())/\(self.serviceLabel)"
    }

    private func uid() -> String {
        String(getuid())
    }

    private func stdoutLogURL() -> URL {
        self.dataDirectory.appendingPathComponent("daemon.out.log")
    }

    private func stderrLogURL() -> URL {
        self.dataDirectory.appendingPathComponent("daemon.err.log")
    }

    private func reconcileLaunchConfiguration(
        config: AppConfig,
        didChange: Bool,
        status: LocalServiceStatus
    ) async throws {
        if config.autoStart {
            if didChange && status.launchctlState != "not_registered" {
                _ = try await self.run("/bin/launchctl", ["bootout", self.serviceTarget()], ignoreFailure: true)
            }
            if didChange || status.launchctlState == "not_registered" {
                try await self.bootstrapLaunchAgent(config: config)
            }
            if didChange || !status.running {
                let arguments = didChange ? ["kickstart", "-k", self.serviceTarget()] : ["kickstart", self.serviceTarget()]
                _ = try await self.run("/bin/launchctl", arguments)
            }
            _ = await self.waitForHealth(config: config, attempts: Self.initialHealthCheckAttempts)
        } else if status.launchctlState != "not_registered" || status.running {
            _ = try await self.run("/bin/launchctl", ["bootout", self.serviceTarget()], ignoreFailure: true)
        }
    }

    private func bootstrapLaunchAgent(config: AppConfig) async throws {
        let arguments = ["bootstrap", self.guiDomain(), Paths.launchAgentURL().path]
        do {
            _ = try await self.run("/bin/launchctl", arguments)
        } catch {
            guard Self.isTransientBootstrapInputOutputError(error) else {
                throw error
            }
            try await self.recoverFromTransientBootstrapFailure(
                config: config,
                originalError: error,
                bootstrapArguments: arguments
            )
        }
    }

    private func recoverFromTransientBootstrapFailure(
        config: AppConfig,
        originalError: Error,
        bootstrapArguments: [String]
    ) async throws {
        await self.sleepForLaunchAgentRecoveryPoll()
        if await self.serviceRecoveredAfterTransientBootstrap(config: config) {
            return
        }

        do {
            _ = try await self.run("/bin/launchctl", bootstrapArguments)
            return
        } catch {
            guard Self.isTransientBootstrapInputOutputError(error) else {
                throw error
            }
        }

        await self.sleepForLaunchAgentRecoveryPoll()
        if await self.serviceRecoveredAfterTransientBootstrap(config: config) {
            return
        }
        throw originalError
    }

    private func serviceRecoveredAfterTransientBootstrap(config: AppConfig) async -> Bool {
        if await self.healthCheck(config: config) {
            return true
        }
        let status = await self.status()
        return status.running || status.launchctlState == "running"
    }

    private func sleepForLaunchAgentRecoveryPoll() async {
        await self.sleep(for: .milliseconds(350))
    }

    private func waitForHealth(config: AppConfig, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if await self.healthCheck(config: config) {
                return true
            }
            await self.sleepForLaunchAgentRecoveryPoll()
        }
        return false
    }

    private func healthCheck(config: AppConfig) async -> Bool {
        if let healthCheckHandler {
            return await healthCheckHandler(config)
        }

        guard let url = URL(string: "http://\(config.publicHost):\(config.publicPort)/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    nonisolated static func applyLaunchConfigurationOutcome(
        config: AppConfig,
        didChange: Bool,
        status: LocalServiceStatus,
        preserveRunningService: Bool
    ) -> ApplyLaunchConfigurationOutcome {
        guard preserveRunningService, status.running else {
            return .appliedNow
        }
        if config.autoStart == false {
            return (status.launchctlState != "not_registered" || status.running) ? .savedButRestartRequired : .appliedNow
        }
        return (didChange && status.launchctlState != "not_registered") ? .savedButRestartRequired : .appliedNow
    }

    nonisolated private static func installLaunchAgent(
        dataDirectory: URL,
        serviceLabel: String,
        daemonBinaryPath: String,
        stdoutPath: String,
        stderrPath: String,
        config: AppConfig
    ) throws -> Bool {
        try Helpers.ensureDirectory(dataDirectory)

        let daemonBinaryFingerprint = Self.daemonBinaryFingerprint(forPath: daemonBinaryPath)
        let plist = Self.makeLaunchAgentPlist(
            dataDirectory: dataDirectory,
            serviceLabel: serviceLabel,
            daemonBinaryPath: daemonBinaryPath,
            daemonBinaryFingerprint: daemonBinaryFingerprint,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            config: config
        )

        let url = Paths.launchAgentURL()
        let data = Data(plist.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            return false
        }
        try Helpers.writeFile(url, data: data, posixMode: 0o644)
        return true
    }

    nonisolated static func daemonBinaryFingerprint(forPath path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return "unreadable:\(path)"
        }
        defer { try? handle.close() }

        do {
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                guard chunk.isEmpty == false else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return "unreadable:\(path)"
        }
    }

    nonisolated static func makeLaunchAgentPlist(
        dataDirectory: URL,
        serviceLabel: String,
        daemonBinaryPath: String,
        daemonBinaryFingerprint: String,
        stdoutPath: String,
        stderrPath: String,
        config: AppConfig
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(Self.xmlEscaped(serviceLabel))</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(Self.xmlEscaped(daemonBinaryPath))</string>
            <string>serve</string>
            <string>--data-dir</string>
            <string>\(Self.xmlEscaped(dataDirectory.path))</string>
            <string>--public-host</string>
            <string>\(Self.xmlEscaped(config.publicHost))</string>
            <string>--public-port</string>
            <string>\(config.publicPort)</string>
            <string>--admin-port</string>
            <string>\(config.adminPort)</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>\(Self.daemonBinarySHA256EnvironmentKey)</key><string>\(Self.xmlEscaped(daemonBinaryFingerprint))</string>
          </dict>
          <key>RunAtLoad</key><\(config.autoStart ? "true" : "false")/>
          <key>KeepAlive</key><\(config.autoStart ? "true" : "false")/>
          <key>StandardOutPath</key><string>\(Self.xmlEscaped(stdoutPath))</string>
          <key>StandardErrorPath</key><string>\(Self.xmlEscaped(stderrPath))</string>
        </dict>
        </plist>
        """
    }

    nonisolated private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    nonisolated private static func parseLaunchctlState(from output: String, installed: Bool) -> String {
        guard !output.isEmpty else {
            return installed ? "not_registered" : "not_installed"
        }
        if output.lowercased().contains("could not find service") {
            return installed ? "not_registered" : "not_installed"
        }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("state = ") {
                return String(trimmed.dropFirst("state = ".count))
            }
        }
        return installed ? "registered" : "not_installed"
    }

    nonisolated private static func lastErrorSummary(launchctlOutput: String, stderrPath: String) -> String? {
        let stderrTail = Self.readTail(of: URL(fileURLWithPath: stderrPath), maxLines: 24)
        return Self.lastErrorSummary(launchctlOutput: launchctlOutput, stderr: stderrTail)
    }

    nonisolated static func lastErrorSummary(launchctlOutput: String, stderr: String) -> String? {
        if let stderr = Self.lastErrorSummary(fromStderr: stderr) {
            return stderr
        }
        return Self.launchctlErrorSummary(from: launchctlOutput)
    }

    nonisolated static func lastErrorSummary(fromStderr stderr: String) -> String? {
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let level = Self.structuredLogLevel(in: trimmed) {
                switch level {
                case .error, .critical:
                    return trimmed
                case .trace, .debug, .info, .notice, .warning:
                    continue
                }
            }

            if Self.looksLikeUnstructuredError(trimmed) {
                return trimmed
            }
        }
        return nil
    }

    nonisolated static func structuredLogLevel(in line: String) -> DiagnosticLogLevel? {
        let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true) { $0.isWhitespace }
        guard parts.count >= 2 else { return nil }
        guard Self.looksLikeStructuredLogTimestamp(String(parts[0])) else { return nil }
        return DiagnosticLogLevel(rawValue: String(parts[1]))
    }

    nonisolated static func launchctlErrorSummary(from output: String) -> String? {
        if Self.launchctlState(from: output) == "running" {
            return nil
        }

        for line in output.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("last exit code")
                || trimmed.lowercased().contains("could not find service")
            {
                return trimmed
            }
            if trimmed.lowercased().hasPrefix("last terminating signal ="),
                trimmed.lowercased().contains("terminated: 15") == false
            {
                return trimmed
            }
        }
        return nil
    }

    nonisolated static func startupHealthTimeoutResolution(for status: LocalServiceStatus) -> StartupHealthTimeoutResolution {
        if status.running {
            return .retryGracePeriod
        }
        if let detail = Self.cleanedErrorSummary(status.lastErrorSummary) {
            return .fail(detail)
        }
        return .fail(Self.exitedBeforeHealthCheckMessage)
    }

    nonisolated static func startupFailureMessage(afterGraceTimeout status: LocalServiceStatus) -> String {
        if status.running {
            return Self.runningButHealthCheckPendingMessage
        }
        if let detail = Self.cleanedErrorSummary(status.lastErrorSummary) {
            return detail
        }
        return Self.exitedBeforeHealthCheckMessage
    }

    nonisolated private static func looksLikeStructuredLogTimestamp(_ value: String) -> Bool {
        let characters = Array(value)
        guard characters.count >= 20 else { return false }
        return characters[4] == "-" && characters[7] == "-" && characters[10] == "T"
    }

    nonisolated private static func looksLikeUnstructuredError(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        let markers = [
            "fatal error",
            "assertion failed",
            "precondition failed",
            "uncaught",
            "exception",
            "segmentation fault",
            "illegal instruction",
            "traceback",
            "terminating due to",
        ]
        if markers.contains(where: { lowercased.contains($0) }) {
            return true
        }

        return lowercased.hasPrefix("error:")
            || lowercased.contains(" error:")
            || lowercased.hasPrefix("fatal:")
            || lowercased.hasPrefix("abort")
            || lowercased.contains(" signal ")
    }

    nonisolated private static func cleanedErrorSummary(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func launchctlState(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("state = ") else { continue }
            return String(trimmed.dropFirst("state = ".count))
        }
        return nil
    }

    nonisolated static func isTransientBootstrapInputOutputError(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("bootstrap failed: 5")
            && lowercased.contains("input/output error")
    }

    nonisolated private static func isTransientBootstrapInputOutputError(_ error: Error) -> Bool {
        Self.isTransientBootstrapInputOutputError(Self.launchctlErrorText(from: error))
    }

    nonisolated private static func launchctlErrorText(from error: Error) -> String {
        if let proxyError = error as? ProxyError {
            switch proxyError {
            case .message(let message):
                return message
            }
        }
        return error.localizedDescription
    }

    nonisolated private static func readTail(of url: URL, maxLines: Int) -> String {
        guard
            let text = try? String(contentsOf: url, encoding: .utf8),
            !text.isEmpty
        else {
            return ""
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .joined(separator: "\n")
    }

    nonisolated private static func loadLogs(
        stdoutURL: URL,
        stderrURL: URL,
        maxLines: Int,
        stdoutLabel: String,
        stderrLabel: String,
        emptyMessage: String
    ) async -> String {
        do {
            return try await Self.runBlocking {
                let stdout = Self.readTail(of: stdoutURL, maxLines: maxLines)
                let stderr = Self.readTail(of: stderrURL, maxLines: maxLines)

                var sections: [String] = []
                if !stdout.isEmpty {
                    sections.append("[\(stdoutLabel)]\n\(stdout)")
                }
                if !stderr.isEmpty {
                    sections.append("[\(stderrLabel)]\n\(stderr)")
                }
                return sections.isEmpty ? emptyMessage : sections.joined(separator: "\n\n")
            }
        } catch {
            return emptyMessage
        }
    }

    nonisolated private static func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .utility) {
            try work()
        }.value
    }

    nonisolated private static func runProcess(
        _ executable: String,
        _ arguments: [String],
        ignoreFailure: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        let err = Pipe()
        process.standardOutput = pipe
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile() + err.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        if process.terminationStatus != 0 && !ignoreFailure {
            throw ProxyError.message(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func run(_ executable: String, _ arguments: [String], ignoreFailure: Bool = false) async throws -> String {
        if executable == "/bin/launchctl", let launchctlHandler {
            return try await launchctlHandler(arguments, ignoreFailure)
        }
        return try await Self.runBlocking {
            try Self.runProcess(executable, arguments, ignoreFailure: ignoreFailure)
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var data = lhs
        data.append(rhs)
        return data
    }
}
#endif
