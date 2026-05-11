#if os(macOS)
import CodexProxyCore
import Foundation

struct AppUpdateCachedResponse: Codable, Sendable, Equatable {
    let url: URL
    let eTag: String?
    let lastModified: String?
    let responseData: Data
    let updatedAt: Date
}

final class AppUpdateResponseCacheStore: @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = Paths.defaultDataDirectory().appendingPathComponent("app-update-cache", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func load(key: String, url: URL) -> AppUpdateCachedResponse? {
        let fileURL = self.fileURL(for: key)
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(AppUpdateCachedResponse.self, from: data),
              cached.url == url,
              cached.responseData.isEmpty == false
        else {
            return nil
        }
        return cached
    }

    func save(key: String, url: URL, response: HTTPURLResponse, data: Data) {
        guard data.isEmpty == false else { return }
        let cached = AppUpdateCachedResponse(
            url: url,
            eTag: Self.header("ETag", response: response),
            lastModified: Self.header("Last-Modified", response: response),
            responseData: data,
            updatedAt: Date()
        )
        guard let encoded = try? JSONEncoder().encode(cached) else { return }
        try? Helpers.writeFile(self.fileURL(for: key), data: encoded)
    }

    func clear(key: String) {
        try? self.fileManager.removeItem(at: self.fileURL(for: key))
    }

    private func fileURL(for key: String) -> URL {
        self.directory.appendingPathComponent(Self.safeKey(key) + ".json")
    }

    private static func safeKey(_ key: String) -> String {
        String(key.map { character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        })
    }

    static func header(_ name: String, response: HTTPURLResponse?) -> String? {
        guard let allHeaderFields = response?.allHeaderFields else { return nil }
        for (key, value) in allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(name) == .orderedSame else { continue }
            let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        return nil
    }
}

enum AppUpdateManifestServiceError: Error, Equatable {
    case unavailable
}

struct AppUpdateManifestService {
    static let defaultManifestURLs = [
        URL(string: "https://github.com/shiguanghuxian/aI-coding-proxy/releases/latest/download/appcast.json")!,
        URL(string: "https://github.com/shiguanghuxian/aI-coding-proxy/releases/latest/download/updates.json")!,
    ]

    private let manifestURLs: [URL]
    private let session: URLSession
    private let cacheStore: AppUpdateResponseCacheStore

    init(
        manifestURLs: [URL] = Self.defaultManifestURLs,
        session: URLSession = URLSession(configuration: .ephemeral),
        cacheStore: AppUpdateResponseCacheStore = AppUpdateResponseCacheStore()
    ) {
        self.manifestURLs = manifestURLs
        self.session = session
        self.cacheStore = cacheStore
    }

    var isEnabled: Bool {
        self.manifestURLs.isEmpty == false
    }

    func fetchLatestRelease() async throws -> AppUpdateRelease {
        for (index, url) in self.manifestURLs.enumerated() {
            let cacheKey = "manifest-\(index)"
            do {
                return try await self.fetchManifestRelease(url: url, cacheKey: cacheKey)
            } catch {
                continue
            }
        }
        throw AppUpdateManifestServiceError.unavailable
    }

    private func fetchManifestRelease(url: URL, cacheKey: String) async throws -> AppUpdateRelease {
        let cached = self.cacheStore.load(key: cacheKey, url: url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AI-Coding-Proxy/\(RuntimeInfo.releaseVersion)", forHTTPHeaderField: "User-Agent")
        if let eTag = cached?.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        } else if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateManifestServiceError.unavailable
        }

        if httpResponse.statusCode == 304 {
            guard let cached else {
                self.cacheStore.clear(key: cacheKey)
                return try await self.fetchManifestReleaseWithoutCache(url: url, cacheKey: cacheKey)
            }
            return try Self.decodeRelease(from: cached.responseData)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateManifestServiceError.unavailable
        }

        let release = try Self.decodeRelease(from: data)
        self.cacheStore.save(key: cacheKey, url: url, response: httpResponse, data: data)
        return release
    }

    private func fetchManifestReleaseWithoutCache(url: URL, cacheKey: String) async throws -> AppUpdateRelease {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AI-Coding-Proxy/\(RuntimeInfo.releaseVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw AppUpdateManifestServiceError.unavailable
        }

        let release = try Self.decodeRelease(from: data)
        self.cacheStore.save(key: cacheKey, url: url, response: httpResponse, data: data)
        return release
    }

    static func decodeRelease(from data: Data) throws -> AppUpdateRelease {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(AppUpdateManifestResponse.self, from: data)
        return try manifest.release()
    }
}

private struct AppUpdateManifestResponse: Decodable {
    let version: String?
    let tagName: String?
    let title: String?
    let name: String?
    let publishedAt: String?
    let releaseNotes: String?
    let body: String?
    let htmlURL: URL?
    let releaseURL: URL?
    let assets: AppUpdateManifestAssetCollection?
    let downloads: AppUpdateManifestAssetCollection?

