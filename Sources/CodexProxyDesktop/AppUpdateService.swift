#if os(macOS)
import CodexProxyCore
import Crypto
import Foundation

enum AppUpdateServiceError: LocalizedError, Equatable {
    case invalidLatestReleaseURL
    case invalidHTTPStatus(AppUpdateHTTPError)
    case invalidReleaseVersion(String)
    case missingCompatibleAsset(AppUpdateArchitecture)
    case missingDigest(String)
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidLatestReleaseURL:
            return "Invalid GitHub release URL."
        case .invalidHTTPStatus(let error):
            return error.summary
        case .invalidReleaseVersion(let tag):
            return "Release version `\(tag)` could not be parsed."
        case .missingCompatibleAsset(let architecture):
            return "No macOS \(architecture.rawValue) update package was found in the latest release."
        case .missingDigest(let name):
            return "The update package `\(name)` does not include a SHA256 digest."
        case .checksumMismatch(let expected, let actual):
            return "The update package checksum did not match. Expected \(expected), got \(actual)."
        }
    }
}

struct AppUpdateHTTPError: Sendable, Equatable {
    struct GitHubErrorBody: Decodable, Sendable, Equatable {
        let message: String?
        let documentationURL: URL?

        private enum CodingKeys: String, CodingKey {
            case message
            case documentationURL = "documentation_url"
        }
    }

    let statusCode: Int
    let message: String?
    let documentationURL: URL?
    let rateLimitLimit: Int?
    let rateLimitRemaining: Int?
    let rateLimitReset: Date?
    let retryAfter: TimeInterval?
    let requestID: String?

    var isRateLimited: Bool {
        if self.rateLimitRemaining == 0 {
            return true
        }
        return self.message?.localizedCaseInsensitiveContains("rate limit") == true
    }

    var retryDate: Date? {
        if let retryAfter {
            return Date().addingTimeInterval(retryAfter)
        }
        return self.rateLimitReset
    }

    var summary: String {
        var parts = ["GitHub returned HTTP \(self.statusCode)."]
        if let message = self.message?.trimmingCharacters(in: .whitespacesAndNewlines), message.isEmpty == false {
            parts.append(message)
        }
        if let requestID, requestID.isEmpty == false {
            parts.append("Request ID: \(requestID)")
        }
        return parts.joined(separator: " ")
    }

    static func make(response: HTTPURLResponse?, data: Data = Data()) -> AppUpdateHTTPError {
        let body = try? JSONDecoder().decode(GitHubErrorBody.self, from: data)
        return AppUpdateHTTPError(
            statusCode: response?.statusCode ?? -1,
            message: body?.message,
            documentationURL: body?.documentationURL,
            rateLimitLimit: Self.integerHeader("X-RateLimit-Limit", response: response),
            rateLimitRemaining: Self.integerHeader("X-RateLimit-Remaining", response: response),
            rateLimitReset: Self.unixDateHeader("X-RateLimit-Reset", response: response),
            retryAfter: Self.timeIntervalHeader("Retry-After", response: response),
            requestID: Self.stringHeader("X-GitHub-Request-Id", response: response)
        )
    }

    private static func stringHeader(_ name: String, response: HTTPURLResponse?) -> String? {
        guard let allHeaderFields = response?.allHeaderFields else { return nil }
        for (key, value) in allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(name) == .orderedSame else { continue }
            let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        return nil
    }

    private static func integerHeader(_ name: String, response: HTTPURLResponse?) -> Int? {
        guard let value = Self.stringHeader(name, response: response) else { return nil }
        return Int(value)
    }

    private static func unixDateHeader(_ name: String, response: HTTPURLResponse?) -> Date? {
        guard let seconds = Self.integerHeader(name, response: response) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func timeIntervalHeader(_ name: String, response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = Self.stringHeader(name, response: response),
              let seconds = TimeInterval(value)
        else {
            return nil
        }
        return seconds
    }
}

@MainActor
protocol AppUpdateServicing {
    func checkForUpdate(
        currentVersion: String,
        architecture: AppUpdateArchitecture
    ) async throws -> AppUpdateCheckResult

    func download(
        package: AppUpdatePackage,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws -> AppUpdateDownloadedPackage
}

struct AppUpdateService: AppUpdateServicing {
    private struct GitHubReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64?
            let digest: String?
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case size
                case digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let draft: Bool
        let prerelease: Bool
        let htmlURL: URL?
        let publishedAt: Date?
        let body: String?
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case draft
            case prerelease
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case body
            case assets
        }
    }

    private let latestReleaseURL: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let manifestService: AppUpdateManifestService?
    private let cacheStore: AppUpdateResponseCacheStore

    init(
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/shiguanghuxian/aI-coding-proxy/releases/latest")!,
        session: URLSession = URLSession(configuration: .ephemeral),
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        manifestService: AppUpdateManifestService? = AppUpdateManifestService(),
        cacheStore: AppUpdateResponseCacheStore = AppUpdateResponseCacheStore()
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.session = session
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.manifestService = manifestService?.isEnabled == true ? manifestService : nil
        self.cacheStore = cacheStore
    }

