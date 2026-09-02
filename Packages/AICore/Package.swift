// swift-tools-version: 6.2
import PackageDescription

// AICore：模型能力抽象层。
//
// 刻意不依赖 UIKit / SwiftUI，也不依赖 FoundationModels —— 这样它能在 macOS 宿主上用
// `swift test` 秒级验证，不需要启动 iOS 模拟器。这是「纯 AI 开发」能否形成快速反馈闭环的关键。
let package = Package(
    name: "AICore",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AICore", targets: ["AICore"]),
    ],
    targets: [
        .target(
            name: "AICore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AICoreTests",
            dependencies: ["AICore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
