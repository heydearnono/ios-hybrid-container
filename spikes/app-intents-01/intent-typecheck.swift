// spike: app-intents-01 / 1. App Intents 核心形态在 iOS 26.2 SDK 上的签名核对
//
// 只做 -typecheck，不需要模拟器。跑法见同目录 README.md。
//
// 目的：确认 AppIntent / @Parameter / AppEntity / AppEnum / AppShortcutsProvider /
// perform() 返回类型体系在 iOS 26.2 SDK 上的真实写法（官网文档已切到 iOS 27）。

import AppIntents
import Foundation

// MARK: - AppEnum：枚举参数（唯一的「结构化」参数之一）

enum NoteFormat: String, AppEnum {
    case plain
    case markdown

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Note Format" }
    static var caseDisplayRepresentations: [NoteFormat: DisplayRepresentation] {
        [.plain: "Plain", .markdown: "Markdown"]
    }
}

// MARK: - AppEntity：唯一的「对象参数」，但必须有 id + EntityQuery

struct NoteEntity: AppEntity {
    var id: String
    var title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Note" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    static var defaultQuery: NoteQuery { NoteQuery() }
}

struct NoteQuery: EntityQuery {
    // 系统按 id 反查实体 —— 模型/Siri 只传 id，实体本身由 App 侧解析。
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        identifiers.map { NoteEntity(id: $0, title: "note-\($0)") }
    }
}

// MARK: - 1. 最简 AppIntent：只返回「做完了」

struct PingIntent: AppIntent {
    static let title: LocalizedStringResource = "Ping"

    func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - 2. 带参数 + 返回值 + 对话文本（Agent 工具最关心的形态）

struct SummarizeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Note"
    static let description = IntentDescription("Summarize a note into one sentence.")

    // iOS 26 新增：openAppWhenRun 被 supportedModes 取代（旧属性已 deprecated: 26.0）
    static let supportedModes: IntentModes = .background

    // 标量参数
    @Parameter(title: "Text")
    var text: String

    // 可选参数：Optional 走 `Swift.Optional: _IntentValue` 条件conformance
    @Parameter(title: "Max Words")
    var maxWords: Int?

    // 枚举参数
    @Parameter(title: "Format")
    var format: NoteFormat

    // 数组参数：Array 走 `Swift.Array: _IntentValue where Element: _IntentValue`
    @Parameter(title: "Tags")
    var tags: [String]

    // 实体参数：能表达「对象」，但只能靠 id + EntityQuery
    @Parameter(title: "Note")
    var note: NoteEntity

    // perform() 的返回类型是「协议组合」而不是具体类型：
    // ReturnsValue<T> 提供机器可读的返回值，ProvidesDialog 提供给用户/Siri 念的话。
    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let summary = "summary of \(note.title) [\(format.rawValue)] tags=\(tags.count) max=\(maxWords ?? 0) len=\(text.count)"
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - 3. 只返回值，不带对话

struct CountNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Count Notes"

    func perform() async throws -> some ReturnsValue<Int> {
        .result(value: 42)
    }
}

// MARK: - 4. 返回实体（Agent 需要「拿到结构化结果再继续推理」时用）

struct FindNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Note"

    @Parameter(title: "Keyword")
    var keyword: String

    func perform() async throws -> some ReturnsValue<NoteEntity> {
        .result(value: NoteEntity(id: "1", title: keyword))
    }
}

// MARK: - 5. AppShortcutsProvider：注册到 Shortcuts / Siri 的入口

struct SpikeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SummarizeNoteIntent(),
            phrases: ["Summarize a note with \(.applicationName)"],
            shortTitle: "Summarize",
            systemImageName: "text.append"
        )
    }
}

// MARK: - 6. AppIntentsPackage：让「定义在 SPM 包里的 Intent」被宿主 App 发现
//
// 包侧声明一个空的 AppIntentsPackage，App 侧再用 includedPackages 把它列进来。

public struct SpikeKitPackage: AppIntentsPackage {}

struct SpikeAppPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [SpikeKitPackage.self]
    }
}

// MARK: - 7. AssistantSchema：iOS 26 里 @AssistantIntent 已改名为 @AppIntent(schema:)
//
// 注意 @AssistantIntent(schema:) 在 26.2 SDK 上标了
// `@available(*, deprecated, renamed: "AppIntent")`。

@AppIntent(schema: .system.search)
struct SpikeSearchIntent {
    @Parameter(title: "Criteria")
    var criteria: StringSearchCriteria

    func perform() async throws -> some IntentResult {
        .result()
    }
}
