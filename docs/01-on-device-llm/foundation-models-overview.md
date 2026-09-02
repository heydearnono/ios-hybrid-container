# Foundation Models 框架总览

- **更新时间**：2026-09-01
- **适用版本**：**iOS 26.2 SDK**（`FoundationModels` module version 1.1.7）/ Xcode 26.2 / Swift 6.2.3。
  框架自 iOS 26.0 起提供；tvOS / watchOS **unavailable**。
  ⚠️ 官网文档当前已切到 iOS 27（2026-06）SDK，若干类型被改名，见文末「版本漂移」。
- **验证方式**：官方文档 + **本机 SDK `.swiftinterface` 实证** + **iOS 26.2 模拟器实跑**（iPhone 17 Pro）
- **相关 spike**：[`spikes/foundation-models-01/`](../../spikes/foundation-models-01/)

## 一句话结论

**能用、免费、离线、数据不出端，但它是「端侧小模型」**：3B 参数 / 2-bit 量化 / **4096 token 上下文**，
Apple 自己说它「不适合世界知识和复杂推理」。正确定位是**文本处理管道里的一环**（摘要、抽取、分类、
改写、打标签），不是聊天机器人的大脑。

最大的两个坑：① **模型不可用时 `respond()` 会挂死而不抛错**，可用性判定不是可选项；
② 本机环境（macOS 15.7.3 宿主）**在模拟器上完全跑不起来**，端侧 LLM 主线目前只能读文档。

## 能做什么

| 能力 | 关键 API | 备注 |
| --- | --- | --- |
| 可用性判定 | `SystemLanguageModel.default.availability` → `.available` / `.unavailable(UnavailableReason)` | `UnavailableReason` 三个 case：`deviceNotEligible`、`appleIntelligenceNotEnabled`、`modelNotReady` |
| 语言支持查询 | `supportedLanguages: Set<Locale.Language>`、`supportsLocale(_:)` | 官方推荐用 `supportsLocale(_:)`，它会考虑语言回退（`en-AU` 匹配 `en`）([文档](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/supportslocale(_:))) |
| 单轮 / 多轮对话 | `LanguageModelSession.respond(to:options:)` | session 自动维护 `transcript`，多轮就是复用同一个 session |
| 系统提示 | `init(model:tools:instructions:)`，或 `@InstructionsBuilder` 闭包 | 模型被训练成「instructions 优先于 prompt」，是防注入的主要手段（但官方明说**不是万无一失**） |
| 流式输出 | `streamResponse(to:...)` → `ResponseStream<Content>` | **不是 async 函数**，同步返回一个 `AsyncSequence` |
| 结构化输出 | `@Generable` / `@Guide` 宏 + `respond(to:generating:)` | 约束解码，schema 会被塞进 prompt（`includeSchemaInPrompt: true`，占上下文） |
| 流式结构化输出 | `Snapshot.content: Content.PartiallyGenerated` | 每个属性变 optional，边生成边填 |
| 运行时动态 schema | `DynamicGenerationSchema` → `GenerationSchema(root:dependencies:)` | 不需要编译期已知类型，适合 schema 由服务端下发的场景 |
| 工具调用 | `Tool` 协议 + `LanguageModelSession(tools:)` | 框架自动多轮：模型生成参数 → 调你的 `call` → 结果进 transcript → 模型继续生成 |
| 采样控制 | `GenerationOptions(sampling:temperature:maximumResponseTokens:)` | `sampling`：`.greedy` / `.random(top:seed:)` / `.random(probabilityThreshold:seed:)` |
| 降低首 token 延迟 | `prewarm(promptPrefix:)` | 只在**至少提前 1 秒**时才有意义 |
| 会话状态 | `isResponding: Bool`、`transcript: Transcript` | `transcript` 在 26.x 是**只读**；可用 `init(model:tools:transcript:)` 重建会话 |
| 内置专用适配器 | `SystemLanguageModel(useCase: .contentTagging)` | 26.x 只有两个 `UseCase`：`.general`、`.contentTagging` |
| 护栏档位 | `SystemLanguageModel(guardrails: .permissiveContentTransformations)` | 只对 `String` 输出生效，结构化输出仍按 default 处理 |
| 自定义 LoRA 适配器 | `SystemLanguageModel(adapter:)` + `Adapter(name:)` / `Adapter(fileURL:)` | 见下文「适配器」，代价很高 |

