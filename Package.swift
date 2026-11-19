// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-z-image: Tongyi-MAI's Z-Image and Z-Image Turbo, and NitroFusion2 on Turbo's core, as a Gaea plugin. One
// worker executable built on GaeaPluginKit over z-image-swift, packaged as a signed .gaeaplugin by
// scripts/build-plugin.sh.
//
// zimage-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, lane configuration and request, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-z-image",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.14.1"), // 0.14.1 on: the manifest names the engine actually linked (MLXEngineRelease)
        .package(url: "https://github.com/xocialize/z-image-swift.git", exact: "0.7.1"),
        // mlx-engine-swift 0.82.1, the first on the fleet's mlx-swift 0.33.1 (contract 1.66.0, which only adds imageLocate
        // to the 1.65.0 Gaea 1.9 decodes). Pinned exactly: a later 0.x could add fields to the worker's memory report
        // that GPP v1's closed schema doesn't carry, or a contract Gaea can't decode.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", exact: "0.82.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.82.1 takes it: 0.33.1 is upstream 0.33.0 with the vendored
        // MLX's head-dim-split SDPA routes off, which abort or give wrong attention on M5 (AB-D-0264, AB-R-1009). It
        // replaces the 0.32.4 leak-fix fork (AB-D-0208), whose fix upstream 0.33.0 carries. A root line naming
        // ml-explore's URL would win and drop the patch.
        .package(url: "https://github.com/xocialize/mlx-swift", exact: "0.33.1"),
    ],
    targets: [
        .target(
            name: "ZImagePlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXZImage", package: "z-image-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-z-image-worker",
            dependencies: [
                "ZImagePlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "zimage-inproc",
            dependencies: [
                "ZImagePlugin",
                .product(name: "MLXZImage", package: "z-image-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ZImagePluginTests",
            dependencies: ["ZImagePlugin", .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                           .product(name: "GaeaProtocol", package: "gaea-plugin-kit"), .product(name: "MLXToolKit", package: "mlx-engine-swift")]
        ),
    ]
)
