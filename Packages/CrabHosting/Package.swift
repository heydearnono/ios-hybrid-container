// swift-tools-version:6.0
// 承载逻辑包。M2 起本仓第一个能在宿主 macOS 上秒级跑测试的逻辑都落这里：
// 承载 origin 的唯一定义、路径归一化与越界判定、以及那条「只定义一处」的可执行检查。
//
// 为什么放包里而不是 App target：包内 `swift test` 在宿主 macOS 上秒级返回，
// App target 的逻辑只能靠模拟器构建（分钟级）才验得到。判定下沉到这里才测得起来。
import PackageDescription

let package = Package(
    name: "CrabHosting",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CrabHosting", targets: ["CrabHosting"]),
    ],
    targets: [
        .target(name: "CrabHosting"),
        .testTarget(name: "CrabHostingTests", dependencies: ["CrabHosting"]),
    ]
)
