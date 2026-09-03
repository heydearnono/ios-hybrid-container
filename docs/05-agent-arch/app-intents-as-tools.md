# App Intents 能否复用为 Agent 的工具层

- **更新时间**：2026-09-03
- **适用版本**：iOS 26.2 SDK（`AppIntents` user-module-version 300.2.3.1，
  `FoundationModels` 1.1.7）/ Xcode 26.2（17C52）/ Swift 6.2.3
- **验证方式**：本机 `.swiftinterface` 逐条核对 + `swiftc -typecheck`（正向与负向）+
  宿主 `swift test` + `xcodebuild` 产物解包。
  **无真机**；宿主 macOS 15.7.3 没有 Apple Intelligence，iOS 26.2 模拟器复用宿主模型资源，
  所以所有涉及**模型实际调用**和**系统 intent 执行环境**的行为一律未实测
  （见 [`foundation-models-overview.md`](../01-on-device-llm/foundation-models-overview.md)）
- **相关 spike**：[`spikes/app-intents-01/`](../../spikes/app-intents-01/)

## 一句话结论

**不能直接复用，只能部分复用 —— 复用业务逻辑，不复用参数声明。**
iOS 26.2 SDK 里**不存在**任何官方桥接能把一个 `AppIntent` 注册成 `FoundationModels.Tool`，
必须为每个 Intent 手写适配器，并把参数用 `@Generable` + `@Guide` **重新声明一遍**。
好消息是本项目最担心的那条代价不成立：**App Intents 不会把业务逻辑逼进 App target**，
包内定义的 Intent 既能被宿主 `swift test` 秒级测试，也照样进构建期元数据。

## 能做什么

- **把 Intent 定义在 SPM 包里，并在宿主上直接测**。包侧声明 `AppIntentsPackage`，
  App 侧再声明一个把它列进 `includedPackages`，即完成装配
  （Xcode 26.2 随附的 Apple 官方文档 `AppIntents-Updates.md` 的 "Swift Package Support" 一节，
  路径见「参考来源」）。实测包内 `SummarizeIntent` 在 macOS 15.7.3 上 `swift test` 4/4 通过，
  含 `await intent.perform()` 并断言 `result.value`。
  顺带说明：26.2 SDK 里**没有** `AppIntentsTesting` 框架（那是 iOS 27 才有的），
  所以在 26.2 上测 Intent 就只能这么做 —— 在包的单元测试里直接调 `perform()`。
- **构建期元数据抽取覆盖包 target**。`xcodebuild` 的 `ExtractAppIntentsMetadata` 阶段会把包里的
  Intent 一并抽出。产物 `IntentSpike.app/Metadata.appintents/extract.actionsdata` 的
  `actions` 字典里，包内与 App target 的 Intent 并列：

  ```
  AppTargetPingIntent => IntentSpike.AppTargetPingIntent | params: []
  SummarizeIntent     => IntentKit.SummarizeIntent       | params: ['text','maxWords','style']
  enums: [('SummaryStyle', 'IntentKit.SummaryStyle')]
  ```

  `root.ssu.yaml` 里包内 Intent 的 App Shortcut 语音短语也在。
- **一个枚举可以同时服务两边**。`@Generable enum DualStyle: String, AppEnum { ... }` 编译通过 ——
  枚举层的重复声明可以省掉（这是唯一能省的一层，见下节）。
- **进程内直接 `await intent.perform()`**，不经过系统。这是手写适配器的技术基础：
  `perform()` 是普通的 `async throws` 方法，没有任何环境前置要求。
- **`@AppIntent(schema:)` 让 Intent 成为 Siri 模型的工具**。这是官方唯一存在的
  「Intent → 模型工具」通路：Apple 的原话是 "when an App Intent adopts an intent schema,
  it becomes available as a tool **to the Siri model**"（WWDC26 session 347）。
  注意主语是 Siri 的模型，不是你的 `LanguageModelSession`。
- iOS 26 新增的执行语义可直接用：`supportedModes`（`.background` /
  `.foreground(.immediate/.deferred/.dynamic)`）、`continueInForeground(alwaysConfirm:)`、
  `requestChoice(between:dialog:)`、`authenticationPolicy`、`@ComputedProperty` / `@DeferredProperty`。

## 不能做什么 / 边界

### 1. 没有官方桥接（本题的核心答案）

**iOS 26.2 SDK 里没有任何 API 能把 `AppIntent` 注册为 `FoundationModels.Tool`。**
五条独立证据：

