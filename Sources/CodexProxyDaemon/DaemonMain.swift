import CodexProxyCore
import Foundation
import Hummingbird
import Logging
import ServiceLifecycle
import UnixSignals

@main
struct CodexProxyDaemonMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let versionOutput = Self.versionOutput(for: arguments) {
            print(versionOutput)
            return
        }

        let publicPort = Self.value(after: "--public-port", in: arguments).flatMap(Int.init) ?? 8787
        let adminPort = Self.value(after: "--admin-port", in: arguments).flatMap(Int.init) ?? 8788
        let publicHost = Self.value(after: "--public-host", in: arguments) ?? "127.0.0.1"
        let dataDirectory = Self.value(after: "--data-dir", in: arguments).map { URL(fileURLWithPath: $0) } ?? Paths.defaultDataDirectory()

        let controller = try DaemonController(
            dataDirectory: dataDirectory,
            publicBaseURLProvider: { "http://\(publicHost):\(publicPort)/v1" },
            adminBaseURLProvider: { "http://127.0.0.1:\(adminPort)/admin" }
        )
        try await controller.bootstrap()

        let service = DaemonHTTPService(
            controller: controller,
            publicHost: publicHost,
            publicPort: publicPort,
            adminPort: adminPort
        )

        print("codex-proxyd is running.")
        print("public=http://\(publicHost):\(publicPort)/v1")
        print("admin=http://127.0.0.1:\(adminPort)/admin")
        print("data_dir=\(dataDirectory.path)")
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [service.publicApplication(), service.adminApplication()],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: Logger(label: "io.shiguanghuxian.codex-proxy.daemon")
            )
        )
        do {
            try await serviceGroup.run()
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func versionOutput(for arguments: [String]) -> String? {
        if arguments.contains("--release-version") {
            return RuntimeInfo.releaseVersion
        }
        if arguments.contains("--version") {
            return RuntimeInfo.displayVersion
        }
        return nil
    }
}
