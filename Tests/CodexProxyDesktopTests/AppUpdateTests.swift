#if os(macOS)
import CodexProxyCore
import Crypto
import Foundation
import XCTest
@testable import CodexProxyDesktop

private enum AppUpdateTestError: LocalizedError {
    case simulated

    var errorDescription: String? {
        "simulated update failure"
    }
}

@MainActor
private final class AppUpdateServiceStub: AppUpdateServicing {
    var checkResult: Result<AppUpdateCheckResult, Error>
    var downloadResult: Result<AppUpdateDownloadedPackage, Error>
    private(set) var checkCallCount = 0
    private(set) var downloadCallCount = 0

    init(
        checkResult: Result<AppUpdateCheckResult, Error>,
        downloadResult: Result<AppUpdateDownloadedPackage, Error>? = nil
    ) {
        self.checkResult = checkResult
        self.downloadResult = downloadResult ?? .failure(AppUpdateTestError.simulated)
    }

    func checkForUpdate(
        currentVersion: String,
        architecture: AppUpdateArchitecture
    ) async throws -> AppUpdateCheckResult {
        self.checkCallCount += 1
        return try self.checkResult.get()
    }

    func download(
        package: AppUpdatePackage,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws -> AppUpdateDownloadedPackage {
        self.downloadCallCount += 1
        progress?(0.5)
        return try self.downloadResult.get()
    }
}

@MainActor
private final class AppUpdateInstallerStub: AppUpdateInstalling {
    private(set) var prepareCallCount = 0
    private(set) var launchCallCount = 0
    var prepareError: Error?
    var launchError: Error?

    func prepareInstallation(
        downloadedPackage: AppUpdateDownloadedPackage,
        currentAppURL: URL?
    ) async throws -> AppUpdatePreparedInstallation {
        self.prepareCallCount += 1
        if let prepareError {
            throw prepareError
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AppUpdatePreparedInstallation(
            downloadedPackage: downloadedPackage,
            scriptURL: root.appendingPathComponent("install.sh"),
            currentAppURL: currentAppURL ?? root.appendingPathComponent("AI Coding Proxy.app", isDirectory: true),
            extractedAppURL: root.appendingPathComponent("expanded/AI Coding Proxy.app", isDirectory: true),
            backupURL: root.appendingPathComponent("AI Coding Proxy.previous.app", isDirectory: true)
        )
    }

    func launchInstallation(_ installation: AppUpdatePreparedInstallation) async throws {
        self.launchCallCount += 1
        if let launchError {
            throw launchError
        }
    }
}

private final class AppUpdateMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
        var requests: [URLRequest] = []
    }

    private static let state = State()

    static func setHandler(_ handler: @escaping Handler) {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        self.state.handler = handler
    }

    static func resetHandler() {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        self.state.handler = nil
        self.state.requests = []
    }