| 证据 | 内容 |
| --- | --- |
| `AppIntents.swiftinterface`（13301 行） | `FoundationModels` / `Generable` / `LanguageModelSession` 出现次数均为 **0** |
| `FoundationModels.swiftinterface` | "intent"（忽略大小写）出现次数为 **0**；import 列表只有 BackgroundAssets / CoreGraphics / Foundation / Observation / Swift / _Concurrency / _StringProcessing / _SwiftConcurrencyShims |
| SDK 全局 | iPhoneOS26.2.sdk 里与 AppIntents 相关的框架只有 `AppIntents.framework` 加四个 cross-import overlay（`_AppIntents_SwiftUI`、`_AppIntents_UIKit`、`_GeoToolbox_AppIntents`、`_Photos_AppIntents`），**没有** `_FoundationModels_AppIntents` / `_AppIntents_FoundationModels`；全 SDK 只有 FoundationModels 自身的 `.swiftinterface` 提到 FoundationModels |
| 官方文档 | App Intents 文档的 Apple Intelligence 总入口页全页零处提及 FoundationModels（见「参考来源」） |
| 编译器 | 泛型 `IntentTool<I: AppIntent>: Tool` 写不出来（下面第 3 条） |

Apple 自己也是这么划分的。WWDC26 session 347 原话：

> Our platform lets you create agentic experiences using either the Foundation Models framework
> to design your own agent, **or** the App Intents framework to let your app work with Siri.

两条路，不是一条路的两种写法。**这个缺口在下一个版本也没补上**：WWDC26 session 241 介绍
FoundationModels 新增的内建工具，是 `BarcodeReaderTool`、`OCRTool` 和一个 Spotlight 驱动的
搜索工具 —— 没有 App Intents 工具。所以不要指望「等下一版就有了」。

### 2. 参数必须写两遍，这是最主要的复用成本

`@Parameter` 和 `@Generable` 是两套互不相通的体系：

| | App Intents 侧 | 模型侧 |
| --- | --- | --- |
| 声明 | `@Parameter(title:)` | `@Generable` struct + `@Guide(description:)` |
| 描述文本 | `LocalizedStringResource`，给**人**看的短标题 | 自然语言句子，给**模型**看的语义说明 |
| 约束 | `IntentParameter` 的 `optionsProvider` / resolver | `@Guide` 的 `.range(1...50)` 等 |
| 是否互通 | **否**。`@Guide` 的 `.range` 不会同步到 `@Parameter`，反之亦然 |

也就是说「复用」实际能复用的只有**业务逻辑那一层**（本例中的 `Summarizer`），
而那一层本来就该抽在 `Packages/` 里，跟 App Intents 无关。反过来看更清楚：
不套 Intent 的 `DirectSummarizeTool` 比套 Intent 的 `SummarizeTool` 更短
（[`intent-tool-adapter.swift`](../../spikes/app-intents-01/intent-tool-adapter.swift)）。

唯一能省的是枚举：`@Generable enum X: String, AppEnum` 双协议一致性成立。

### 3. 泛型适配器做不到，重复无法用抽象消掉

想写「一个 `IntentTool<I: AppIntent>` 自动适配所有 Intent」，卡在两处硬限制
（[`generic-adapter-negative.swift`](../../spikes/app-intents-01/generic-adapter-negative.swift)，三个 case 全部 EXIT=1）：

- **`AppIntent` 没有任何关联类型描述「参数集合」**。参数是 `@propertyWrapper final public class
  IntentParameter<Value>` 属性包装器，不是一个能被泛型引用的类型。
  `typealias Arguments = I.Parameters` 报 `'Parameters' is not a member type of type 'I'`。
  `AppIntent` 的关联类型只有 `PerformResult: IntentResult` 和 `SummaryContent: ParameterSummary`。
- **返回类型也不通**。`Tool.Output` 要 `PromptRepresentable`，`AppIntent.PerformResult` 只要
  `IntentResult`，两者无交集 → `type 'ResultPassthroughTool<I>' does not conform to protocol 'Tool'`。

退一步用 `GeneratedContent` + `DynamicGenerationSchema` 在运行时造 schema 是编得过的，
但**参数清单仍然得手工喂进来** —— AppIntents 26.2 SDK 里没有公开的运行时 API 能枚举一个
`AppIntent` 的 `@Parameter` 列表，赋值也没有 KeyPath 之外的通路。所谓「泛型方案」只是把重复
从声明处搬到了描述表里，总量不变。