以上全部在本机 `iPhoneOS26.2.sdk` 的 `.swiftinterface` 中逐条核对过，并用 `swiftc -typecheck` 编译通过。

## 不能做什么 / 边界

这一节比上一节重要。

### 上下文：4096 token，进出共用

- **每个 session 4096 token**，输入输出**共用**这一个池子：instructions + 所有 prompt +
  工具定义与工具输入输出 + `@Generable` schema + 模型的全部历史回复都算在内
  （[Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)）。
- 官方给的换算：拉丁字母约 **3–4 字符/token**，而**中文 / 日文 / 韩文 / 越南文约 1 字符/token**。
  也就是说**中文场景下 4096 token ≈ 4000 字左右**，包含系统提示和历史。这是做中文长文摘要的硬天花板。
- 超了抛 `GenerationError.exceededContextWindowSize`，且**该 session 之后无法再处理请求**。
  官方给的恢复路径只有两条：裁剪历史后用 `init(model:tools:transcript:)` 重建会话，或直接开新 session。
  WWDC25 301 的具体建议是「保留第一条 entry（instructions）+ 最近一次成功回复」，
  更长的历史考虑**用模型自己去摘要 transcript**。
- 长输入的官方套路：分块 → **每块开独立 session** 摘要 → 合并 → 再摘要。
- ⚠️ **未验证**：有开发者称实际不到 4096 就会抛错（要给回复留余量），Apple 文档没有确认这个余量行为。
- `contextSize` 属性和 `tokenCount(for:)` 方法是 **iOS 26.4 才引入**的，
  本机 26.2 SDK 里**没有**（已 grep 确认）。在 26.2 上算 token 只能靠字符数估。

### 模型能力：Apple 自己列了「别用它做什么」

WWDC25 286 原话：3B 参数、**每个权重量化到 2 bit**，是 device-scale model，
「**不是为世界知识和复杂推理设计的**」。文档里有一张明确的 "Capabilities to avoid" 表
（[Generating content and performing tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)）：

| 别用 | Apple 给的反例 |
| --- | --- |
| 基础数学 | 「bagel 里有几个 b」 |
| 生成代码 | 「写个 Swift 导航列表」 |
| 逻辑推理 | 「我在 Apple Park 面朝加拿大，德州在哪个方向」 |

适合的是：摘要、实体抽取、文本理解、润色改写、分类判定、创意写作、生成标签、游戏对话。
另外 prompt 本身也有限制：官方要求「**限制在 1–3 段之内**」，因为小模型撑不住长而绕的指令。

### 多模态：26.2 SDK **完全没有**图像输入

本机 `.swiftinterface` 全文只有 `public import CoreGraphics` 一行提到图形，
没有任何 `CGImage` / `Attachment` / 图像相关的公开 API；`Transcript.Segment` 只有
`.text` 和 `.structure` 两个 case。**iOS 26.x 的 Foundation Models 是纯文本框架。**
图像 prompt 属于 iOS 27 新增能力。

### 语言：官方 16 种，中文在内

