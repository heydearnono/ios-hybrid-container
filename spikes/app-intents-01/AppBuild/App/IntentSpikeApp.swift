import AppIntents
import IntentKit
import SwiftUI

// spike: app-intents-01 / AppBuild
//
// 薄壳。唯一的作用是让 xcodebuild 把 IntentKit 包链进来，
// 看看构建期元数据抽取会不会把包里的 SummarizeIntent 也一起抽出来。

@main
struct IntentSpikeApp: App {
    var body: some Scene {
        WindowGroup { Text("intent spike") }
    }
}

/// App 侧必须再声明一个 AppIntentsPackage，把包侧的 AppIntentsPackage 列进来。
/// 这是「Intent 定义在包里」的官方装配方式（Xcode 26.2 随附文档
/// AppIntents-Updates.md 的 "Swift Package Support" 一节）。
///
/// 用 `-D NO_PACKAGE_DECL` 重新构建可以对照：去掉这段声明后，
/// 包里的 Intent 还会不会进 App 的 Metadata.appintents。
#if !NO_PACKAGE_DECL
struct AppPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [IntentKitPackage.self]
    }
}
#endif

/// 顺便注册一个 App Shortcut，验证包里的 Intent 能不能被 AppShortcutsProvider 引用。
struct SpikeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SummarizeIntent(),
            phrases: ["Summarize with \(.applicationName)"],
            shortTitle: "Summarize",
            systemImageName: "text.append"
        )
    }
}

/// 对照组：定义在 App target 里的 Intent。
/// 用来在元数据产物里区分「包里抽到了」和「只有 App target 抽到了」。
struct AppTargetPingIntent: AppIntent {
    static let title: LocalizedStringResource = "App Target Ping"
    func perform() async throws -> some IntentResult { .result() }
}
