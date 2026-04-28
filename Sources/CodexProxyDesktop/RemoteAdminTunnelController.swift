#if os(macOS)
import CodexProxyCore
import CodexProxyDeploy
import Foundation

enum RemoteAdminTunnelStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(localPort: Int)
    case reconnecting
    case failed(String)
}

enum RemoteAdminReachabilityStatus: Sendable, Equatable {
    case unknown
    case reachable
    case reconnecting
    case failed(String)
}

struct RemoteAdminSessionState: Sendable, Equatable {
    var hostID: String
    var adminBaseURL: URL?
    var remoteEndpoint: String
    var configuredAdminPort: Int
    var effectiveAdminPort: Int
    var discoveredAdminPort: Int?
    var adminPortDriftDetected: Bool
    var localPort: Int?
    var tunnelStatus: RemoteAdminTunnelStatus
    var reachabilityStatus: RemoteAdminReachabilityStatus

    init(
        hostID: String,
        adminBaseURL: URL? = nil,
        remoteEndpoint: String,
        configuredAdminPort: Int,
        effectiveAdminPort: Int,
        discoveredAdminPort: Int? = nil,
        adminPortDriftDetected: Bool = false,
        localPort: Int? = nil,
        tunnelStatus: RemoteAdminTunnelStatus = .disconnected,
        reachabilityStatus: RemoteAdminReachabilityStatus = .unknown
    ) {
        self.hostID = hostID
        self.adminBaseURL = adminBaseURL
        self.remoteEndpoint = remoteEndpoint
        self.configuredAdminPort = configuredAdminPort
        self.effectiveAdminPort = effectiveAdminPort
        self.discoveredAdminPort = discoveredAdminPort
        self.adminPortDriftDetected = adminPortDriftDetected
        self.localPort = localPort
        self.tunnelStatus = tunnelStatus
        self.reachabilityStatus = reachabilityStatus
    }
}

protocol RemoteAdminTunneling: Sendable {
    func snapshot() async -> RemoteAdminSessionState
    func ensureConnected() async throws -> RemoteAdminSessionState
    func reconnect() async throws -> RemoteAdminSessionState
    func updateConfiguredAdminPort(_ port: Int) async
    func currentToken() async throws -> String
    func updateReachability(_ status: RemoteAdminReachabilityStatus) async
    func loadManagedProxyLogs(lines: Int) async throws -> String
    func close() async
}

