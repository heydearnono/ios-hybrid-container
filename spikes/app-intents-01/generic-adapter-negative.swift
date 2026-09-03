// spike: app-intents-01 / 4. 泛型适配器的负向验证
//
// 目的：证明「写一个泛型 `IntentTool<I: AppIntent>` 自动把任意 Intent 变成模型工具」
// 在 iOS 26.2 SDK 上做不到，而不是我没想到写法。
//
// 跑法：-D CASE_GENERIC 单独 -typecheck，记录报错。

import AppIntents
import FoundationModels
import Foundation

struct PlaceholderIntent: AppIntent {
    static let title: LocalizedStringResource = "Placeholder"
    @Parameter(title: "Text") var text: String
    func perform() async throws -> some ReturnsValue<String> { .result(value: text) }
}

// MARK: - CASE_GENERIC：把 Intent 的参数类型当作 Tool.Arguments
//
// 期望：编译失败。AppIntent 协议里没有任何关联类型描述「参数集合」，
// 所以 Tool.Arguments 无从推导。

#if CASE_GENERIC
struct IntentTool<I: AppIntent>: Tool {
    var name: String { "\(I.self)" }
    var description: String { "\(I.description?.descriptionText ?? "")" }

    // 想写成 I 的参数类型 —— 但 AppIntent 没有这样的关联类型。
    // 只能瞎猜一个名字，编译器会告诉我们它不存在。
    typealias Arguments = I.Parameters      // ← 期望报错：AppIntent 没有 Parameters

    func call(arguments: Arguments) async throws -> String { "" }
}
#endif

// MARK: - CASE_RESULT：PerformResult 也不是 Generable
//
// 期望：编译失败。Tool.Output 要求 PromptRepresentable，
// 而 AppIntent.PerformResult 只要求 IntentResult，两者无交集。

#if CASE_RESULT
struct ResultPassthroughTool<I: AppIntent>: Tool {
    let name = "x"
    let description = "x"

    @Generable
    struct Arguments { var dummy: String }

    func call(arguments: Arguments) async throws -> I.PerformResult {   // ← 期望报错
        try await I().perform()
    }
}
#endif

// MARK: - CASE_INTENT_AS_TOOL：让 Intent 直接同时符合两个协议
//
// 期望：编译失败或需要补全大量成员。AppIntent 要 perform()，Tool 要 call(arguments:)，
// 名字/签名都不同，不存在「一个方法满足两边」的写法。

#if CASE_INTENT_AS_TOOL
struct DualIntent: AppIntent, Tool {
    static let title: LocalizedStringResource = "Dual"
    let description = "dual"

    @Parameter(title: "Text") var text: String

    func perform() async throws -> some ReturnsValue<String> { .result(value: text) }
    // 故意不实现 Tool.call(arguments:) 和 Arguments  ← 期望报错
}
#endif
