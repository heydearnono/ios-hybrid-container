// spike: app-intents-01 / 2. 参数类型系统的边界（负向验证）
//
// 目的：确认 @Parameter 到底能表达什么。每一段都是**故意编不过**的代码，
// 用来把「不能做什么」钉死在编译器输出上，而不是靠推测。
//
// 跑法：逐个取消注释，单独 -typecheck，记录报错。见 README.md。

import AppIntents
import Foundation

// 用来占位的合法 Intent，保证文件本身有内容
struct OKIntent: AppIntent {
    static let title: LocalizedStringResource = "OK"
    @Parameter(title: "Text") var text: String
    func perform() async throws -> some IntentResult { .result() }
}

// MARK: - CASE A：嵌套结构体不能当参数
//
// 期望：`Address` 不符合 `_IntentValue`，编译失败。
// 结论：App Intents 的参数类型是一个**封闭集合**（标量 + Date/URL/Measurement/IntentFile 等
// 系统类型 + AppEnum + AppEntity + 它们的 Optional / Array / Set），
// **没有「任意嵌套 Codable 对象」这一档**。

#if CASE_A
struct Address {
    var city: String
    var street: String
}

struct NestedStructIntent: AppIntent {
    static let title: LocalizedStringResource = "Nested"
    @Parameter(title: "Address") var address: Address   // ← 期望报错
    func perform() async throws -> some IntentResult { .result() }
}
#endif

// MARK: - CASE B：字典不能当参数
//
// 期望：`[String: String]` 不符合 `_IntentValue`，编译失败。

#if CASE_B
struct DictIntent: AppIntent {
    static let title: LocalizedStringResource = "Dict"
    @Parameter(title: "Meta") var meta: [String: String]   // ← 期望报错
    func perform() async throws -> some IntentResult { .result() }
}
#endif

// MARK: - CASE C：嵌套数组（数组的数组）
//
// `Array: _IntentValue where Element: _IntentValue`，而 Array 自己也是 _IntentValue，
// 所以 `[[String]]` 在**类型系统层面**可能满足约束。这一条要实测。

#if CASE_C
struct NestedArrayIntent: AppIntent {
    static let title: LocalizedStringResource = "NestedArray"
    @Parameter(title: "Matrix") var matrix: [[String]]
    func perform() async throws -> some IntentResult { .result() }
}
#endif

// MARK: - CASE D：AppEntity 作为「值对象」直接内联
//
// AppEntity 必须有 id 和 defaultQuery。这里故意不给 defaultQuery，
// 确认「想把普通 struct 当参数就得付出 EntityQuery 的代价」。

#if CASE_D
struct BareEntity: AppEntity {
    var id: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Bare" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
    // 故意不写 static var defaultQuery  ← 期望报错
}
#endif
