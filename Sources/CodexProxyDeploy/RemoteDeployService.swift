import CodexProxyCore
import Foundation

public protocol RemoteDeploying: Sendable {
    func deploy(
        host: RemoteHostConfig,
        exportedAccountsJSON: Data,
        config: AppConfig
    ) async throws -> RemoteDeployStatus
    func start(host: RemoteHostConfig) async throws -> RemoteDeployStatus
    func stop(host: RemoteHostConfig) async throws -> RemoteDeployStatus
    func logs(host: RemoteHostConfig, lines: Int) async throws -> String
    func status(host: RemoteHostConfig) async throws -> RemoteDeployStatus
    func testConnection(host: RemoteHostConfig) async throws -> RemoteConnectionCheck
}

public final class RemoteDeployService: @unchecked Sendable, RemoteDeploying {
    private let ssh: any SSHControlling
    private let artifactResolver: any RemoteDeployArtifactResolving

    public init(
        ssh: any SSHControlling = SSHController(),
        artifactResolver: any RemoteDeployArtifactResolving = RemoteDeployArtifactResolver()
    ) {
        self.ssh = ssh
        self.artifactResolver = artifactResolver
    }

    public convenience init(
        ssh: any SSHControlling = SSHController(),
        artifactRoot: URL
    ) {
        self.init(
            ssh: ssh,
            artifactResolver: RemoteDeployArtifactResolver(searchRoot: artifactRoot)
        )
    }

    public func deploy(
        host: RemoteHostConfig,
        exportedAccountsJSON: Data,
        config: AppConfig
    ) async throws -> RemoteDeployStatus {
        let architecture = try await self.detectArchitecture(host: host)
        let artifactBundle = try self.locateArtifactBundle(for: architecture)
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let bootstrapAccounts = tempDirectory.appendingPathComponent("bootstrap-accounts.json")
        let bootstrapSettings = tempDirectory.appendingPathComponent("settings-bootstrap.json")
        let unitFile = tempDirectory.appendingPathComponent(self.systemdUnitName(for: host))
        let remoteStage = "/tmp/codex-proxy-\(host.id)-\(Int(Date().timeIntervalSince1970))"

        try exportedAccountsJSON.write(to: bootstrapAccounts)
        var remoteConfig = config
        remoteConfig.publicHost = "0.0.0.0"
        remoteConfig.publicPort = host.publicPort
        remoteConfig.adminPort = host.adminPort
        remoteConfig.daemonBinaryOverride = ""
        remoteConfig.remoteHosts = []
        try Helpers.encodeJSON(remoteConfig, pretty: true).write(to: bootstrapSettings)
        try Data(self.renderSystemdUnit(for: host).utf8).write(to: unitFile)

        _ = try await self.ssh.run(host: host, command: "mkdir -p \(self.shellQuote(remoteStage)) \(self.shellQuote(host.remoteDirectory)) \(self.shellQuote(host.remoteDirectory))/data")
        try await self.ssh.upload(host: host, local: artifactBundle.daemonURL, remote: "\(remoteStage)/codex-proxyd")
        try await self.ssh.upload(host: host, local: artifactBundle.mihomoURL, remote: "\(remoteStage)/mihomo")
        try await self.ssh.upload(host: host, local: bootstrapAccounts, remote: "\(remoteStage)/bootstrap-accounts.json")
        try await self.ssh.upload(host: host, local: bootstrapSettings, remote: "\(remoteStage)/settings-bootstrap.json")
        try await self.ssh.upload(host: host, local: unitFile, remote: "\(remoteStage)/\(self.systemdUnitName(for: host))")

        let installCommand = """
        set -e;
        mkdir -p \(self.shellQuote(host.remoteDirectory)) \(self.shellQuote(host.remoteDirectory))/data;
        mv \(self.shellQuote(remoteStage))/codex-proxyd \(self.shellQuote(host.remoteDirectory))/codex-proxyd;
        chmod +x \(self.shellQuote(host.remoteDirectory))/codex-proxyd;
        mv \(self.shellQuote(remoteStage))/mihomo \(self.shellQuote(host.remoteDirectory))/mihomo;
        chmod +x \(self.shellQuote(host.remoteDirectory))/mihomo;
        mv \(self.shellQuote(remoteStage))/bootstrap-accounts.json \(self.shellQuote(host.remoteDirectory))/data/bootstrap-accounts.json;
        mv \(self.shellQuote(remoteStage))/settings-bootstrap.json \(self.shellQuote(host.remoteDirectory))/data/settings-bootstrap.json;
        sudo mv \(self.shellQuote(remoteStage))/\(self.systemdUnitName(for: host)) /etc/systemd/system/\(self.systemdUnitName(for: host));
        sudo systemctl daemon-reload;
        sudo systemctl enable --now \(self.systemdUnitName(for: host));
        """
        _ = try await self.ssh.run(host: host, command: installCommand)
        return try await self.status(host: host)
    }

