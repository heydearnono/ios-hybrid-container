// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "mlxtest",
    platforms: [.macOS("14.0"), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4")
    ],
    targets: [
        .target(name: "probe", dependencies: [.product(name: "MLX", package: "mlx-swift")])
    ]
)