    static func recordedRequests() -> [URLRequest] {
        self.state.lock.lock()
        defer { self.state.lock.unlock() }
        return self.state.requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.lock.lock()
        let handler = Self.state.handler
        Self.state.requests.append(self.request)
        Self.state.lock.unlock()

        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class AppUpdateTests: XCTestCase {
    override func tearDown() {
        AppUpdateMockURLProtocol.resetHandler()
        super.tearDown()
    }

    func testSemanticVersionComparisonSupportsVPrefix() {
        XCTAssertGreaterThan(SemanticVersion("1.0.1")!, SemanticVersion("1.0.0")!)
        XCTAssertGreaterThan(SemanticVersion("v1.2.0")!, SemanticVersion("1.1.9")!)
        XCTAssertEqual(SemanticVersion("1.2")!, SemanticVersion("1.2.0")!)
    }

    func testAssetSelectionPrefersFullPackageAndFallsBackToLocalPackage() {
        let full = Self.asset(name: "AICodingProxy-macos-arm64-1.0.1.zip")
        let local = Self.asset(name: "AICodingProxy-macos-arm64-1.0.1-local.zip")
        let release = Self.release(version: "1.0.1", assets: [local, full])

        XCTAssertEqual(release.compatibleAsset(for: .arm64), full)

        let localOnlyRelease = Self.release(version: "1.0.1", assets: [local])
        XCTAssertEqual(localOnlyRelease.compatibleAsset(for: .arm64), local)
        XCTAssertNil(localOnlyRelease.compatibleAsset(for: .x86_64))
    }

    func testCheckForUpdateDecodesGitHubReleaseAndSelectsArchitecture() async throws {
        let service = Self.makeService(json: Self.releaseJSON(version: "1.0.1"))

        let result = try await service.checkForUpdate(currentVersion: "1.0.0", architecture: .arm64)

        guard case .updateAvailable(let package) = result else {
            XCTFail("Expected updateAvailable")
            return
        }
        XCTAssertEqual(package.versionText, "1.0.1")
        XCTAssertEqual(package.asset.name, "AICodingProxy-macos-arm64-1.0.1.zip")
        XCTAssertEqual(package.asset.digest, "sha256:abcdef")
        XCTAssertEqual(package.release.htmlURL?.absoluteString, "https://github.com/shiguanghuxian/aI-coding-proxy/releases/tag/1.0.1")
    }

    func testCheckForUpdateReportsUpToDateForSameVersion() async throws {
        let service = Self.makeService(json: Self.releaseJSON(version: "1.0.0"))

        let result = try await service.checkForUpdate(currentVersion: "1.0.0", architecture: .arm64)

        guard case .upToDate(let release) = result else {
            XCTFail("Expected upToDate")
            return
        }
        XCTAssertEqual(release.versionText, "1.0.0")
    }

    func testManifest200DecodesReleaseAndSelectsArchitecture() async throws {
        let service = Self.makeManifestBackedService(manifestJSON: Self.manifestJSON(version: "1.0.1"))

        let result = try await service.checkForUpdate(currentVersion: "1.0.0", architecture: .arm64)

        guard case .updateAvailable(let package) = result else {
            XCTFail("Expected updateAvailable")
            return
        }
        XCTAssertEqual(package.versionText, "1.0.1")
        XCTAssertEqual(package.asset.name, "AICodingProxy-macos-arm64-1.0.1.zip")
        XCTAssertEqual(package.asset.digest, "sha256:abcdef")
        XCTAssertEqual(package.asset.architecture, .arm64)
        XCTAssertEqual(package.release.htmlURL?.absoluteString, "https://github.com/shiguanghuxian/aI-coding-proxy/releases/tag/1.0.1")
    }

    func testManifest304UsesCachedRelease() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheStore = AppUpdateResponseCacheStore(directory: root)
        let manifestURL = URL(string: "https://updates.example.test/appcast.json")!
        let response = HTTPURLResponse(
            url: manifestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["ETag": #""manifest-v1""#]
        )!
        cacheStore.save(key: "manifest-0", url: manifestURL, response: response, data: Data(Self.manifestJSON(version: "1.0.1").utf8))

        let service = Self.makeManifestBackedService(
            manifestURL: manifestURL,
            manifestStatusCode: 304,
            manifestJSON: "",
            cacheStore: cacheStore
        )

        let result = try await service.checkForUpdate(currentVersion: "1.0.0", architecture: .arm64)

        guard case .updateAvailable(let package) = result else {
            XCTFail("Expected updateAvailable")
            return
        }
        XCTAssertEqual(package.versionText, "1.0.1")
        XCTAssertEqual(AppUpdateMockURLProtocol.recordedRequests().first?.value(forHTTPHeaderField: "If-None-Match"), #""manifest-v1""#)
    }

    func testManifestMissingFallsBackToGitHubAPI() async throws {
        let service = Self.makeManifestBackedService(
            manifestStatusCode: 404,
            manifestJSON: #"{"message":"Not Found"}"#,
            fallbackJSON: Self.releaseJSON(version: "1.0.1")
        )

        let result = try await service.checkForUpdate(currentVersion: "1.0.0", architecture: .arm64)

        guard case .updateAvailable(let package) = result else {
            XCTFail("Expected updateAvailable")
            return
        }
        XCTAssertEqual(package.versionText, "1.0.1")
        let requestedURLs = AppUpdateMockURLProtocol.recordedRequests().compactMap { $0.url?.absoluteString }
        XCTAssertEqual(requestedURLs, [
            "https://updates.example.test/appcast.json",
            "https://updates.example.test/releases/latest",
        ])
    }

    func testGitHubAPIFallbackUsesETagCacheOnSecondRequest() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheStore = AppUpdateResponseCacheStore(directory: root)
        let service = Self.makeService(
            headers: ["ETag": #""github-v1""#],
            json: Self.releaseJSON(version: "1.0.1"),
            cacheStore: cacheStore
        )

        _ = try await service.checkForUpdate(currentVersion: "1.0.0", architecture: .arm64)

        AppUpdateMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), #""github-v1""#)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: nil,
                headerFields: ["ETag": #""github-v1""#]
            )!
            return (response, Data())
        }

        let result = try await service.checkForUpdate(currentVersion: "1.0.0", architecture: .arm64)

        guard case .updateAvailable(let package) = result else {
            XCTFail("Expected updateAvailable from cached GitHub response")
            return
        }
        XCTAssertEqual(package.versionText, "1.0.1")
    }

    func testGitHubRateLimit403ProducesActionableMessage() async throws {
        let service = Self.makeService(
            statusCode: 403,
            headers: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1778466000",
                "X-GitHub-Request-Id": "RATE:LIMIT",
            ],
            json: #"{"message":"API rate limit exceeded for 127.0.0.1.","documentation_url":"https://docs.github.com/rest"}"#
        )
        let model = try Self.makeModel(appUpdateService: service)

        model.checkForAppUpdates(isAutomatic: false)
        try await Self.waitUntil {
            if case .failed = model.appUpdateStatus { return true }
            return false
        }

        let detail = model.banners.first?.detail ?? ""
        XCTAssertTrue(detail.contains("GitHub API 访问频率受限") || detail.contains("rate limit"))
        XCTAssertTrue(detail.contains(FixedDisplayDateTimeFormat.string(from: Date(timeIntervalSince1970: 1_778_466_000))))
        XCTAssertTrue(detail.contains("RATE:LIMIT"))
        XCTAssertTrue(detail.contains("API rate limit exceeded"))
    }