    public func start(host: RemoteHostConfig) async throws -> RemoteDeployStatus {
        _ = try await self.ssh.run(host: host, command: "sudo systemctl start \(self.systemdUnitName(for: host))")
        return try await self.status(host: host)
    }

    public func stop(host: RemoteHostConfig) async throws -> RemoteDeployStatus {
        _ = try await self.ssh.run(host: host, command: "sudo systemctl stop \(self.systemdUnitName(for: host))")
        return try await self.status(host: host)
    }

    public func logs(host: RemoteHostConfig, lines: Int = 120) async throws -> String {
        try await self.ssh.run(host: host, command: "sudo journalctl -u \(self.systemdUnitName(for: host)) -n \(lines) --no-pager")
    }

    public func status(host: RemoteHostConfig) async throws -> RemoteDeployStatus {
        let architecture = (try? await self.detectArchitecture(host: host)) ?? "unknown"
        let unit = self.systemdUnitName(for: host)
        let command = """
        INSTALLED=0;
        RUNNING=0;
        ENABLED=0;
        if [ -x \(self.shellQuote(host.remoteDirectory))/codex-proxyd ]; then INSTALLED=1; fi;
        if systemctl is-active --quiet \(unit); then RUNNING=1; fi;
        if systemctl is-enabled --quiet \(unit); then ENABLED=1; fi;
        API_KEY="";
        if [ -f \(self.shellQuote(host.remoteDirectory))/data/proxy-api-key.txt ]; then API_KEY=$(cat \(self.shellQuote(host.remoteDirectory))/data/proxy-api-key.txt); fi;
        printf 'installed=%s\\nrunning=%s\\nenabled=%s\\napi_key=%s\\n' "$INSTALLED" "$RUNNING" "$ENABLED" "$API_KEY";
        """
        let output = try await self.ssh.run(host: host, command: command)
        var installed = false
        var running = false
        var enabled = false
        var apiKey: String?
        for line in output.split(separator: "\n") {
            if let value = line.split(separator: "=").dropFirst().first {
                if line.hasPrefix("installed=") { installed = value == "1" }
                if line.hasPrefix("running=") { running = value == "1" }
                if line.hasPrefix("enabled=") { enabled = value == "1" }
                if line.hasPrefix("api_key=") { apiKey = String(value) }
            }
        }
        return RemoteDeployStatus(
            hostID: host.id,
            installed: installed,
            serviceInstalled: true,
            running: running,
            enabled: enabled,
            architecture: architecture,
            baseURL: "http://\(host.host):\(host.publicPort)/v1",
            apiKey: apiKey,
            lastError: nil
        )
    }

