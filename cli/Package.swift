// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Millfolio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Vendored zstd decompressor (decoder-only amalgamation), statically
        // linked so we never need a system `zstd`/`libzstd` — see Sources/CZstd.
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            sources: ["zstddeclib.c"],
            publicHeadersPath: "include"
        ),
        // Shared engine-lifecycle logic: install/build/start the millfolio inference
        // server + enclave + the millfolio vault. The same Bootstrapper the millfolio
        // app uses (it installs into the shared ~/Library/Application Support/Millfolio
        // tree + the me.millfolio.server launchd job), so the `millfolio` and `millfolio`
        // CLIs interoperate on one server.
        .target(
            name: "MillfolioCore",
            dependencies: ["CZstd"],
            path: "Sources/MillfolioCore"
        ),
        // The millfolio CLI. There is no companion .app, so the binary is named
        // `mill` directly; the Homebrew formula installs it as `mill`.
        .executableTarget(
            name: "mill",
            dependencies: [
                "MillfolioCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/mill"
        ),
    ]
)