Apple Intelligence 自 iOS 26.1 起支持 16 种语言：英语、丹麦语、荷兰语、法语、德语、意大利语、
挪威语、葡萄牙语、西班牙语、瑞典语、土耳其语、**简体中文**、繁体中文、日语、韩语、越南语
（[Apple Intelligence 可用性](https://support.apple.com/en-us/121115)）。
模型的语言范围就是 Apple Intelligence 的语言范围
（[Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)）。

两个必须知道的坑：

1. **「支持简体中文」≠「在中国大陆可用」**。同一页写明：在中国大陆购买的设备目前用不了
   Apple Intelligence；在中国大陆境内且 Apple 账户地区为中国大陆时，境外购买的设备也用不了。
   做面向国内用户的产品，这条基本判死了端侧 LLM 主线。
2. **护栏只覆盖受支持语言**。官方明说：不支持的语言里夹带的敏感短语，
   既可能不触发 `unsupportedLanguageOrLocale`，也可能**绕过护栏**。

输出语言不会自动跟随：默认「跟随输入语言」，要固定就在 instructions 里写死
（例如 `"You MUST respond in Simplified Chinese."`）。非 en_US 场景官方还建议在 instructions 里
原样写英文句子 `"The person's locale is \(locale.identifier)."` —— 这个短语来自训练数据，能降低多语言幻觉。

### 机型与系统：Apple Intelligence 那套门槛

- iPhone 15 Pro / 15 Pro Max，以及 iPhone 16 及更新机型
- iPad mini（A17 Pro）、M1 及更新的 iPad
- Apple 芯片的 Mac、Apple Vision Pro
- 需要 **7GB 可用存储**、设备语言与 Siri 语言一致且为受支持语言、用户**手动开启** Apple Intelligence
  （关闭时模型会被从设备上删除）
- 框架本身要求 iOS 26.0+

对应的降级判定就是 `UnavailableReason` 三个 case。注意 **`UnavailableReason` 不是 `@frozen`**
（`Availability` 是），`switch` 必须留 `@unknown default` 或 catch-all，
Apple 自己的示例也是这么写的。地区不支持、语言不支持都**没有**独立 case：
地区问题落到这三个之一，语言问题要到 `respond()` 时才以 `unsupportedLanguageOrLocale` 抛出。

### 限流与并发

- iOS 26.x 文档写得很具体：`rateLimited` **只在 App 处于后台且超过系统限额时**才会发生
  （[rateLimited](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:))）。
  前台按文档语义不限流。**具体数值 Apple 没有公开**，也没有 retry-after。
- 后台建议用**非流式** `respond(to:options:)`，降低触发限流的概率。
- **一个 session 同时只能有一个请求**，重入会抛 `concurrentRequests`；UI 上用
  `.disabled(session.isResponding)` 挡住。要并发就开多个 session。

### 护栏

输入和输出**双向**检查（instructions、prompt、工具调用都算输入），命中抛 `guardrailViolation`。
覆盖自残、暴力、成人内容。可调的只有一个维度：`Guardrails.permissiveContentTransformations`，
且**只对 `String` 输出生效**。官方给的误伤应对手段：改写触发词、在 instructions 开头给模型一个
明确的角色与领域许可、对用户输入给出可重试的提示文案、非用户触发的场景直接忽略错误不打扰 UI。

注意区分 `guardrailViolation`（护栏拦截，抛错）和 `refusal`（模型自己拒答）：
**`String` 输出的拒答是以正常文本返回的**，不抛错——官方说如果必须区分，只能再开一个 session 让模型去分类。

### 成本与合规

端侧模型**不需要任何 entitlement**，无调用成本，无网络。框架文档里唯一的 entitlement 是
iOS 27 的 Private Cloud Compute（`com.apple.developer.private-cloud-compute`，还要求
App Store 小型企业计划 + 首次下载量 < 200 万）。
App Store 审核 5.1.2(i) 的「第三方 AI 需披露」对 Apple 自家端侧模型**不适用**。
另外 Instruments 的 Foundation Models 模板会**以未加密形式**记录 prompt 和回复，trace 文件要当敏感文件处理。

## 关键 API

下面每段都在 iOS 26.2 SDK 上 `swiftc -typecheck` 通过，可直接照抄。
完整可编译文件见 [`spikes/foundation-models-01/api-typecheck.swift`](../../spikes/foundation-models-01/api-typecheck.swift)。

