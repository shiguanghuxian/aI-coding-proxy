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
products.append(.executable(name: "CodexProxyMLXOCRServer", targets: ["CodexProxyMLXOCRServer"]))
targets.append(
    .executableTarget(
        name: "CodexProxyDesktop",
        dependencies: [
            "CodexProxyCore",
            "CodexProxyDeploy",
        ],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("IOKit"),
            .linkedFramework("SwiftUI"),
        ]
    )
)
targets.append(
    .executableTarget(
        name: "CodexProxyMLXOCRServer",
        dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ],
        linkerSettings: [
            .linkedFramework("Network"),
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
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
