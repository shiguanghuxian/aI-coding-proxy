#if os(macOS)
import Foundation

enum AppUpdateArchitecture: String, Sendable, Equatable {
    case arm64
    case x86_64

    static var current: AppUpdateArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .x86_64
        #endif
    }
}

struct SemanticVersion: Comparable, Sendable, Equatable, CustomStringConvertible {
    let components: [Int]
    let original: String

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let versionText = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let core = versionText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.isEmpty == false else { return nil }

        var parsed: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard digits.isEmpty == false, let value = Int(digits) else { return nil }
            parsed.append(value)
        }
        guard parsed.isEmpty == false else { return nil }

        self.components = parsed
        self.original = trimmed
    }

    var description: String {
        self.original
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct AppUpdateAsset: Sendable, Equatable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let digest: String?
    let architecture: AppUpdateArchitecture?

    init(
        name: String,
        browserDownloadURL: URL,
        size: Int64,
        digest: String?,
        architecture: AppUpdateArchitecture? = nil
    ) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
        self.digest = digest
        self.architecture = architecture
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: self.size, countStyle: .file)
    }
}

struct AppUpdateRelease: Sendable, Equatable {
    let version: SemanticVersion
    let versionText: String
    let tagName: String
    let title: String
    let htmlURL: URL?
    let publishedAt: Date?
    let body: String
    let assets: [AppUpdateAsset]

    func compatibleAsset(for architecture: AppUpdateArchitecture) -> AppUpdateAsset? {
        let candidates = self.assets.filter { asset in
            let name = asset.name.lowercased()
            guard name.hasSuffix(".zip") else { return false }
            if let assetArchitecture = asset.architecture {
                return assetArchitecture == architecture
            }
            return name.contains("macos") && name.contains(architecture.rawValue.lowercased())
        }

        return candidates.sorted { left, right in
            let leftScore = Self.assetPreferenceScore(left, versionText: self.versionText)
            let rightScore = Self.assetPreferenceScore(right, versionText: self.versionText)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }.first
    }

    private static func assetPreferenceScore(_ asset: AppUpdateAsset, versionText: String) -> Int {
        let name = asset.name.lowercased()
        var score = 0
        if name.contains(versionText.lowercased()) {
            score += 20
        }
        if name.contains("-local") == false {
            score += 10
        }
        if name.contains("aicodingproxy") {
            score += 4
        }
        return score
    }
}

struct AppUpdatePackage: Sendable, Equatable {
    let release: AppUpdateRelease
    let asset: AppUpdateAsset

    var versionText: String {
        self.release.versionText
    }

    var releaseNotes: String {
        self.release.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AppUpdateDownloadedPackage: Sendable, Equatable {
    let package: AppUpdatePackage
    let fileURL: URL
}

enum AppUpdateCheckResult: Sendable, Equatable {
    case upToDate(AppUpdateRelease)
    case updateAvailable(AppUpdatePackage)
}

enum AppUpdateStatus: Sendable, Equatable {
    case idle
    case checking
    case upToDate(AppUpdateRelease)
    case updateAvailable(AppUpdatePackage)
    case downloading(AppUpdatePackage, progress: Double?)
    case readyToInstall(AppUpdateDownloadedPackage)
    case installing(AppUpdatePackage)
    case failed(String)
}

enum AppUpdatePromptDecision: Sendable, Equatable {
    case install
    case later
    case openReleasePage
}
#endif
