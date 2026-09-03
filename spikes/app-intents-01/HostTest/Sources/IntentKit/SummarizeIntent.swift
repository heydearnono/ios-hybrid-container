import AppIntents
import Foundation

// spike: app-intents-01 —— 一个定义在 SPM 包里的 AppIntent。
//
// 关键点：这里既 import AppIntents，又能在宿主 macOS 上被 `swift test` 直接跑，
// 因为 AppIntents 是 macOS 13+ 的框架，且业务逻辑本身不依赖系统的 intent 执行环境。

/// 被 Intent 包装的**纯业务逻辑**。真实项目里这一层应该在 AICore / AIFeatures 里，
/// 与 App Intents 完全解耦 —— Intent 只是它的一个 adapter。
public struct Summarizer: Sendable {
    public init() {}

    public func summarize(_ text: String, maxWords: Int) -> String {
        let words = text.split(separator: " ").prefix(maxWords)
        return words.joined(separator: " ")
    }
}

public enum SummaryStyle: String, AppEnum {
    case terse
    case verbose

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Summary Style" }
    public static var caseDisplayRepresentations: [SummaryStyle: DisplayRepresentation] {
        [.terse: "Terse", .verbose: "Verbose"]
    }
}

public struct SummarizeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Summarize Text"
    public static let description = IntentDescription("Summarize text into at most N words.")

    @Parameter(title: "Text")
    public var text: String

    @Parameter(title: "Max Words", default: 5)
    public var maxWords: Int

    @Parameter(title: "Style")
    public var style: SummaryStyle

    public init() {}

    public func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let limit = style == .terse ? min(maxWords, 3) : maxWords
        let out = Summarizer().summarize(text, maxWords: limit)
        return .result(value: out, dialog: IntentDialog(stringLiteral: out))
    }
}

/// 让宿主 App 能发现本包内的 Intent（`AppIntentsPackage`，iOS 17 / macOS 14 起）。
/// App 侧还要再声明一个 `AppIntentsPackage`，把它列进 `includedPackages`。
public struct IntentKitPackage: AppIntentsPackage {}
