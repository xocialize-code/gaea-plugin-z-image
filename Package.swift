// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-z-image: Tongyi-MAI's Z-Image and Z-Image Turbo as a Gaea plugin. One worker executable
// built on GaeaPluginKit over z-image-swift, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-z-image",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.2.0"),
        .package(url: "https://github.com/xocialize/z-image-swift.git", exact: "0.5.4"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.72.0"),
    ],
    targets: [
        .executableTarget(
            name: "gaea-z-image-worker",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXZImage", package: "z-image-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
    ]
)