    public func detectArchitecture(host: RemoteHostConfig) async throws -> String {
        let output = try await self.ssh.run(host: host, command: "uname -m")
        do {
            return try RemoteDeployArtifactResolver.normalizedArchitectureIdentifier(from: output)
        } catch {
            throw ProxyError.message(
                "Unsupported remote architecture reported by host: \(RemoteDeployArtifactResolver.summarizedArchitectureOutput(output))"
            )
        }
    }

    public func testConnection(host: RemoteHostConfig) async throws -> RemoteConnectionCheck {
        let command = """
        set -u;
        TARGET=\(self.shellQuote(host.remoteDirectory));
        PARENT=$(dirname "$TARGET");
        ARCH=$(uname -m 2>/dev/null || printf 'unknown');
        REMOTE_USER=$(id -un 2>/dev/null || printf '');
        SYSTEMCTL=0;
        if command -v systemctl >/dev/null 2>&1; then SYSTEMCTL=1; fi;
        SUDO=0;
        if sudo -v >/dev/null 2>&1; then SUDO=1; fi;
        DIR_WRITABLE=0;
        if [ -d "$TARGET" ]; then
            if [ -w "$TARGET" ]; then DIR_WRITABLE=1; fi;
        elif [ -d "$PARENT" ] && [ -w "$PARENT" ]; then
            DIR_WRITABLE=1;
        fi;
        printf 'architecture=%s\\nremote_user=%s\\nsystemctl=%s\\nsudo=%s\\ndir_writable=%s\\n' \
            "$ARCH" "$REMOTE_USER" "$SYSTEMCTL" "$SUDO" "$DIR_WRITABLE";
        """
        let output = try await self.ssh.run(host: host, command: command)
        var architecture = "unknown"
        var remoteUser = host.sshUser
        var systemctlAvailable = false
        var sudoAvailable = false
        var remoteDirectoryWritable = false

        for line in output.split(separator: "\n") {
            guard let value = line.split(separator: "=", maxSplits: 1).dropFirst().first else { continue }
            if line.hasPrefix("architecture=") { architecture = String(value) }
            if line.hasPrefix("remote_user=") { remoteUser = String(value) }
            if line.hasPrefix("systemctl=") { systemctlAvailable = value == "1" }
            if line.hasPrefix("sudo=") { sudoAvailable = value == "1" }
            if line.hasPrefix("dir_writable=") { remoteDirectoryWritable = value == "1" }
        }

        return RemoteConnectionCheck(
            hostID: host.id,
            architecture: architecture,
            remoteUser: remoteUser,
            remoteDirectoryWritable: remoteDirectoryWritable,
            systemctlAvailable: systemctlAvailable,
            sudoAvailable: sudoAvailable,
            localArtifactAvailable: self.artifactAvailable(for: architecture)
        )
    }

    private func locateArtifactBundle(for architecture: String) throws -> RemoteDeployArtifactBundle {
        try self.artifactResolver.artifactBundle(for: architecture)
    }

    private func artifactAvailable(for architecture: String) -> Bool {
        self.artifactResolver.artifactAvailable(for: architecture)
    }

    private func systemdUnitName(for host: RemoteHostConfig) -> String {
        "codex-proxy-\(host.id).service"
    }

    private func renderSystemdUnit(for host: RemoteHostConfig) -> String {
        """
        [Unit]
        Description=AI Coding Proxy Daemon (\(host.label.isEmpty ? host.host : host.label))
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        WorkingDirectory=\(host.remoteDirectory)
        Environment="CODEX_PROXY_MIHOMO_PATH=\(self.systemdEscape("\(host.remoteDirectory)/mihomo"))"
        ExecStart=\(host.remoteDirectory)/codex-proxyd serve --data-dir \(host.remoteDirectory)/data --public-host 0.0.0.0 --public-port \(host.publicPort) --admin-port \(host.adminPort)
        Restart=always
        RestartSec=2
        User=root
        Group=root
        LimitNOFILE=65535

        [Install]
        WantedBy=multi-user.target
        """
    }

    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func systemdEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
