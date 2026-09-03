// swift-tools-version: 6.2
import PackageDescription

// spike: app-intents-01 / HostTest
//
// 要回答的问题：**把 AppIntent 定义在 SPM 包里，还能不能用 `swift test` 在宿主 macOS 上
// 秒级验证？** 这是本项目的核心工程约束（CLAUDE.md「代码」一节）。
//
// AppIntents 框架是 macOS 13+，所以理论上宿主 macOS 15.7.3 能跑。
// FoundationModels 是 macOS 26+，宿主跑不了 —— 所以这个包**刻意不 import FoundationModels**。
let package = Package(
    name: "IntentKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "IntentKit", targets: ["IntentKit"]),
    ],
    targets: [
        .target(name: "IntentKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "IntentKitTests",
            dependencies: ["IntentKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