    func testGitHubForbidden403ProducesNetworkRouteSuggestion() async throws {
        let service = Self.makeService(
            statusCode: 403,
            headers: ["X-GitHub-Request-Id": "DENIED:ROUTE"],
            json: #"{"message":"Resource not accessible by integration"}"#
        )
        let model = try Self.makeModel(appUpdateService: service)

        model.checkForAppUpdates(isAutomatic: false)
        try await Self.waitUntil {
            if case .failed = model.appUpdateStatus { return true }
            return false
        }

        let detail = model.banners.first?.detail ?? ""
        XCTAssertTrue(detail.contains("网络出口") || detail.contains("network route"))
        XCTAssertTrue(detail.contains("代理") || detail.contains("proxy"))
        XCTAssertTrue(detail.contains("DENIED:ROUTE"))
        XCTAssertTrue(detail.contains("Resource not accessible"))
    }

    func testGitHubHTTPErrorKeepsStatusAndRequestID() async throws {
        let service = Self.makeService(
            statusCode: 500,
            headers: ["X-GitHub-Request-Id": "SERVER:ERROR"],
            json: #"{"message":"Server error"}"#
        )
        let model = try Self.makeModel(appUpdateService: service)

        model.checkForAppUpdates(isAutomatic: false)
        try await Self.waitUntil {
            if case .failed = model.appUpdateStatus { return true }
            return false
        }

        let detail = model.banners.first?.detail ?? ""
        XCTAssertTrue(detail.contains("HTTP 500"))
        XCTAssertTrue(detail.contains("SERVER:ERROR"))
        XCTAssertTrue(detail.contains("Server error"))
    }