actor RemoteAdminTunnelController: RemoteAdminTunneling {
    private var host: RemoteHostConfig
    private let ssh: any SSHControlling
    private var state: RemoteAdminSessionState
    private var controlPath: String?
    private var adminToken: String?

    init(
        host: RemoteHostConfig,
        ssh: any SSHControlling = SSHController()
    ) {
        self.host = host
        self.ssh = ssh
        self.state = RemoteAdminSessionState(
            hostID: host.id,
            remoteEndpoint: "\(host.host):\(host.adminPort)",
            configuredAdminPort: host.adminPort,
            effectiveAdminPort: host.adminPort
        )
    }

    func snapshot() async -> RemoteAdminSessionState {
        self.state
    }

    func ensureConnected() async throws -> RemoteAdminSessionState {
        if case .connected = self.state.tunnelStatus,
           self.state.localPort != nil,
           self.state.adminBaseURL != nil,
           self.controlPath != nil
        {
            return self.state
        }
        return try await self.establishTunnel(isReconnect: false)
    }

    func reconnect() async throws -> RemoteAdminSessionState {
        await self.close()
        return try await self.establishTunnel(isReconnect: true)
    }

    func updateConfiguredAdminPort(_ port: Int) async {
        self.host.adminPort = port
        self.state.configuredAdminPort = port
    }

    func currentToken() async throws -> String {
        if let adminToken {
            return adminToken
        }
        _ = try await self.ensureConnected()
        guard let adminToken else {
            throw ProxyError.message("Remote admin token is unavailable.")
        }
        return adminToken
    }

    func updateReachability(_ status: RemoteAdminReachabilityStatus) async {
        self.state.reachabilityStatus = status
    }

    func loadManagedProxyLogs(lines: Int = 120) async throws -> String {
        _ = try await self.ensureConnected()
        let dataDirectory = self.remoteDataDirectoryPath()
        let stdoutPath = "\(dataDirectory)/mihomo/mihomo.out.log"
        let stderrPath = "\(dataDirectory)/mihomo/mihomo.err.log"
        let command = [
            "stdout=$(tail -n \(max(lines, 1)) \(Self.shellQuoted(stdoutPath)) 2>/dev/null || true)",
            "stderr=$(tail -n \(max(lines, 1)) \(Self.shellQuoted(stderrPath)) 2>/dev/null || true)",
            "if [ -n \"$stdout\" ]; then printf \"[mihomo stdout]\\\\n%s\" \"$stdout\"; fi",
            "if [ -n \"$stderr\" ]; then if [ -n \"$stdout\" ]; then printf \"\\\\n\\\\n\"; fi; printf \"[mihomo stderr]\\\\n%s\" \"$stderr\"; fi",
            "if [ -z \"$stdout$stderr\" ]; then printf \"No mihomo logs available.\"; fi",
        ].joined(separator: "; ")
        return try await self.ssh.run(host: self.host, command: command)
    }

    func close() async {
        if let controlPath = self.controlPath {
            await self.ssh.closeTunnel(host: self.host, controlPath: controlPath)
            try? FileManager.default.removeItem(atPath: controlPath)
        }
        self.controlPath = nil
        self.adminToken = nil
        self.state.adminBaseURL = nil
        self.state.localPort = nil
        self.state.tunnelStatus = .disconnected
        self.state.reachabilityStatus = .unknown
    }

    private func establishTunnel(isReconnect: Bool) async throws -> RemoteAdminSessionState {
        self.state.tunnelStatus = isReconnect ? .reconnecting : .connecting
        self.state.reachabilityStatus = isReconnect ? .reconnecting : .unknown
        let configuredAdminPort = self.host.adminPort
        let discoveredAdminPort = await self.discoverAdminPort()
        let effectiveAdminPort = discoveredAdminPort ?? configuredAdminPort

        self.state.configuredAdminPort = configuredAdminPort
        self.state.effectiveAdminPort = effectiveAdminPort
        self.state.discoveredAdminPort = discoveredAdminPort
        self.state.adminPortDriftDetected = discoveredAdminPort != nil && discoveredAdminPort != configuredAdminPort
        self.state.remoteEndpoint = "\(self.host.host):\(effectiveAdminPort)"

        guard let localPort = POSIXCompat.availableTCPIPv4LoopbackPort(preferred: 0) else {
            let message = "Unable to allocate a local port for the remote admin tunnel."
            self.state.tunnelStatus = .failed(message)
            self.state.reachabilityStatus = .failed(message)
            throw ProxyError.message(message)
        }

        let controlPath = Self.makeControlPath(for: self.host.id)
        var didOpenTunnel = false

        do {
            try await self.ssh.openTunnel(
                host: self.host,
                localPort: localPort,
                remotePort: effectiveAdminPort,
                controlPath: controlPath
            )
            didOpenTunnel = true

            let token = try await self.readAdminToken()
            guard token.isEmpty == false else {
                throw ProxyError.message("Remote admin token is empty.")
            }

            self.controlPath = controlPath
            self.adminToken = token
            self.state.localPort = localPort
            self.state.adminBaseURL = URL(string: "http://127.0.0.1:\(localPort)/admin")
            self.state.tunnelStatus = .connected(localPort: localPort)
            self.state.reachabilityStatus = .unknown
            return self.state
        } catch {
            if didOpenTunnel {
                await self.ssh.closeTunnel(host: self.host, controlPath: controlPath)
            }
            try? FileManager.default.removeItem(atPath: controlPath)
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            self.controlPath = nil
            self.adminToken = nil
            self.state.adminBaseURL = nil
            self.state.localPort = nil
            self.state.tunnelStatus = .failed(message)
            self.state.reachabilityStatus = .failed(message)
            throw error
        }
    }

    private func readAdminToken() async throws -> String {
        let tokenPath = "\(self.remoteDataDirectoryPath())/admin-token.txt"
        do {
            let output = try await self.ssh.run(
                host: self.host,
                command: "cat \(Self.shellQuoted(tokenPath))"
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isMissingFileError(detail) {
                throw ProxyError.message(
                    "Remote admin token file is missing at \(tokenPath). This host was likely deployed by an older or incomplete remote proxy service setup. Redeploy the remote host or restart the remote proxy service once with the fixed build to recreate the admin token file."
                )
            }
            throw error
        }
    }

    private func discoverAdminPort() async -> Int? {
        let unit = Self.systemdUnitName(for: self.host.id)
        let unitPath = "/etc/systemd/system/\(unit)"
        let command = [
            "EXEC_START=$(sudo systemctl cat \(Self.shellQuoted(unit)) 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n 1)",
            "if [ -z \"$EXEC_START\" ] && [ -f \(Self.shellQuoted(unitPath)) ]; then EXEC_START=$(sudo sed -n 's/^ExecStart=//p' \(Self.shellQuoted(unitPath)) | head -n 1); fi",
            "printf '%s' \"$EXEC_START\"",
        ].joined(separator: "; ")

        guard let output = try? await self.ssh.run(host: self.host, command: command) else {
            return nil
        }
        return Self.parseAdminPort(from: output)
    }

    private func remoteDataDirectoryPath() -> String {
        let trimmed = self.host.remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return "/data"
        }
        return "\(self.host.remoteDirectory)/data"
    }

    private static func makeControlPath(for hostID: String) -> String {
        let suffix = hostID.replacingOccurrences(of: "-", with: "").prefix(12)
        return "/tmp/codex-proxy-remote-\(suffix).sock"
    }

    private static func systemdUnitName(for hostID: String) -> String {
        "codex-proxy-\(hostID).service"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func parseAdminPort(from execStart: String) -> Int? {
        let pattern = #"--admin-port(?:=|\s+)(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(execStart.startIndex..<execStart.endIndex, in: execStart)
        guard
            let match = regex.firstMatch(in: execStart, range: range),
            match.numberOfRanges > 1,
            let portRange = Range(match.range(at: 1), in: execStart),
            let port = Int(execStart[portRange]),
            port > 0
        else {
            return nil
        }
        return port
    }

    private static func isMissingFileError(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("no such file")
            || lower.contains("cannot open")
            || lower.contains("can't open")
            || lower.contains("not found")
    }
}
#endif