### 4. `@Parameter` 的类型表达力是一个**封闭集合**

`IntentParameter<Value>` 要求 `Value: _IntentValue`。`_IntentValue` 的一致性在 26.2 SDK 里
是穷举的：`String` / `Int` / `Double` / `Bool` / `URL` / `Date` / `DateComponents` /
`Measurement` / `AttributedString` / `Calendar.RecurrenceRule` / `NSNull` / `CLPlacemark` /
`IntentFile` / `IntentPerson` / `IntentCurrencyAmount` / `IntentPaymentMethod` /
`EntityIdentifier` / `Never`，加上条件一致性 `Array` / `Set` / `Optional`（元素也得是
`_IntentValue`），以及 `AppValue` 分支（`AppEntity` / `AppEnum` 走这里）。

实测边界（[`param-limits-negative.swift`](../../spikes/app-intents-01/param-limits-negative.swift)）：

| 写法 | 结果 |
| --- | --- |
| 任意嵌套 struct | ❌ `generic class 'IntentParameter' requires that 'Address' conform to '_IntentValue'` |
| `[String: String]`（字典） | ❌ 同上形状。**字典无解**，`Dictionary` 没有一致性 |
| `[[String]]`（嵌套数组） | ✅ 编得过（`Array` 条件一致性递归成立）。运行时与 Shortcuts UI 表现 ⚠️ 未验证 |
| `AppEntity` 不给 `defaultQuery` | ❌ `type 'BareEntity' does not conform to protocol 'AppEntity'` |

结论：**要传结构化对象只有 `AppEntity` 一条路**，而它强制要求 `id: EntityIdentifierConvertible`
和一个 `EntityQuery` 实现 —— 对「只是想给模型传个参数对象」来说是很重的税。
对比之下 `@Generable` 支持任意嵌套的自定义类型，表达力明显更强。
**如果参数模型以 `@Parameter` 为准，模型侧的表达力会被拉低到 App Intents 的水平。**

### 5. 进程内调 `perform()` 会绕过系统的 intent 执行环境

手写适配器里 `try await intent.perform()` 能跑，但拿到的是一个**被剥光的** Intent：

- `supportedModes` 语义失效 —— 没有前台/后台判定，没有 `continueInForeground` 续跑
- `requestConfirmation` / `requestChoice` / `authenticationPolicy` 全部不生效，
  也就是说 WWDC26 session 347 里针对 prompt injection 讲的那套 App Intents 侧防护
  （风险分级确认、锁屏认证）**在这条路径上一个都不在**
- `@Dependency` 只有在 App 侧提前 `AppDependencyManager.shared.add(dependency:)` 过才可用；
  在包的单元测试里必须自己注入
- `IntentResult.value` 是 `Optional`（`var value: Self.Value? { get }`），取值必须兜底

以上都是从类型签名和框架职责推出来的，**运行时行为无真机未实测 ⚠️**。

### 6. 注册成 App Intent 是有副作用的，不是纯收益

一旦声明为 `AppIntent`，它就会**同时**出现在 Shortcuts、Siri、Spotlight 里，被用户直接调用。
这意味着：

- 只想给自家模型当工具的内部动作（例如「清空对话上下文」「切换 provider」）
  会莫名出现在用户的快捷指令库里。想藏起来要显式设 `isDiscoverable = false`
  （iOS 17+），或者用 `AssistantSchemaIntent.isAssistantOnly`
- 参数标题、`IntentDescription`、`ParameterSummary` 都变成**面向用户的 UI 文案**，
  要本地化、要审校；而模型侧的 `@Guide` 是面向模型的技术描述。两者受众不同，
  想合并成一份文案基本上两边都不讨好
- 用户可见 = 攻击面。Intent 能被 Shortcuts 任意编排、被自动化触发，
  权限模型和「只在自家 session 里被模型调用」完全不同

### 7. 端侧路径在本机整体不可验证

Apple Intelligence 在宿主 macOS 15.7.3 上不存在，模拟器复用宿主模型资源，
所以「模型真的会不会挑这个工具」「schema 描述写成什么样命中率高」这类问题
**在拿到真机或宿主升级 macOS 26 之前一个都答不了 ⚠️**。
本笔记所有结论止于**编译期与构建期**。

## 关键 API

`AppIntent` 协议在 26.2 的实际形状（`AppIntents.swiftinterface:708`）：