    private enum CodingKeys: String, CodingKey {
        case version
        case tagName
        case tagNameSnake = "tag_name"
        case title
        case name
        case publishedAt
        case publishedAtSnake = "published_at"
        case releaseNotes
        case releaseNotesSnake = "release_notes"
        case body
        case htmlURL = "html_url"
        case releaseURL = "release_url"
        case assets
        case downloads
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(String.self, forKey: .version)
        self.tagName = try container.decodeIfPresent(String.self, forKey: .tagName)
            ?? container.decodeIfPresent(String.self, forKey: .tagNameSnake)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
            ?? container.decodeIfPresent(String.self, forKey: .publishedAtSnake)
        self.releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
            ?? container.decodeIfPresent(String.self, forKey: .releaseNotesSnake)
        self.body = try container.decodeIfPresent(String.self, forKey: .body)
        self.htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
        self.releaseURL = try container.decodeIfPresent(URL.self, forKey: .releaseURL)
        self.assets = try container.decodeIfPresent(AppUpdateManifestAssetCollection.self, forKey: .assets)
        self.downloads = try container.decodeIfPresent(AppUpdateManifestAssetCollection.self, forKey: .downloads)
    }

    func release() throws -> AppUpdateRelease {
        let rawVersion = self.version ?? self.tagName ?? ""
        guard let semanticVersion = SemanticVersion(rawVersion) else {
            throw AppUpdateServiceError.invalidReleaseVersion(rawVersion)
        }

        let entries = (self.assets ?? self.downloads)?.entries ?? []
        let assets = entries.compactMap { entry in
            entry.asset.appUpdateAsset(fallbackArchitecture: AppUpdateArchitecture(rawValue: entry.key ?? ""))
        }
        guard assets.isEmpty == false else {
            throw AppUpdateManifestServiceError.unavailable
        }

        let tagName = self.tagName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? self.tagName ?? rawVersion
            : rawVersion
        let versionText = Self.versionText(from: semanticVersion)
        let title = [self.title, self.name, tagName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false } ?? versionText

        return AppUpdateRelease(
            version: semanticVersion,
            versionText: versionText,
            tagName: tagName,
            title: title,
            htmlURL: self.htmlURL ?? self.releaseURL,
            publishedAt: Self.date(from: self.publishedAt),
            body: self.releaseNotes ?? self.body ?? "",
            assets: assets
        )
    }

    private static func versionText(from version: SemanticVersion) -> String {
        version.description.hasPrefix("v") || version.description.hasPrefix("V")
            ? String(version.description.dropFirst())
            : version.description
    }

    private static func date(from text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

private struct AppUpdateManifestAssetCollection: Decodable {
    struct Entry {
        let key: String?
        let asset: AppUpdateManifestAsset
    }

    let entries: [Entry]

    init(from decoder: Decoder) throws {
        if let array = try? [AppUpdateManifestAsset](from: decoder) {
            self.entries = array.map { Entry(key: nil, asset: $0) }
            return
        }

        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.entries = try container.allKeys.map { key in
            Entry(key: key.stringValue, asset: try container.decode(AppUpdateManifestAsset.self, forKey: key))
        }
    }
}

private struct AppUpdateManifestAsset: Decodable {
    let architecture: String?
    let name: String?
    let url: URL?
    let downloadURL: URL?
    let browserDownloadURL: URL?
    let size: Int64?
    let digest: String?
    let sha256: String?
    let checksum: String?

    private enum CodingKeys: String, CodingKey {
        case architecture
        case arch
        case name
        case url
        case downloadURL
        case downloadURLSnake = "download_url"
        case browserDownloadURL
        case browserDownloadURLSnake = "browser_download_url"
        case size
        case digest
        case sha256
        case checksum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.architecture = try container.decodeIfPresent(String.self, forKey: .architecture)
            ?? container.decodeIfPresent(String.self, forKey: .arch)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.downloadURL = try container.decodeIfPresent(URL.self, forKey: .downloadURL)
            ?? container.decodeIfPresent(URL.self, forKey: .downloadURLSnake)
        self.browserDownloadURL = try container.decodeIfPresent(URL.self, forKey: .browserDownloadURL)
            ?? container.decodeIfPresent(URL.self, forKey: .browserDownloadURLSnake)
        self.size = try container.decodeIfPresent(Int64.self, forKey: .size)
        self.digest = try container.decodeIfPresent(String.self, forKey: .digest)
        self.sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        self.checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
    }

    func appUpdateAsset(fallbackArchitecture: AppUpdateArchitecture?) -> AppUpdateAsset? {
        let downloadURL = self.browserDownloadURL ?? self.downloadURL ?? self.url
        guard let downloadURL else { return nil }

        let resolvedName = self.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? self.name ?? downloadURL.lastPathComponent
            : downloadURL.lastPathComponent
        let architecture = AppUpdateArchitecture(rawValue: self.architecture ?? "") ?? fallbackArchitecture
        return AppUpdateAsset(
            name: resolvedName,
            browserDownloadURL: downloadURL,
            size: self.size ?? 0,
            digest: Self.normalizedDigest(digest: self.digest, sha256: self.sha256, checksum: self.checksum),
            architecture: architecture
        )
    }

    private static func normalizedDigest(digest: String?, sha256: String?, checksum: String?) -> String? {
        for candidate in [digest, sha256, checksum] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard value.isEmpty == false else { continue }
            if value.lowercased().hasPrefix("sha256:") {
                return value
            }
            return "sha256:\(value)"
        }
        return nil
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
#endif