    func checkForUpdate(
        currentVersion: String = RuntimeInfo.releaseVersion,
        architecture: AppUpdateArchitecture = .current
    ) async throws -> AppUpdateCheckResult {
        let release = try await self.fetchLatestRelease()
        guard let current = SemanticVersion(currentVersion) else {
            throw AppUpdateServiceError.invalidReleaseVersion(currentVersion)
        }

        guard release.version > current else {
            return .upToDate(release)
        }

        guard let asset = release.compatibleAsset(for: architecture) else {
            throw AppUpdateServiceError.missingCompatibleAsset(architecture)
        }

        return .updateAvailable(AppUpdatePackage(release: release, asset: asset))
    }

    func fetchLatestRelease() async throws -> AppUpdateRelease {
        if let manifestService {
            do {
                return try await manifestService.fetchLatestRelease()
            } catch {
            }
        }

        return try await self.fetchLatestGitHubRelease()
    }

    private func fetchLatestGitHubRelease() async throws -> AppUpdateRelease {
        let cacheKey = "github-latest-release"
        let cached = self.cacheStore.load(key: cacheKey, url: self.latestReleaseURL)
        var request = URLRequest(url: self.latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AI-Coding-Proxy/\(RuntimeInfo.releaseVersion)", forHTTPHeaderField: "User-Agent")
        if let eTag = cached?.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        } else if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateServiceError.invalidHTTPStatus(AppUpdateHTTPError.make(response: nil, data: data))
        }
        if httpResponse.statusCode == 304 {
            guard let cached else {
                self.cacheStore.clear(key: cacheKey)
                return try await self.fetchLatestGitHubReleaseWithoutCache(cacheKey: cacheKey)
            }
            return try Self.decodeGitHubRelease(from: cached.responseData)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateServiceError.invalidHTTPStatus(AppUpdateHTTPError.make(response: httpResponse, data: data))
        }

        let release = try Self.decodeGitHubRelease(from: data)
        self.cacheStore.save(key: cacheKey, url: self.latestReleaseURL, response: httpResponse, data: data)
        return release
    }

    private func fetchLatestGitHubReleaseWithoutCache(cacheKey: String) async throws -> AppUpdateRelease {
        var request = URLRequest(url: self.latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AI-Coding-Proxy/\(RuntimeInfo.releaseVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateServiceError.invalidHTTPStatus(AppUpdateHTTPError.make(response: nil, data: data))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateServiceError.invalidHTTPStatus(AppUpdateHTTPError.make(response: httpResponse, data: data))
        }

        let release = try Self.decodeGitHubRelease(from: data)
        self.cacheStore.save(key: cacheKey, url: self.latestReleaseURL, response: httpResponse, data: data)
        return release
    }

    private static func decodeGitHubRelease(from data: Data) throws -> AppUpdateRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubReleaseResponse.self, from: data)
        guard release.draft == false, release.prerelease == false else {
            throw AppUpdateServiceError.invalidReleaseVersion(release.tagName)
        }

        guard let version = SemanticVersion(release.tagName) else {
            throw AppUpdateServiceError.invalidReleaseVersion(release.tagName)
        }

        return AppUpdateRelease(
            version: version,
            versionText: version.description.hasPrefix("v") || version.description.hasPrefix("V")
                ? String(version.description.dropFirst())
                : version.description,
            tagName: release.tagName,
            title: release.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? release.name ?? release.tagName
                : release.tagName,
            htmlURL: release.htmlURL,
            publishedAt: release.publishedAt,
            body: release.body ?? "",
            assets: release.assets.map { asset in
                AppUpdateAsset(
                    name: asset.name,
                    browserDownloadURL: asset.browserDownloadURL,
                    size: asset.size ?? 0,
                    digest: asset.digest,
                    architecture: nil
                )
            }
        )
    }

    func download(
        package: AppUpdatePackage,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> AppUpdateDownloadedPackage {
        let workDirectory = self.temporaryDirectory
            .appendingPathComponent("ai-coding-proxy-update-\(UUID().uuidString)", isDirectory: true)
        try self.fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let destinationURL = workDirectory.appendingPathComponent(package.asset.name)

        var request = URLRequest(url: package.asset.browserDownloadURL)
        request.httpMethod = "GET"
        request.setValue("AI-Coding-Proxy/\(RuntimeInfo.releaseVersion)", forHTTPHeaderField: "User-Agent")

        let (downloadedURL, response) = try await self.session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateServiceError.invalidHTTPStatus(AppUpdateHTTPError.make(response: nil))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let data = (try? Data(contentsOf: downloadedURL)) ?? Data()
            throw AppUpdateServiceError.invalidHTTPStatus(AppUpdateHTTPError.make(response: httpResponse, data: data))
        }

        try? self.fileManager.removeItem(at: destinationURL)
        try self.fileManager.moveItem(at: downloadedURL, to: destinationURL)
        try self.verifyChecksum(for: destinationURL, asset: package.asset)
        progress?(1.0)
        return AppUpdateDownloadedPackage(package: package, fileURL: destinationURL)
    }

    func verifyChecksum(for fileURL: URL, asset: AppUpdateAsset) throws {
        guard let digest = asset.digest?.trimmingCharacters(in: .whitespacesAndNewlines),
              digest.lowercased().hasPrefix("sha256:")
        else {
            throw AppUpdateServiceError.missingDigest(asset.name)
        }

        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        let actual = try Self.sha256HexDigest(for: fileURL)
        guard expected == actual else {
            try? self.fileManager.removeItem(at: fileURL)
            throw AppUpdateServiceError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    static func sha256HexDigest(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard chunk.isEmpty == false else { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
