// spike: app-intents-01 / 3. 手写 AppIntent → FoundationModels.Tool 适配层
//
// 只做 -typecheck（本机跑不了端侧模型，见 docs/01-on-device-llm/foundation-models-overview.md）。
//
// 要回答的问题：iOS 26.2 SDK 里没有官方桥接，那自己写要写多少、写成什么样、
// 哪些地方必然重复。

import AppIntents
import FoundationModels
import Foundation

// MARK: - 被复用的业务逻辑（这一层才是真正该复用的东西）

struct Summarizer: Sendable {
    func summarize(_ text: String, maxWords: Int) -> String {
        text.split(separator: " ").prefix(maxWords).joined(separator: " ")
    }
}

// MARK: - App Intents 侧：给 Siri / Shortcuts / Spotlight 用

enum SummaryStyle: String, AppEnum {
    case terse
    case verbose

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Summary Style" }
    static var caseDisplayRepresentations: [SummaryStyle: DisplayRepresentation] {
        [.terse: "Terse", .verbose: "Verbose"]
    }
}

struct SummarizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Text"
    static let description = IntentDescription("Summarize text into at most N words.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Max Words", default: 5)
    var maxWords: Int

    @Parameter(title: "Style")
    var style: SummaryStyle

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let limit = style == .terse ? min(maxWords, 3) : maxWords
        let out = Summarizer().summarize(text, maxWords: limit)
        return .result(value: out, dialog: IntentDialog(stringLiteral: out))
    }
}

// MARK: - 模型侧：@Generable 参数必须**重新声明一遍**
//
// 这就是「没有官方桥接」的具体代价：同一组参数写两次，
// 一次给 App Intents（@Parameter + LocalizedStringResource 标题），
// 一次给模型（@Generable + @Guide 自然语言描述 + 约束）。
// 两边的约束语言也不通用：@Guide 的 .range 不会同步到 @Parameter，反之亦然。

@Generable
enum ToolSummaryStyle: String {
    case terse
    case verbose
}

// MARK: - 手写适配器（每个 Intent 一个）

struct SummarizeTool: Tool {
    let name = "summarizeText"
    let description = "Summarize text into at most N words."

    @Generable
    struct Arguments {
        @Guide(description: "The text to summarize")
        var text: String

        @Guide(description: "Maximum number of words in the summary", .range(1...50))
        var maxWords: Int

        @Guide(description: "terse for very short, verbose for normal length")
        var style: ToolSummaryStyle
    }

    func call(arguments: Arguments) async throws -> String {
        let intent = SummarizeIntent()
        intent.text = arguments.text
        intent.maxWords = arguments.maxWords
        // 枚举也要手工映射：AppEnum 与 Generable 是两套体系
        intent.style = arguments.style == .terse ? .terse : .verbose

        // 直接在进程内调 perform()。**注意这绕过了系统的 intent 执行环境**：
        // 没有 supportedModes 语义、没有前台续跑、没有用户确认、
        // @Dependency 只有在 App 侧提前 AppDependencyManager.shared.add 过才可用。
        let result = try await intent.perform()

        // ReturnsValue<String> 的 value 是 Optional，要自己兜底
        return result.value ?? ""
    }
}

// MARK: - 反向验证：不带 Intent 的「直接工具」写起来更短

struct DirectSummarizeTool: Tool {
    let name = "summarizeTextDirect"
    let description = "Summarize text into at most N words."

    @Generable
    struct Arguments {
        @Guide(description: "The text to summarize")
        var text: String
        @Guide(description: "Maximum number of words", .range(1...50))
        var maxWords: Int
    }

    func call(arguments: Arguments) async throws -> String {
        Summarizer().summarize(arguments.text, maxWords: arguments.maxWords)
    }
}

// MARK: - 一个类型能不能同时是 AppEnum 和 Generable？（减少重复的可能性）

@Generable
enum DualStyle: String, AppEnum {
    case terse
    case verbose

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Dual Style" }
    static var caseDisplayRepresentations: [DualStyle: DisplayRepresentation] {
        [.terse: "Terse", .verbose: "Verbose"]
    }
}

// MARK: - 泛型适配器为什么做不到
//
// 想写 `struct IntentTool<I: AppIntent>: Tool`，卡在两处：
// 1. `Tool.Arguments` 必须是 `ConvertibleFromGeneratedContent`。`AppIntent` 没有任何
//    关联类型能提供它 —— 参数是 @Parameter 属性包装器，不是一个可被泛型引用的类型。
// 2. 就算把 Arguments 退化成 `GeneratedContent` 并用 `DynamicGenerationSchema` 在运行时
//    造 schema（下面这段编得过），**参数清单仍然得手工喂进来** ——
//    AppIntents 26.2 SDK 里没有公开的运行时 API 能枚举一个 AppIntent 的 @Parameter。
//    赋值也没有 KeyPath 之外的通路。所以「泛型」只是把重复从声明处搬到了描述表里。

struct DynamicIntentTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema

    // 由调用方手工提供：参数名 → 怎么塞回 intent
    let apply: @Sendable (GeneratedContent) async throws -> String

    init(name: String, description: String, properties: [DynamicGenerationSchema.Property],
         apply: @escaping @Sendable (GeneratedContent) async throws -> String) throws {
        self.name = name
        self.description = description
        let root = DynamicGenerationSchema(name: name, description: description, properties: properties)
        self.parameters = try GenerationSchema(root: root, dependencies: [])
        self.apply = apply
    }

    func call(arguments: GeneratedContent) async throws -> String {
        try await apply(arguments)
    }
}

func buildDynamicTool() throws -> DynamicIntentTool {
    try DynamicIntentTool(
        name: "summarizeTextDynamic",
        description: "Summarize text into at most N words.",
        properties: [
            .init(name: "text", description: "The text to summarize",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "maxWords", description: "Maximum number of words",
                  schema: DynamicGenerationSchema(type: Int.self)),
        ],
        apply: { content in
            let intent = SummarizeIntent()
            intent.text = try content.value(String.self, forProperty: "text")
            intent.maxWords = try content.value(Int.self, forProperty: "maxWords")
            intent.style = .verbose
            return try await intent.perform().value ?? ""
        }
    )
}

// MARK: - 装配：工具在 session 创建时传入

@available(iOS 26.0, *)
func makeSession() -> LanguageModelSession {
    LanguageModelSession(tools: [SummarizeTool(), DirectSummarizeTool()]) {
        "需要摘要时调用 summarizeText 工具。"
    }
}
