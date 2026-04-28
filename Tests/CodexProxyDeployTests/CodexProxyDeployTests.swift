import CodexProxyCore
import XCTest
@testable import CodexProxyDeploy

private final class SSHControllerStub: @unchecked Sendable, SSHControlling {
    var commands: [String] = []
    var uploadedPaths: [(local: String, remote: String)] = []
    var runHandler: (@Sendable (RemoteHostConfig, String) throws -> String)?

    func run(host: RemoteHostConfig, command: String) async throws -> String {
        self.commands.append(command)
        if let runHandler {
            return try runHandler(host, command)
        }
        return ""
    }

    func upload(host: RemoteHostConfig, local: URL, remote: String) async throws {
        self.uploadedPaths.append((local.path, remote))
    }

    func openTunnel(host: RemoteHostConfig, localPort: Int, remotePort: Int, controlPath: String) async throws {
    }

    func closeTunnel(host: RemoteHostConfig, controlPath: String) async {
    }
}

final class CodexProxyDeployTests: XCTestCase {
    func testArtifactResolverResolvesBundleFromExplicitSearchRoot() throws {
        let artifactRoot = try self.makeArtifactRoot(with: ["linux-amd64"])
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let resolver = RemoteDeployArtifactResolver(searchRoot: artifactRoot)
        let resolved = try resolver.artifactBundle(for: "x86_64")

        XCTAssertEqual(
            resolved.daemonURL.path,
            artifactRoot.appendingPathComponent("linux-amd64/codex-proxyd").path
        )
        XCTAssertEqual(
            resolved.mihomoURL.path,
            artifactRoot.appendingPathComponent("linux-amd64/mihomo").path
        )
    }

    func testArtifactResolverThrowsHelpfulMessageWhenBundledArtifactsAreUnavailable() {
        let resolver = RemoteDeployArtifactResolver(searchRoots: [])

        XCTAssertThrowsError(try resolver.artifactBundle(for: "arm64")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Scripts/build-macos-app.sh"))
            XCTAssertTrue(error.localizedDescription.contains("Scripts/package-release.sh"))
        }
    }

    func testArtifactResolverThrowsWhenBundleIsIncomplete() throws {
        let artifactRoot = try self.makeArtifactRoot(with: ["linux-arm64"], includeMihomo: false)
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let resolver = RemoteDeployArtifactResolver(searchRoot: artifactRoot)

        XCTAssertThrowsError(try resolver.artifactBundle(for: "arm64")) { error in
            XCTAssertTrue(error.localizedDescription.contains("mihomo"))
        }
    }

    func testArtifactResolverDirectoryNameNormalizesNoisyAndAliasedArchitectureStrings() throws {
        XCTAssertEqual(
            try RemoteDeployArtifactResolver.directoryName(for: "x86_64\nWarning: Permanently added '47.96.17.38' (ED25519) to the list of known hosts."),
            "linux-amd64"
        )
        XCTAssertEqual(try RemoteDeployArtifactResolver.directoryName(for: "amd64"), "linux-amd64")
        XCTAssertEqual(try RemoteDeployArtifactResolver.directoryName(for: "aarch64"), "linux-arm64")
        XCTAssertEqual(try RemoteDeployArtifactResolver.directoryName(for: "  arm64  "), "linux-arm64")
    }

