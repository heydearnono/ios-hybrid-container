// swift-tools-version: 6.2
import PackageDescription

// AIFeatures：业务逻辑与视图状态。依赖 AICore，不依赖 SwiftUI 视图本身，
// 因此聊天流程可以在没有 UI、没有模拟器的情况下用 `swift test` 验证。
let package = Package(
    name: "AIFeatures",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AIFeatures", targets: ["AIFeatures"]),
    ],
    dependencies: [
        .package(path: "../AICore"),
    ],
    targets: [
        .target(
            name: "AIFeatures",
            dependencies: ["AICore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AIFeaturesTests",
            dependencies: ["AIFeatures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