```swift
import AppIntents

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol AppIntent: PersistentlyIdentifiable, _SupportsAppDependencies, Sendable {
    associatedtype PerformResult: IntentResult
    static var title: LocalizedStringResource { get }
    @available(iOS, deprecated: 26.0, message: "Please provide 'supportedModes' instead")
    static var openAppWhenRun: Bool { get }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { get }        // iOS 26 起用这个
    static var authenticationPolicy: IntentAuthenticationPolicy { get }
    @available(iOS 17.0, *)
    static var isDiscoverable: Bool { get }               // 藏起来用它
    associatedtype SummaryContent: ParameterSummary
    static var parameterSummary: Self.SummaryContent { get }
    static var description: IntentDescription? { get }
    func perform() async throws -> Self.PerformResult
    init()
}

public protocol IntentResult: Sendable {                 // :5849
    associatedtype Value: _IntentValue = Never
    associatedtype Snippet = Never
    associatedtype Dialog = Never
    var value: Self.Value? { get }                       // ← Optional，适配层必须兜底
}
```

包内定义 Intent 的装配（这是让逻辑留在 `Packages/` 的关键）：

```swift
// 包里（Packages/AIFeatures 之类）
public struct IntentKitPackage: AppIntentsPackage {}

// App target
struct AppPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [IntentKitPackage.self] }
}
```

手写适配层的骨架（`AppIntent` → `Tool`，每个 Intent 一份）：

```swift
import AppIntents
import FoundationModels

struct SummarizeTool: Tool {
    let name = "summarizeText"
    let description = "Summarize text into at most N words."

    @Generable
    struct Arguments {                                   // ← 参数在这里重新声明一遍
        @Guide(description: "The text to summarize") var text: String
        @Guide(description: "Maximum number of words", .range(1...50)) var maxWords: Int
        @Guide(description: "terse for very short, verbose for normal") var style: ToolSummaryStyle
    }

    func call(arguments: Arguments) async throws -> String {
        let intent = SummarizeIntent()
        intent.text = arguments.text
        intent.maxWords = arguments.maxWords
        intent.style = arguments.style == .terse ? .terse : .verbose   // 枚举手工映射
        return try await intent.perform().value ?? ""    // value 是 Optional
    }
}
```

`Tool` 协议本身的细节见 [tool-calling.md](tool-calling.md)。

### 三条容易混淆的通路，分开说

| 通路 | 触发者 | 装配方式 | 与 FoundationModels 的关系 |
| --- | --- | --- | --- |
| **Shortcuts / 快捷指令** | 用户手工编排、自动化 | 声明 `AppIntent` 即出现 | 无 |
| **Siri / Apple Intelligence** | Siri 的模型 | `@AppIntent(schema:)` 采纳域 schema | Intent 成为 **Siri 模型**的工具，你的 `LanguageModelSession` 拿不到 |
| **自家 Agent** | 你自己的 `LanguageModelSession` | 手写 `Tool` 适配器 | 唯一入口是 `LanguageModelSession(tools:)` |

`AssistantIntent` 宏家族的现状（`AppIntents.swiftinterface:1127-1129` 与 `:9710-9711`）：

```swift
@available(*, deprecated, renamed: "AppIntent")
public macro AssistantIntent<T>(schema: T) where T: AssistantSchemas.Intent   // 已废弃

public macro AppIntent<T>(schema: T) where T: AssistantSchemas.Intent         // 用这个
```

**`@AssistantIntent` / `@AssistantEntity` 在 iOS 26 已废弃并改名为 `@AppIntent(schema:)` /
`@AppEntity(schema:)`。** 网上大量 iOS 18 时期的教程还在用旧名字，照抄会拿到 deprecation 警告。

域 schema（domain schema）指的是 Apple 预定义的一批 Intent 形状：你的 Intent 采纳
`AssistantSchemas` 里某个域的 schema（例如 `.system.search`、`.photos.deleteAsset`），
Apple Intelligence 就知道它的语义，不必靠自然语言猜。代价是**形状由 Apple 定**，
参数不能自己加减。

### 版本漂移