### 1. 可用性判定（必须做，否则会挂死）

```swift
import FoundationModels

let model = SystemLanguageModel.default   // @Observable，可直接绑到 SwiftUI

switch model.availability {
case .available:
    break                                   // 只有这里才能发请求
case .unavailable(.deviceNotEligible):
    break                                   // 机型不支持，永久降级
case .unavailable(.appleIntelligenceNotEnabled):
    break                                   // 引导用户去「设置 → Apple 智能」
case .unavailable(.modelNotReady):
    break                                   // 正在下载/尚未就绪，可稍后重试
@unknown default:
    break                                   // UnavailableReason 非 @frozen，必须留
}

// 语言判定：模型不可用时也能查
let zhOK = model.supportsLocale(Locale(identifier: "zh_CN"))
```

### 2. 会话与流式

```swift
let session = LanguageModelSession {          // @InstructionsBuilder
    "你是一个简洁的中文助手。"
    "回答不超过两句话。"
}
session.prewarm()                             // 至少提前 1s 才有意义

let reply = try await session.respond(
    to: "北京天气如何？",
    options: GenerationOptions(temperature: 0.3)   // temperature 取值 0...1
)
print(reply.content)                          // Response<String>.content
```

流式的关键认知：**吐的是累积快照，不是增量 delta**。WWDC25 286 原话是
「Instead of raw deltas, we stream snapshots」。所以 UI 上直接整体替换，不要做字符串拼接：

```swift
let stream = session.streamResponse(to: "写一首两行的诗")   // 同步返回，不是 async
for try await snapshot in stream {
    text = snapshot.content        // 每次都是到目前为止的完整内容
}
let final = try await stream.collect().content
```

### 3. 结构化输出

```swift
@Generable
struct Recipe {
    @Guide(description: "菜名")
    var title: String
    @Guide(description: "步骤", .count(3...8))
    var steps: [String]
    @Guide(description: "分钟", .range(5...240))
    var minutes: Int
}

let recipe = try await session.respond(to: "给我一个番茄炒蛋菜谱",
                                       generating: Recipe.self).content

// 流式：每个属性都变 optional，边生成边填
for try await snap in session.streamResponse(to: "再来一个", generating: Recipe.self) {
    let partial: Recipe.PartiallyGenerated = snap.content
}
```

`@Guide` 可用的约束（来自 SDK）：`String` → `.constant(_:)` / `.anyOf(_:)` / `.pattern(_ regex:)`；
`Int` / `Float` / `Double` / `Decimal` → `.minimum(_:)` / `.maximum(_:)` / `.range(_:)`；
数组 → `.minimumCount(_:)` / `.maximumCount(_:)` / `.count(_:)` / `.element(_:)`。

两个要点：**属性按声明顺序生成**，顺序会影响输出质量和流式填充次序；
schema 默认会被注入 prompt（`includeSchemaInPrompt: true`），**是要算进 4096 token 的**。

### 4. 工具调用

```swift
struct WeatherTool: Tool {
    let name = "getWeather"                  // 有默认实现，可不写
    let description = "查询指定城市的当前天气"  // 必须自己写，无默认实现

    @Generable
    struct Arguments {
        @Guide(description: "城市名，如 Beijing")
        var city: String
    }

    func call(arguments: Arguments) async throws -> String {
        "\(arguments.city): 26°C, sunny"
    }
}

let session = LanguageModelSession(tools: [WeatherTool()],
                                   instructions: "需要天气时调用工具。")
```

`Tool` 协议五个成员里，只有 `description` 和 `call(arguments:)` 必须自己实现：
`name`、`includesSchemaInInstructions` 有协议扩展默认实现，`Arguments: Generable` 时
`parameters` 自动合成。`Arguments` 用 `String` / `Int` / `Bool` 等标量会被
`@available(*, unavailable)` 直接拒绝，编译期报错让你换 `@Generable` struct。

