// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "CodexProxyCore", targets: ["CodexProxyCore"]),
    .library(name: "CodexProxyDeploy", targets: ["CodexProxyDeploy"]),
    .executable(name: "codex-proxyd", targets: ["CodexProxyDaemon"]),
]

var targets: [Target] = [
    .target(
        name: "CSQLite3",
        path: "Sources/SQLite3",
        publicHeadersPath: "include"
    ),
    .target(
        name: "CodexProxyCore",
        dependencies: [
            "CSQLite3",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ],
        linkerSettings: [
            .linkedFramework("Security", .when(platforms: [.macOS])),
            .linkedFramework("CryptoKit", .when(platforms: [.macOS])),
        ]
    ),
    .target(
        name: "CodexProxyDeploy",
        dependencies: ["CodexProxyCore"]
    ),
    .executableTarget(
        name: "CodexProxyDaemon",
        dependencies: [
            "CodexProxyCore",
            "CodexProxyDeploy",
            .product(name: "Hummingbird", package: "hummingbird"),
        ],
        linkerSettings: [
        ]
    ),
    .testTarget(
        name: "CodexProxyCoreTests",
        dependencies: [
            "CodexProxyCore",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTesting", package: "hummingbird"),
        ]
    ),
    .testTarget(
        name: "CodexProxyDaemonTests",
        dependencies: [
            "CodexProxyCore",
            "CodexProxyDaemon",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
        ]
    ),
    .testTarget(
        name: "CodexProxyDeployTests",
        dependencies: [
            "CodexProxyCore",
            "CodexProxyDeploy",
        ]
    ),
]

#if os(macOS)
products.append(.executable(name: "CodexProxyDesktop", targets: ["CodexProxyDesktop"]))
targets.append(
    .executableTarget(
        name: "CodexProxyDesktop",
        dependencies: [
            "CodexProxyCore",
            "CodexProxyDeploy",
        ],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
        ]
    )
)
targets.append(
    .testTarget(
        name: "CodexProxyDesktopTests",
        dependencies: ["CodexProxyDesktop", "CodexProxyCore", "CodexProxyDeploy"]
    )
)
#endif

let package = Package(
    name: "codex-proxy",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.4.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.22.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.33.1"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