    func testDownloadHTTP403ProducesReadableError() async throws {
        let package = Self.package(version: "1.0.1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        AppUpdateMockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url ?? package.asset.browserDownloadURL,
                statusCode: 403,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "X-GitHub-Request-Id": "DOWNLOAD:403",
                ]
            )!
            return (response, Data(#"{"message":"Download forbidden"}"#.utf8))
        }
        let service = AppUpdateService(session: session)

        do {
            _ = try await service.download(package: package, progress: nil)
            XCTFail("Expected download to throw")
        } catch let error as AppUpdateServiceError {
            guard case .invalidHTTPStatus(let httpError) = error else {
                XCTFail("Expected invalidHTTPStatus")
                return
            }
            XCTAssertEqual(httpError.statusCode, 403)
            XCTAssertEqual(httpError.message, "Download forbidden")
            XCTAssertEqual(httpError.requestID, "DOWNLOAD:403")
        }
    }

    func testChecksumMismatchDeletesDownloadedFile() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("update.zip")
        try Data("hello".utf8).write(to: fileURL)
        let service = AppUpdateService(temporaryDirectory: root)
        let asset = Self.asset(name: "AICodingProxy-macos-arm64-1.0.1.zip", digest: "sha256:0000")

        XCTAssertThrowsError(try service.verifyChecksum(for: fileURL, asset: asset))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testChecksumAcceptsGitHubDigest() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("update.zip")
        let data = Data("hello".utf8)
        try data.write(to: fileURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let service = AppUpdateService(temporaryDirectory: root)
        let asset = Self.asset(name: "AICodingProxy-macos-arm64-1.0.1.zip", digest: "sha256:\(digest)")

        XCTAssertNoThrow(try service.verifyChecksum(for: fileURL, asset: asset))
    }

    func testDesktopPreferencesDecodeOldPayloadDefaultsUpdateFields() throws {
        let data = Data(
            """
            {
              "language_mode": "system",
              "theme_mode": "system",
              "interface_mode": "full",
              "account_pool_display_mode": "cards",
              "shows_menu_bar_token_usage": true
            }
            """.utf8
        )

        let preferences = try Helpers.readJSON(DesktopPreferences.self, from: data)

        XCTAssertTrue(preferences.automaticUpdateChecksEnabled)
        XCTAssertNil(preferences.lastUpdateCheckAt)
    }

