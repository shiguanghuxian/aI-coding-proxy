import CodexProxyCore
import Foundation

public struct RemoteDeployArtifactBundle: Sendable, Equatable {
    public var architecture: String
    public var directoryURL: URL
    public var daemonURL: URL
    public var mihomoURL: URL

    public init(
        architecture: String,
        directoryURL: URL,
        daemonURL: URL,
        mihomoURL: URL
    ) {
        self.architecture = architecture
        self.directoryURL = directoryURL
        self.daemonURL = daemonURL
        self.mihomoURL = mihomoURL
    }
}

public protocol RemoteDeployArtifactResolving: Sendable {
    var bundledArtifactRootURL: URL? { get }
    func artifactBundle(for architecture: String) throws -> RemoteDeployArtifactBundle
    func artifactAvailable(for architecture: String) -> Bool
}

public struct RemoteDeployArtifactResolver: RemoteDeployArtifactResolving, Sendable {
    public static let bundledArtifactsDirectoryName = "RemoteArtifacts"
    public static let daemonBinaryName = "codex-proxyd"
    public static let mihomoBinaryName = "mihomo"

    private let searchRoots: [URL]

    public var bundledArtifactRootURL: URL? {
        self.searchRoots.first
    }

    public init(searchRoot: URL) {
        self.init(searchRoots: [searchRoot])
    }

    public init(searchRoots: [URL] = Self.defaultSearchRoots()) {
        self.searchRoots = searchRoots
    }

    public func artifactBundle(for architecture: String) throws -> RemoteDeployArtifactBundle {
        let normalizedArchitecture = try Self.normalizedArchitectureIdentifier(from: architecture)
        let directoryName = try Self.directoryName(for: normalizedArchitecture)
        let candidates = self.searchRoots.map { root in
            root.appendingPathComponent(directoryName, isDirectory: true)
        }

        let fileManager = FileManager.default
        for directoryURL in candidates {
            let daemonURL = directoryURL.appendingPathComponent(Self.daemonBinaryName)
            let mihomoURL = directoryURL.appendingPathComponent(Self.mihomoBinaryName)
            if fileManager.isExecutableFile(atPath: daemonURL.path),
               fileManager.isExecutableFile(atPath: mihomoURL.path) {
                return RemoteDeployArtifactBundle(
                    architecture: normalizedArchitecture,
                    directoryURL: directoryURL,
                    daemonURL: daemonURL,
                    mihomoURL: mihomoURL
                )
            }
        }

        guard let firstCandidate = candidates.first else {
            throw ProxyError.message(Self.missingBundledArtifactBundleMessage())
        }

        let daemonURL = firstCandidate.appendingPathComponent(Self.daemonBinaryName)
        let mihomoURL = firstCandidate.appendingPathComponent(Self.mihomoBinaryName)
        let missingComponents = [
            (daemonURL, Self.daemonBinaryName),
            (mihomoURL, Self.mihomoBinaryName),
        ].compactMap { url, name in
            fileManager.isExecutableFile(atPath: url.path) ? nil : name
        }

        if missingComponents.isEmpty == false {
            throw ProxyError.message(
                "Incomplete Linux deployment package at \(firstCandidate.path): missing \(missingComponents.joined(separator: ", "))"
            )
        }

        throw ProxyError.message("Missing Linux deployment package at \(firstCandidate.path)")
    }

    public func artifactAvailable(for architecture: String) -> Bool {
        (try? self.artifactBundle(for: architecture)) != nil
    }

    public static func defaultSearchRoots(mainBundle: Bundle = .main) -> [URL] {
        if let override = ProcessInfo.processInfo.environment["CODEX_PROXY_REMOTE_ARTIFACTS_DIR"],
           FileManager.default.fileExists(atPath: override) {
            return [URL(fileURLWithPath: override, isDirectory: true)]
        }

        guard let bundledRoot = self.defaultBundledArtifactRoot(mainBundle: mainBundle) else {
            return []
        }
        return [bundledRoot]
    }

    public static func defaultBundledArtifactRoot(mainBundle: Bundle = .main) -> URL? {
        guard let resourceURL = mainBundle.resourceURL else { return nil }
        let root = resourceURL.appendingPathComponent(Self.bundledArtifactsDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return root
    }

    public static func directoryName(for architecture: String) throws -> String {
        switch try self.normalizedArchitectureIdentifier(from: architecture) {
        case "x86_64":
            return "linux-amd64"
        case "arm64":
            return "linux-arm64"
        default:
            throw ProxyError.message("Unsupported remote architecture: \(self.summarizedArchitectureOutput(architecture))")
        }
    }

    static func canonicalArchitectureIdentifier(from text: String) -> String? {
        let tokens = text.unicodeScalars.split(whereSeparator: Self.isArchitectureTokenSeparator).map(String.init)
        for token in tokens {
            switch token.lowercased() {
            case "x86_64", "amd64":
                return "x86_64"
            case "arm64", "aarch64":
                return "arm64"
            default:
                continue
            }
        }
        return nil
    }

    static func normalizedArchitectureIdentifier(from text: String) throws -> String {
        if let architecture = self.canonicalArchitectureIdentifier(from: text) {
            return architecture
        }
        throw ProxyError.message("Unsupported remote architecture: \(self.summarizedArchitectureOutput(text))")
    }

    static func summarizedArchitectureOutput(_ text: String, maximumLength: Int = 160) -> String {
        let summary = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.isEmpty == false else {
            return "<empty>"
        }
        guard summary.count > maximumLength else {
            return summary
        }
        return String(summary.prefix(maximumLength - 1)) + "…"
    }

    private static func isArchitectureTokenSeparator(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) == false && scalar != "_" && scalar != "-"
    }

    public static func missingBundledArtifactBundleMessage() -> String {
        "Bundled Linux deployment packages are unavailable in this build. Use the remote-capable packaged app built with Scripts/build-macos-app.sh or Scripts/package-release.sh before deploying."
    }
}