    func testTestConnectionMapsSuccessfulReadinessChecks() async throws {
        let artifactRoot = try self.makeArtifactRoot(with: ["linux-arm64"])
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let ssh = SSHControllerStub()
        ssh.runHandler = { _, _ in
            """
            architecture=arm64
            remote_user=deploy
            systemctl=1
            sudo=1
            dir_writable=1
            """
        }

        let service = RemoteDeployService(ssh: ssh, artifactRoot: artifactRoot)
        let host = RemoteHostConfig(id: "host-1", label: "Tokyo", host: "tokyo.example.com", sshUser: "deploy")

        let check = try await service.testConnection(host: host)

        XCTAssertEqual(check.hostID, "host-1")
        XCTAssertEqual(check.architecture, "arm64")
        XCTAssertEqual(check.remoteUser, "deploy")
        XCTAssertTrue(check.remoteDirectoryWritable)
        XCTAssertTrue(check.systemctlAvailable)
        XCTAssertTrue(check.sudoAvailable)
        XCTAssertTrue(check.localArtifactAvailable)
        XCTAssertEqual(ssh.commands.count, 1)
        XCTAssertTrue(ssh.commands[0].contains("sudo -v"))
    }

    func testTestConnectionReportsMissingArtifactForSupportedArchitecture() async throws {
        let artifactRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let ssh = SSHControllerStub()
        ssh.runHandler = { _, _ in
            """
            architecture=x86_64
            remote_user=root
            systemctl=1
            sudo=1
            dir_writable=1
            """
        }

        let service = RemoteDeployService(ssh: ssh, artifactRoot: artifactRoot)
        let host = RemoteHostConfig(id: "host-2", label: "Seoul", host: "seoul.example.com")

        let check = try await service.testConnection(host: host)

        XCTAssertEqual(check.architecture, "x86_64")
        XCTAssertFalse(check.localArtifactAvailable)
        XCTAssertTrue(check.systemctlAvailable)
        XCTAssertTrue(check.sudoAvailable)
        XCTAssertTrue(check.remoteDirectoryWritable)
    }

    func testTestConnectionMapsUnsupportedArchitectureAndMissingCapabilitiesWithoutThrowing() async throws {
        let artifactRoot = try self.makeArtifactRoot(with: [])
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let ssh = SSHControllerStub()
        ssh.runHandler = { _, _ in
            """
            architecture=riscv64
            remote_user=ubuntu
            systemctl=0
            sudo=0
            dir_writable=0
            """
        }

        let service = RemoteDeployService(ssh: ssh, artifactRoot: artifactRoot)
        let host = RemoteHostConfig(id: "host-3", label: "Edge", host: "edge.example.com", sshUser: "ubuntu")

        let check = try await service.testConnection(host: host)

        XCTAssertEqual(check.architecture, "riscv64")
        XCTAssertEqual(check.remoteUser, "ubuntu")
        XCTAssertFalse(check.systemctlAvailable)
        XCTAssertFalse(check.sudoAvailable)
        XCTAssertFalse(check.remoteDirectoryWritable)
        XCTAssertFalse(check.localArtifactAvailable)
    }

    func testDeployUsesResolvedArtifactForRemoteArchitecture() async throws {
        let artifactRoot = try self.makeArtifactRoot(with: ["linux-arm64"])
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let ssh = SSHControllerStub()
        ssh.runHandler = { _, command in
            if command == "uname -m" {
                return "arm64\n"
            }
            if command.contains("printf 'installed=%s\\nrunning=%s\\nenabled=%s\\napi_key=%s\\n'") {
                return """
                installed=1
                running=1
                enabled=1
                api_key=
                """
            }
            return ""
        }

        let service = RemoteDeployService(
            ssh: ssh,
            artifactResolver: RemoteDeployArtifactResolver(searchRoot: artifactRoot)
        )
        let host = RemoteHostConfig(id: "host-4", label: "Tokyo", host: "tokyo.example.com")

        _ = try await service.deploy(
            host: host,
            exportedAccountsJSON: Data("[]".utf8),
            config: AppConfig()
        )

        XCTAssertEqual(
            ssh.uploadedPaths.first?.local,
            artifactRoot.appendingPathComponent("linux-arm64/codex-proxyd").path
        )
        XCTAssertTrue(
            ssh.uploadedPaths.contains {
                $0.local == artifactRoot.appendingPathComponent("linux-arm64/mihomo").path &&
                    $0.remote.hasSuffix("/mihomo")
            }
        )
        XCTAssertTrue(ssh.commands.contains { $0.contains("sudo systemctl enable --now codex-proxy-host-4.service") })
        XCTAssertTrue(ssh.commands.contains { $0.contains("mv") && $0.contains("/mihomo") })
    }