    func testAutomaticUpdateCheckRunsAtMostOncePerInterval() async throws {
        let package = Self.package(version: "1.0.1")
        let service = AppUpdateServiceStub(checkResult: .success(.updateAvailable(package)))
        let (preferencesStore, preferencesDirectory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: preferencesDirectory) }
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            appUpdateService: service,
            appUpdateInstaller: AppUpdateInstallerStub(),
            appUpdateTerminateHandler: {},
            confirmInstallUpdateHandler: { _ in .later }
        )
        let now = Date(timeIntervalSince1970: 1_000)
        model.appUpdateNowProvider = { now }

        model.checkForAppUpdatesIfNeededOnLaunch()
        try await Self.waitUntil { service.checkCallCount == 1 }
        model.checkForAppUpdatesIfNeededOnLaunch()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(service.checkCallCount, 1)
        XCTAssertEqual(model.preferences.lastUpdateCheckAt, now)
    }

    func testAutomaticUpdateCheckRespectsDisabledPreference() async throws {
        let service = AppUpdateServiceStub(checkResult: .failure(AppUpdateTestError.simulated))
        let (preferencesStore, preferencesDirectory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: preferencesDirectory) }
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            appUpdateService: service,
            appUpdateInstaller: AppUpdateInstallerStub(),
            appUpdateTerminateHandler: {}
        )
        model.updateAutomaticUpdateChecksEnabled(false)

        model.checkForAppUpdatesIfNeededOnLaunch()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(service.checkCallCount, 0)
    }

    func testManualUpdateCheckPromptsWhenUpdateAvailable() async throws {
        let package = Self.package(version: "1.0.1")
        let service = AppUpdateServiceStub(checkResult: .success(.updateAvailable(package)))
        var promptedPackage: AppUpdatePackage?
        let (preferencesStore, preferencesDirectory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: preferencesDirectory) }
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            appUpdateService: service,
            appUpdateInstaller: AppUpdateInstallerStub(),
            appUpdateTerminateHandler: {},
            confirmInstallUpdateHandler: { package in
                promptedPackage = package
                return .later
            }
        )

        model.checkForAppUpdates(isAutomatic: false)
        try await Self.waitUntil {
            if case .updateAvailable = model.appUpdateStatus { return true }
            return false
        }

        XCTAssertEqual(service.checkCallCount, 1)
        XCTAssertEqual(promptedPackage?.versionText, "1.0.1")
    }

    func testManualUpdateCheckReportsNoUpdateWithFriendlyBanner() async throws {
        let release = Self.release(version: "1.0.0")
        let service = AppUpdateServiceStub(checkResult: .success(.upToDate(release)))
        let (preferencesStore, preferencesDirectory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: preferencesDirectory) }
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            appUpdateService: service,
            appUpdateInstaller: AppUpdateInstallerStub(),
            appUpdateTerminateHandler: {}
        )

        model.checkForAppUpdates(isAutomatic: false)
        try await Self.waitUntil {
            if case .upToDate = model.appUpdateStatus { return true }
            return false
        }

        XCTAssertEqual(model.banners.first?.tone, .success)
        XCTAssertTrue(model.banners.first?.title.contains("最新") == true || model.banners.first?.title.contains("up to date") == true)
    }

    func testDownloadFailurePublishesError() async throws {
        let package = Self.package(version: "1.0.1")
        let service = AppUpdateServiceStub(
            checkResult: .success(.updateAvailable(package)),
            downloadResult: .failure(AppUpdateTestError.simulated)
        )
        let (preferencesStore, preferencesDirectory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: preferencesDirectory) }
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            appUpdateService: service,
            appUpdateInstaller: AppUpdateInstallerStub(),
            appUpdateTerminateHandler: {},
            confirmInstallUpdateHandler: { _ in .install }
        )

        model.checkForAppUpdates(isAutomatic: false)
        try await Self.waitUntil {
            if case .failed = model.appUpdateStatus { return true }
            return false
        }

        XCTAssertEqual(service.downloadCallCount, 1)
        XCTAssertEqual(model.banners.first?.tone, .error)
        XCTAssertEqual(model.banners.first?.detail, "simulated update failure")
    }

    func testInstallSuccessPreparesInstallerAndTerminatesApp() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = Self.package(version: "1.0.1")
        let downloaded = AppUpdateDownloadedPackage(package: package, fileURL: root.appendingPathComponent("update.zip"))
        let service = AppUpdateServiceStub(
            checkResult: .success(.updateAvailable(package)),
            downloadResult: .success(downloaded)
        )
        let installer = AppUpdateInstallerStub()
        var terminateCallCount = 0
        let (preferencesStore, preferencesDirectory) = try Self.makePreferencesStore()
        defer { try? FileManager.default.removeItem(at: preferencesDirectory) }
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            appUpdateService: service,
            appUpdateInstaller: installer,
            appUpdateCurrentAppURLProvider: { root.appendingPathComponent("AI Coding Proxy.app", isDirectory: true) },
            appUpdateTerminateHandler: { terminateCallCount += 1 },
            confirmInstallUpdateHandler: { _ in .install }
        )

        model.checkForAppUpdates(isAutomatic: false)
        try await Self.waitUntil { terminateCallCount == 1 }

        XCTAssertEqual(service.downloadCallCount, 1)
        XCTAssertEqual(installer.prepareCallCount, 1)
        XCTAssertEqual(installer.launchCallCount, 1)
        XCTAssertEqual(terminateCallCount, 1)
    }

    func testInstallerExtractsPackageAndWritesScript() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentAppURL = root.appendingPathComponent("Installed/AI Coding Proxy.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: currentAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let packageRoot = root.appendingPathComponent("Payload", isDirectory: true)
        let appURL = packageRoot.appendingPathComponent("AI Coding Proxy.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/CodexProxyDesktop")
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: executableURL)
        let zipURL = root.appendingPathComponent("update.zip")
        try Self.runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", appURL.path, zipURL.path])

        let package = Self.package(version: "1.0.1")
        let downloaded = AppUpdateDownloadedPackage(package: package, fileURL: zipURL)
        let installer = AppUpdateInstaller(temporaryDirectory: root, processIdentifierProvider: { 123 })

        let prepared = try await installer.prepareInstallation(
            downloadedPackage: downloaded,
            currentAppURL: currentAppURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.extractedAppURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.scriptURL.path))
        let script = try String(contentsOf: prepared.scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("CURRENT_PID"))
        XCTAssertTrue(script.contains("AI Coding Proxy.app"))
    }

    private static func makeService(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        json: String,
        cacheStore: AppUpdateResponseCacheStore = AppUpdateResponseCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    ) -> AppUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let latestURL = URL(string: "https://updates.example.test/releases/latest")!
        AppUpdateMockURLProtocol.setHandler { request in
            var responseHeaders = ["Content-Type": "application/json"]
            for (key, value) in headers {
                responseHeaders[key] = value
            }
            let response = HTTPURLResponse(
                url: request.url ?? latestURL,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: responseHeaders
            )!
            return (response, Data(json.utf8))
        }
        return AppUpdateService(latestReleaseURL: latestURL, session: session, manifestService: nil, cacheStore: cacheStore)
    }

    private static func makeManifestBackedService(
        manifestURL: URL = URL(string: "https://updates.example.test/appcast.json")!,
        manifestStatusCode: Int = 200,
        manifestJSON: String,
        fallbackJSON: String? = nil,
        cacheStore: AppUpdateResponseCacheStore = AppUpdateResponseCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    ) -> AppUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let latestURL = URL(string: "https://updates.example.test/releases/latest")!
        let fallbackPayload = fallbackJSON ?? Self.releaseJSON(version: "1.0.1")
        AppUpdateMockURLProtocol.setHandler { request in
            if request.url == manifestURL {
                let response = HTTPURLResponse(
                    url: manifestURL,
                    statusCode: manifestStatusCode,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "ETag": #""manifest-v1""#,
                    ]
                )!
                return (response, Data(manifestJSON.utf8))
            }

            let response = HTTPURLResponse(
                url: request.url ?? latestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(fallbackPayload.utf8))
        }
        let manifestService = AppUpdateManifestService(
            manifestURLs: [manifestURL],
            session: session,
            cacheStore: cacheStore
        )
        return AppUpdateService(
            latestReleaseURL: latestURL,
            session: session,
            manifestService: manifestService,
            cacheStore: cacheStore
        )
    }

    private static func releaseJSON(version: String) -> String {
        """
        {
          "tag_name": "\(version)",
          "name": "\(version)",
          "draft": false,
          "prerelease": false,
          "html_url": "https://github.com/shiguanghuxian/aI-coding-proxy/releases/tag/\(version)",
          "published_at": "2026-04-28T15:11:11Z",
          "body": "根据自己电脑CPU系统架构下载对应软件包",
          "assets": [
            {
              "name": "AICodingProxy-macos-arm64-\(version)-local.zip",
              "size": 12,
              "digest": "sha256:local",
              "browser_download_url": "https://example.test/AICodingProxy-macos-arm64-\(version)-local.zip"
            },
            {
              "name": "AICodingProxy-macos-arm64-\(version).zip",
              "size": 34,
              "digest": "sha256:abcdef",
              "browser_download_url": "https://example.test/AICodingProxy-macos-arm64-\(version).zip"
            },
            {
              "name": "AICodingProxy-macos-x86_64-\(version)-local.zip",
              "size": 56,
              "digest": "sha256:x86",
              "browser_download_url": "https://example.test/AICodingProxy-macos-x86_64-\(version)-local.zip"
            }
          ]
        }
        """
    }

    private static func manifestJSON(version: String) -> String {
        """
        {
          "version": "\(version)",
          "tag_name": "\(version)",
          "title": "\(version)",
          "published_at": "2026-04-28T15:11:11Z",
          "release_notes": "根据自己电脑CPU系统架构下载对应软件包",
          "html_url": "https://github.com/shiguanghuxian/aI-coding-proxy/releases/tag/\(version)",
          "assets": {
            "arm64": {
              "name": "AICodingProxy-macos-arm64-\(version).zip",
              "download_url": "https://github.com/shiguanghuxian/aI-coding-proxy/releases/download/\(version)/AICodingProxy-macos-arm64-\(version).zip",
              "size": 34,
              "sha256": "abcdef"
            },
            "x86_64": {
              "name": "AICodingProxy-macos-x86_64-\(version).zip",
              "download_url": "https://github.com/shiguanghuxian/aI-coding-proxy/releases/download/\(version)/AICodingProxy-macos-x86_64-\(version).zip",
              "size": 56,
              "digest": "sha256:x86"
            }
          }
        }
        """
    }

    private static func package(version: String) -> AppUpdatePackage {
        let release = Self.release(version: version)
        return AppUpdatePackage(release: release, asset: release.assets[0])
    }

    private static func release(
        version: String,
        assets: [AppUpdateAsset]? = nil
    ) -> AppUpdateRelease {
        let assets = assets ?? [Self.asset(name: "AICodingProxy-macos-arm64-\(version).zip")]
        return AppUpdateRelease(
            version: SemanticVersion(version)!,
            versionText: version,
            tagName: version,
            title: version,
            htmlURL: URL(string: "https://github.com/shiguanghuxian/aI-coding-proxy/releases/tag/\(version)")!,
            publishedAt: Date(timeIntervalSince1970: 1_777_777),
            body: "Release notes",
            assets: assets
        )
    }

    private static func asset(
        name: String,
        digest: String = "sha256:abcdef"
    ) -> AppUpdateAsset {
        AppUpdateAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.test/\(name)")!,
            size: 42,
            digest: digest
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makePreferencesStore() throws -> (DesktopPreferencesStore, URL) {
        let directory = try Self.makeTemporaryDirectory()
        return (DesktopPreferencesStore(dataDirectory: directory), directory)
    }

    private static func makeModel(appUpdateService: AppUpdateServicing) throws -> DesktopAppModel {
        let (preferencesStore, _) = try Self.makePreferencesStore()
        let model = DesktopAppModel(
            preferencesStore: preferencesStore,
            appUpdateService: appUpdateService,
            appUpdateInstaller: AppUpdateInstallerStub(),
            appUpdateTerminateHandler: {}
        )
        model.toastAutoDismissDuration = .seconds(30)
        return model
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @MainActor @escaping () -> Bool
    ) async throws {
        let startedAt = ContinuousClock.now
        while startedAt.duration(to: .now) < timeout {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
#endif