行为要点：工具在 session 创建时传入，**对该 session 的所有后续请求都可见**；
一次请求里同一个工具**可能被并发调用多次**（所以 `Tool: Sendable`）；
工具输出会像模型输出一样进 transcript；工具抛错会被包成 `LanguageModelSession.ToolCallError`
（带 `tool` 和 `underlyingError`），框架会把 transcript **回滚到上一个有效状态**。
成本上，工具名 + 描述 + 参数 schema 是**原样进 prompt** 的，官方建议单次请求不超过 3–5 个工具、
描述控制在一句话。

### 5. 错误分类

`LanguageModelSession.GenerationError` 在 26.x 共 **9 个 case**（SDK 逐条核对）：

| case | 含义 | 处理 |
| --- | --- | --- |
| `exceededContextWindowSize` | 4096 token 用尽 | 裁剪 transcript 重建 session |
| `assetsUnavailable` | 模型资源不可用 | 降级到云端/关闭功能 |
| `guardrailViolation` | 护栏拦截（输入或输出） | 提示用户换个说法 |
| `unsupportedGuide` | `@Guide` 约束不被支持 | 改 schema |
| `unsupportedLanguageOrLocale` | 语言不支持 | 前置 `supportsLocale(_:)` 避免 |
| `decodingFailure` | 结构化输出解析失败 | 简化类型 / 重试 |
| `rateLimited` | 后台超限 | 退避重试，挪到前台 |
| `concurrentRequests` | 同一 session 并发请求 | 查 `isResponding` |
| `refusal` | 模型拒答（带 `Refusal`，可 `await explanation`） | 走拒答文案 |

## 适配器（LoRA）：结论是别碰