    func testDeployUsesResolvedArtifactForNoisyX8664ArchitectureOutput() async throws {
        let artifactRoot = try self.makeArtifactRoot(with: ["linux-amd64"])
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let ssh = SSHControllerStub()
        ssh.runHandler = { _, command in
            if command == "uname -m" {
                return """
                x86_64
                Warning: Permanently added '47.96.17.38' (ED25519) to the list of known hosts.
                """
            }
            if command.contains("printf 'installed=%s\\nrunning=%s\\nenabled=%s\\napi_key=%s\\n'") {
                return """
                installed=1
                running=1
                enabled=1
                api_key=
                """
            }
            return ""
        }

        let service = RemoteDeployService(
            ssh: ssh,
            artifactResolver: RemoteDeployArtifactResolver(searchRoot: artifactRoot)
        )
        let host = RemoteHostConfig(id: "host-5", label: "Shanghai", host: "47.96.17.38")

        _ = try await service.deploy(
            host: host,
            exportedAccountsJSON: Data("[]".utf8),
            config: AppConfig()
        )

        XCTAssertEqual(
            ssh.uploadedPaths.first?.local,
            artifactRoot.appendingPathComponent("linux-amd64/codex-proxyd").path
        )
        XCTAssertTrue(
            ssh.uploadedPaths.contains {
                $0.local == artifactRoot.appendingPathComponent("linux-amd64/mihomo").path &&
                    $0.remote.hasSuffix("/mihomo")
            }
        )
    }

    func testDetectArchitectureNormalizesNoisyAArch64Output() async throws {
        let ssh = SSHControllerStub()
        ssh.runHandler = { _, command in
            if command == "uname -m" {
                return """
                aarch64
                Warning: Permanently added 'edge.example.com' (ED25519) to the list of known hosts.
                """
            }
            return ""
        }

        let service = RemoteDeployService(ssh: ssh, artifactResolver: RemoteDeployArtifactResolver(searchRoots: []))
        let host = RemoteHostConfig(id: "host-6", label: "Edge", host: "edge.example.com")

        let architecture = try await service.detectArchitecture(host: host)

        XCTAssertEqual(architecture, "arm64")
    }

    func testDetectArchitectureThrowsHelpfulErrorForUnsupportedArchitectureOutput() async {
        let ssh = SSHControllerStub()
        ssh.runHandler = { _, command in
            if command == "uname -m" {
                return """
                riscv64
                Warning: Permanently added 'edge.example.com' (ED25519) to the list of known hosts.
                """
            }
            return ""
        }

        let service = RemoteDeployService(ssh: ssh, artifactResolver: RemoteDeployArtifactResolver(searchRoots: []))
        let host = RemoteHostConfig(id: "host-7", label: "RISC-V", host: "edge.example.com")

        do {
            _ = try await service.detectArchitecture(host: host)
            XCTFail("Expected unsupported architecture error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unsupported remote architecture reported by host"))
            XCTAssertTrue(error.localizedDescription.contains("riscv64"))
        }
    }

    private func makeArtifactRoot(
        with directories: [String],
        includeDaemon: Bool = true,
        includeMihomo: Bool = true
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for directory in directories {
            let binaryDirectory = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
            if includeDaemon {
                let binaryPath = binaryDirectory.appendingPathComponent("codex-proxyd")
                try Data("binary".utf8).write(to: binaryPath)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
            }
            if includeMihomo {
                let mihomoPath = binaryDirectory.appendingPathComponent("mihomo")
                try Data("mihomo".utf8).write(to: mihomoPath)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mihomoPath.path)
            }
        }

        return root
    }
}
