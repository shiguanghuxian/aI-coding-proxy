import CodexProxyCore
import Foundation

public protocol SSHControlling: Sendable {
    func run(host: RemoteHostConfig, command: String) async throws -> String
    func upload(host: RemoteHostConfig, local: URL, remote: String) async throws
    func openTunnel(host: RemoteHostConfig, localPort: Int, remotePort: Int, controlPath: String) async throws
    func closeTunnel(host: RemoteHostConfig, controlPath: String) async
}

public final class SSHController: @unchecked Sendable, SSHControlling {
    private let pty = PtyProcess()

    public init() {}

    public func run(host: RemoteHostConfig, command: String) async throws -> String {
        let args = try self.baseSSHArguments(host: host) + [self.connectionTarget(for: host), command]
        let result = try await self.execute(binary: "/usr/bin/ssh", arguments: args, password: host.authMode == .password ? host.password : nil)
        guard result.exitCode == 0 else {
            throw ProxyError.message(result.output)
        }
        return result.output
    }

    public func upload(host: RemoteHostConfig, local: URL, remote: String) async throws {
        let args = try self.baseSCPArguments(host: host) + [local.path, "\(self.connectionTarget(for: host)):\(remote)"]
        let result = try await self.execute(binary: "/usr/bin/scp", arguments: args, password: host.authMode == .password ? host.password : nil)
        guard result.exitCode == 0 else {
            throw ProxyError.message(result.output)
        }
    }

    public func openTunnel(host: RemoteHostConfig, localPort: Int, remotePort: Int, controlPath: String) async throws {
        let args = try self.baseSSHArguments(host: host) + [
            "-o", "ExitOnForwardFailure=yes",
            "-M",
            "-S", controlPath,
            "-f",
            "-N",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
            self.connectionTarget(for: host),
        ]
        let result = try await self.execute(
            binary: "/usr/bin/ssh",
            arguments: args,
            password: host.authMode == .password ? host.password : nil
        )
        guard result.exitCode == 0 else {
            throw ProxyError.message(result.output)
        }
    }

    public func closeTunnel(host: RemoteHostConfig, controlPath: String) async {
        let args: [String]
        do {
            args = try self.baseSSHArguments(host: host) + [
                "-S", controlPath,
                "-O", "exit",
                self.connectionTarget(for: host),
            ]
        } catch {
            return
        }
        _ = try? await self.execute(binary: "/usr/bin/ssh", arguments: args, password: nil)
    }

    private func execute(binary: String, arguments: [String], password: String?) async throws -> PtyProcess.Result {
        if password != nil {
            return try await self.pty.run(launchPath: binary, arguments: arguments, password: password)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile() + stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return .init(output: output, exitCode: process.terminationStatus)
    }

    private func connectionTarget(for host: RemoteHostConfig) -> String {
        "\(host.sshUser)@\(host.host)"
    }

    private func baseSSHArguments(host: RemoteHostConfig) throws -> [String] {
        var args = [
            "-p", "\(host.sshPort)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=30",
        ]
        if let identity = try self.identityFile(for: host) {
            args += ["-i", identity]
        }
        return args
    }

    private func baseSCPArguments(host: RemoteHostConfig) throws -> [String] {
        var args = [
            "-P", "\(host.sshPort)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
        ]
        if let identity = try self.identityFile(for: host) {
            args += ["-i", identity]
        }
        return args
    }

    private func identityFile(for host: RemoteHostConfig) throws -> String? {
        switch host.authMode {
        case .sshKeyPath:
            return host.identityFile.isEmpty ? nil : host.identityFile
        case .sshKeyContent:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-proxy-key-\(host.id)")
            try Helpers.writeFile(url, data: Data(host.privateKey.utf8))
            return url.path
        case .password:
            return nil
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
