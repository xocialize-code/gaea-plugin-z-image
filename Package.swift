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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.12.0"),
        .package(url: "https://github.com/xocialize/z-image-swift.git", exact: "0.7.1"),
        // Exactly the engine Gaea and GaeaPluginKit 0.12.0 are on: 0.76 adds fields to the worker's memory report that
        // GPP v1's closed schema doesn't carry.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", exact: "0.74.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.74.1 takes it: 0.32.4 is upstream 0.32.3 plus the
        // _updateInternal leak fix (ml-explore/mlx-swift#501; AB-D-0208). A root line naming ml-explore's URL would win.
        .package(url: "https://github.com/xocialize/mlx-swift", exact: "0.32.4"),
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