- 方法是 LoRA：冻结基座权重，训练小矩阵。官方提供 Python 训练工作流 + `.fmadapter` 导出 +
  Background Assets 分发（[Adapter 训练工具包](https://developer.apple.com/apple-intelligence/foundation-models-adapter)）。
- 训练门槛：≥32GB 内存的 Apple 芯片 Mac 或 Linux GPU、Python 3.11+；简单任务 100–1000 条样本，
  复杂任务 5000+。单个适配器约 **160MB**，官方要求走 Background Assets 远端下发而不是打进包。
- 部署要 **`com.apple.developer.foundation-model-adapter`** entitlement（需账户持有人申请）。
- **决定性代价**：一个适配器只兼容**一个特定的系统模型版本**，
  Apple 在同一页说了三遍「每换一个系统模型版本就要重训一个适配器」。
  而系统模型至今已有 3 个版本（26.0–26.3 / 26.4 / 27.0）。
- 更关键的是：**工具包 26.0.0 是最后一个版本，且不兼容 iOS/macOS 27 及以后**。
  同时 iOS 27 文档里 `SystemLanguageModel.Adapter` 相关页面已 **404**（26.2 SDK 里 API 还在）。

**结论：适配器对本项目是死路。** 面向 iOS 27+ 完全不可用，即便只做 26.x 也是「每次系统更新重训一遍」的跑步机。

## 实测数据

本机实测，环境：macOS 15.7.3 / Xcode 26.2 / iOS 26.2 模拟器（iPhone 17 Pro）。
spike：[`spikes/foundation-models-01/`](../../spikes/foundation-models-01/)

| 指标 | 环境 | 数值 | 备注 |
| --- | --- | --- | --- |
| API 类型检查 | iOS 26.2 SDK / Swift 6 | **全部通过**（exit 0） | 含流式、结构化、工具、动态 schema、适配器 |
| `availability` | iOS 26.2 模拟器 | **`.unavailable(.modelNotReady)`** | 宿主 macOS 15.7.3 无 Apple Intelligence |
| `isAvailable` | 同上 | `false` | |
| `supportedLanguages` | 同上 | **23 个标识**：`da de en en-AU en-GB es es-419 es-US fr fr-CA it ja ko nb nl pt pt-PT sv tr vi zh zh-HK zh-TW` | 模型不可用时**仍可查询** |
| `supportsLocale(zh_CN)` | 同上 | `true` | 简体中文在支持范围内 |
| 不可用时调 `respond()` | 同上 | **挂死 >300s，不抛错** | 两次复现（300s / 90s 超时） |
| 首 token 延迟 / 吞吐 | — | **未实测** | 需真机；模拟器数据无参考价值 |

关于官方性能数字：**Apple 从未公布 iOS 26 端侧模型的 tokens/sec 或 TTFT**。
唯一公开过的数字属于 2024 年（iOS 18 时代）那个**不同量化方案的旧模型**：iPhone 15 Pro 上
约 0.6ms/prompt token 的首 token 延迟、30 tokens/s
（[Apple ML Research 2024](https://machinelearning.apple.com/research/introducing-apple-foundation-models)）。
**不要拿这组数字当 iOS 26 的结论。** 官方给的办法是自己用 Instruments 的 Foundation Models 模板测。
⚠️ 未验证：论坛上 Apple DTS 工程师提到「持续低于 20~30 tokens/s 就该提 feedback」，
这是自查基线而非规格，且未指明机型和模型版本。

## 踩坑记录

- **不判可用性直接 `respond()` → 挂死**。现象：模拟器上 `.modelNotReady` 时调用
  `respond(to:)`，300s 和 90s 两次实测都不返回、不抛错。
  原因：模型资源没准备好，框架看起来在等资源而不是快速失败。
  解决：**任何调用前必须先看 `availability`**，并给所有请求加超时兜底（`Task` + `withTimeout` 之类）。
- **本机模拟器测不了 Foundation Models**。现象：`.modelNotReady`。
  原因：iOS 模拟器**复用宿主 Mac 的模型资源**，而本机是 macOS 15.7.3（Sequoia），
  没有 Apple Intelligence。⚠️ 这一点**只有 Apple DTS 工程师在开发者论坛的回复**为依据
  （要求：宿主 macOS Tahoe 26 + Mac 上开启 Apple Intelligence + 模拟器运行时 26+），
  **官方文档、Xcode 发行说明里都没有任何关于模拟器的说明**。
  解决：要么把宿主升到 macOS 26，要么上真机。**这是端侧 LLM 主线的真正阻塞项——
  卡的是宿主 macOS 版本，不只是缺真机。**
  另外论坛上也有人在完整升级到 Tahoe 后仍然在 iPhone 模拟器里拿到
  `GenerationError -1` / "Apple Intelligence is not enabled"，Apple 的回复是重启 + 提 feedback。
- **`stdout` 块缓冲吃掉日志**。用 `simctl spawn` 跑探针时日志走管道是块缓冲，
  进程被超时 kill 后什么都看不到。解决：日志写 `FileHandle.standardError`。
- **文档示例在 26.2 上编不过**。当前官网示例用 `GenerationOptions(samplingMode: .greedy)`，
  但 `samplingMode` 是 iOS 27 才有的改名（26.x 叫 `sampling`）。照抄官网会编译失败。

## ⚠️ 版本漂移（重要）

`developer.apple.com/documentation/foundationmodels` 现在展示的是 **iOS 27（2026-06）** 的 SDK。
本项目 target 是 iOS 26.2，**照抄官网会踩改名**。已确认的差异：

| 26.x（本项目用这个） | iOS 27 | 说明 |
| --- | --- | --- |
| `GenerationOptions.sampling` | `samplingMode` | 属性和 init 参数都改了名 |
| `LanguageModelSession.GenerationError`（9 case） | `LanguageModelError` / `SystemLanguageModel.Error` / `LanguageModelSession.Error` 三个类型 | 26.x 的类型在 27 标记 deprecated |
| `.exceededContextWindowSize` | `LanguageModelError.contextSizeExceeded` | |
| `transcript` 只读 | `transcript` 可写（`{ get set }`） | |
| 无 | `toolCallingMode`（`.allowed` / `.required` / `.disallowed`） | 27 新增 |
| 无 | 图像输入（`Attachment` / `ImageReference`）、`PrivateCloudComputeLanguageModel`、自定义 `LanguageModel`、`Usage` 统计、`DynamicInstructions` | 全是 27 新增 |
| 无 | `contextSize` / `tokenCount(for:)` | 26.4 引入，26.2 SDK 里没有 |
| `SystemLanguageModel.Adapter` 存在 | 文档页 404 | 适配器路线被弃 |

**结论：查 API 时不能只看官网当前页，必须对着本机
`$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/*.swiftinterface`
核对。** 这个文件是 26.2 的唯一权威。

## 结论与下一步

**选型倾向：作为「可选增强」用，不作为核心能力依赖。**

理由：
1. 能力天花板明确（4096 token、无世界知识、不擅长推理），只适合做管道里的文本变换环节。
2. 可用性不可控：机型 + 用户开关 + 地区三重门槛，**中国大陆基本不可用**。
   任何用它的功能都必须有完整降级路径，等于每个功能要做两套。
3. 但它免费、离线、隐私零成本，用在「有就更好、没有也能用」的地方（本地摘要、打标签、
   离线兜底）性价比极高。
4. 适配器定制不要考虑（见上）。

**架构含义**：应该先设计一个「文本生成能力」抽象层，端侧模型只是其中一个 provider，
云端是另一个，路由和降级在抽象层解决。这条直接对应 backlog 里
「端侧与云端 Tool Calling 能否统一抽象」（05 分组 P0）。

**待验证问题**（已同步到 [`../backlog.md`](../backlog.md)）：
- **P0 阻塞**：宿主 macOS 15.7.3 无法在模拟器上跑通端侧模型。要么升 macOS 26，要么找真机。
  在此之前中文实测、性能实测、结构化输出可靠性、护栏误伤率**全部无法推进**。
- 中文实际表现（4096 token ≈ 4000 汉字的天花板下，摘要质量如何）
- 复杂嵌套 `@Generable` 类型的稳定性与 `decodingFailure` 触发率
- 后台限流的实际数值
- 上下文溢出的实际余量（是否不到 4096 就抛错）

## 参考来源

- [Foundation Models 框架文档](https://developer.apple.com/documentation/foundationmodels) — API 索引（注意已是 iOS 27 版本）
- [Foundation Models 更新记录](https://developer.apple.com/documentation/updates/foundationmodels) — 判断哪个 API 是哪个版本引入的唯一可靠来源
- [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window) — 4096 token、中文 1 字符/token、溢出恢复策略
- [Generating content and performing tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models) — 适合/不适合的任务表、并发规则
- [Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation) — `@Generable` / `@Guide` 语义与属性顺序
- [Expanding generation with tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling) — 工具生命周期与错误回滚
- [Improving the safety of generative model output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output) — 护栏双向检查、误伤应对
- [Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models) — 语言判定 API、locale 提示词技巧、护栏语言盲区
- [Apple Intelligence 可用性与语言列表](https://support.apple.com/en-us/121115) — 16 种语言、机型、7GB 存储、中国大陆限制
- [Prompting an on-device foundation model](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model) — prompt 限 1–3 段
- [Analyzing runtime performance](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app) — Instruments 模板、trace 未加密
- [WWDC25 286 Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/) — 3B/2-bit、snapshot 而非 delta、device-scale 定位
- [WWDC25 301 Deep dive into the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/301/) — 工具多轮机制、transcript 裁剪策略
- [Apple ML Research 2025 更新](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates) — 2-bit QAT、KV cache 8-bit
- [Adapter 训练工具包](https://developer.apple.com/apple-intelligence/foundation-models-adapter) — LoRA 门槛、160MB、每版本重训、26.0.0 为末版
- 本机 SDK 接口文件 `iPhoneOS26.2.sdk/.../FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface`（module version 1.1.7）— **26.2 API 的权威来源**