| 项 | iOS 26.2 SDK（本机实测） | developer.apple.com 当前文档（已切 iOS 27） |
| --- | --- | --- |
| 域 schema 数量 | **15** 个访问器：`assistant` / `books` / `browser` / `camera` / `files` / `journal` / `mail` / `photos` / `presentation` / `reader` / `spreadsheet` / `system` / `visualIntelligence` / `whiteboard` / `wordProcessor` | **23** 个，分三组（Primary 13 / Single-purpose 2 / Shortcuts-specific 8） |
| 26.2 没有的域 | — | Audio、Calendar、Clock、Maps、Messages、Notes、Phone、Reminders（8 个，iOS 27 新增） |
| Assistant 域 | `@available(iOS 26.2, *)`，仅 iOS，26.2 才有 | 文档描述为「让日本用户用侧键启动语音对话 App」 |
| 测试框架 | **`AppIntentsTesting` 不在 26.2 SDK 里**（`find` 全 SDK 无结果） | 文档已有 "Testing your App Intents code" 与 `AppIntentsTesting` 模块 |
| 宏名 | `@AppIntent(schema:)`；`@AssistantIntent` deprecated | 同 |

按 `CLAUDE.md` 的约定：**查 26.x API 要对着本机 `.swiftinterface`，不要照抄官网**。

## 实测数据

| 指标 | 环境 | 数值 | 备注 |
| --- | --- | --- | --- |
| 包内 Intent 宿主测试 | macOS 15.7.3 `swift test` | **4/4 通过** | 含 `await perform()` + 断言 `result.value` |
| 反馈延迟（改一个包内源文件） | 宿主 `swift test` vs `xcodebuild build` | **9.89s vs 28.29s** | 约 2.9× |
| 反馈延迟（空跑，无改动） | 同上 | **0.91s vs 3.35s** | 约 3.7× |
| 反馈延迟（冷启，清缓存） | 同上 | **30.73s vs 56.09s** | 约 1.8× |
| 正向 typecheck | iOS 26.2 SDK，`-swift-version 6` | EXIT=0 | 5 种 Intent 形状 + `AppEntity` + `AppShortcutsProvider` + `@AppIntent(schema: .system.search)` |
| 参数负向 case | 同上 | A/B/D EXIT=1，C EXIT=0 | 见上文表格 |
| 泛型适配器负向 case | 同上 | 3/3 EXIT=1 | |
| 包内 Intent 是否进元数据 | `xcodebuild` + iPhone 17 Pro 模拟器 | **是**，`IntentKit.SummarizeIntent` | 与 App target 对照组并列 |
| 去掉 `AppIntentsPackage` 声明的后果 | 同上 | 仍抽取，但少 `extract.packagedata` | 运行时后果**未实测**（无真机） |
| 模型是否会正确挑选适配后的工具 | — | **未实测** | 宿主无 Apple Intelligence，无真机 |
| Siri 端到端调用包内 Intent | — | **未实测** | 同上 |
| `[[String]]` 在 Shortcuts UI 里的表现 | — | **未实测** | 只验证了编译通过 |

## 踩坑记录

- **`IntentResult.value` 是 Optional** → 适配器里 `try await intent.perform()` 拿到的
  `result.value` 类型是 `String?` 而非 `String` → 必须 `?? ""` 或显式抛错，
  不要写成 `!`（模型工具里崩溃会直接干掉整个 session）。
- **官方文档页抓不到内容** → Apple 的文档页是 JS 渲染的，`WebFetch` 只能拿到标题 →
  改打 JSON API 端点 `https://developer.apple.com/tutorials/data/documentation/appintents/<page>.json`，
  再走 `topicSections` / `references`。
- **照抄 iOS 18 教程会用到废弃宏** → `@AssistantIntent` 已 deprecated renamed 为 `AppIntent` →
  统一用 `@AppIntent(schema:)`。
- **`extract.actionsdata` 里 `enums` 是 JSON 数组不是对象** → 用 `.keys()` 解析会
  `AttributeError: 'list' object has no attribute 'keys'` → 遍历列表读 `identifier`。
- **不要把「Intent 能被 Siri 当工具」理解成「Intent 能被我的模型当工具」**。
  这是本题最容易走错的一步：`@AppIntent(schema:)` 服务的是 Siri 的模型，
  跟 `LanguageModelSession(tools:)` 是两个世界。

## 结论与下一步

**选型倾向：部分复用 —— 业务逻辑复用，参数声明不复用；两侧都只做薄适配。**

具体到本项目：

1. **业务逻辑一律留在 `Packages/`**，写成不依赖 `AppIntents` 也不依赖 `FoundationModels`
   的纯函数/纯类型（如 spike 里的 `Summarizer`）。这一层是唯一真正被两边共享的东西，
   也符合架构不变量里「逻辑放 Packages」的约束。
2. **`AppIntent` 和 `Tool` 都当 adapter 写**，各自薄薄一层，各自声明自己的参数。
   不要试图让一个抽象同时喂两边 —— 已验证做不到（泛型适配器三个 case 全挂）。
3. **需要 `AppIntent` 时放包里，不放 App target。** 这条已实测可行且代价为零：
   宿主 `swift test` 能测（4/4），构建期元数据照样抽取。
   包侧 + App 侧各声明一个 `AppIntentsPackage` 即完成装配。
   —— 本题原本担心的「最重要的代价」不存在。
4. **不要为了「复用」而给内部动作套 `AppIntent`**。套上去就等于对用户公开，
   且参数表达力被 `_IntentValue` 封闭集合拉低。只有**确实希望用户在
   Shortcuts / Siri / Spotlight 里用到**的能力才值得做成 Intent。
5. 枚举可以省一份声明：`@Generable enum X: String, AppEnum`。这是唯一能省的一层。

待验证问题（登记到 `docs/backlog.md`）：

- 拿到真机或宿主升级 macOS 26 后：模型对手写适配工具的选择准确率；
  `@Guide` 描述怎么写命中率高。
- 去掉 App 侧 `AppIntentsPackage` 声明后，包内 Intent 在**运行时**能否被 Siri / Shortcuts 发现
  （构建期仍抽取，但 `extract.packagedata` 缺失，后果未知）。
- 进程内 `perform()` 绕过系统执行环境后，`@Dependency` 的注入方式在真机上的实际约束。
- `[[String]]` 这类嵌套数组参数在 Shortcuts UI 里是否可用。
- iOS 27 是否引入 App Intents → FoundationModels 桥接（目前 WWDC26 session 241
  的新内建工具只有 Barcode / OCR / Spotlight search，看不到迹象）。

## 参考来源

- `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/AppIntents.framework/Modules/AppIntents.swiftmodule/arm64e-apple-ios.swiftinterface`
  — 26.2 的唯一权威。`AppIntent:708`、`IntentResult:5849`、`_IntentValue:3075`、
  `IntentParameter:1811`、`AppEntity:4182`、`AppEnum:8918`、`AppIntentsPackage:6323`、
  `IntentModes:5749`、`AssistantIntent` 废弃标记 `:1127`、`AppIntent(schema:)` 宏 `:9711`。
- `.../iPhoneOS26.2.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface`
  — 证明 FoundationModels 侧零处提及 intent。
- `/Applications/Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation/AppIntents-Updates.md`
  — Xcode 26.2 随附的 Apple 官方文档（426 行）。"Swift Package Support" 一节给出了
  `AppIntentsPackage` 双向声明的官方写法，是「Intent 可以放包里」的直接依据；
  同时是 `IntentModes` / `continueInForeground` / `requestChoice` / `@ComputedProperty` 的来源。
- [Secure your app: mitigate risks to agentic features — WWDC26 session 347](https://developer.apple.com/videos/play/wwdc2026/347/)
  — Apple 明确把 agentic 能力分成 FoundationModels 与 App Intents 两条独立路线；
  并说明 "when an App Intent adopts an intent schema, it becomes available as a tool
  to the Siri model"。也是 App Intents 侧安全防护（确认、锁屏认证）的来源。
- [What's new in the Foundation Models framework — WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
  — 下一版新增的内建工具只有 `BarcodeReaderTool` / `OCRTool` / Spotlight 搜索，
  说明桥接缺口没有被补上。
- [App schema domains](https://developer.apple.com/documentation/AppIntents/app-schema-domains)
  — 域 schema 的分组与说明。⚠️ 该页已是 iOS 27 内容，列 23 个域，
  比 26.2 SDK 多 8 个，引用时须对照本机 `.swiftinterface`。
- [Apple Intelligence and Siri AI](https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai)
  — App Intents 官方文档中「接入 Apple Intelligence」的总入口。
  **全页 `FoundationModels` / `Generable` / `LanguageModelSession` 出现次数均为 0** ——
  官方文档层面也印证了没有桥接。下挂的子页只有 App Entity、Spotlight、域 schema、
  contextual cues、donation 和四个示例工程。
- 姊妹笔记 [tool-calling.md](tool-calling.md) — `FoundationModels.Tool` 协议本身的细节。
- spike 代码与完整命令：[`spikes/app-intents-01/`](../../spikes/app-intents-01/)
