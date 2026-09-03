# Tool Calling：端侧 vs 云端

- **更新时间**：2026-09-03
- **适用版本**：iOS 26.2 SDK / Xcode 26.2 (17C52) / Swift 6.2.3；FoundationModels module version 1.1.7
- **验证方式**：对着本机 `iPhoneOS26.2.sdk` 的 `.swiftinterface` 逐条核对，并在
  **iOS 26.2 模拟器（iPhone 17 Pro）实跑 4 组探针**验证运行期行为（探针代码写在 `/tmp`，未落库）。
  ⚠️ **端侧「模型何时决定调工具」这类行为完全无法验证** —— 本机没有 Apple Intelligence，
  `availability == .unavailable(.modelNotReady)`。下文凡涉及模型决策的都标了 ⚠️
  云端侧的结论已经由 `Packages/AICore` 的实现加 31 个测试兑现，见
  [已落地的实现](#已落地的实现2026-09-03)。
- **相关 backlog**：05 P0

## 一句话结论

**可以抽象成统一接口，但必须切在「工具定义 + 单次执行」这一层，不要试图统一「工具调用循环」。**

最本质的差异只有一句：**端侧的工具循环在框架里，云端的工具循环在你手里。**
端侧 `respond()` 一次调用内部就把「模型出参数 → 调你的 `call` → 结果进 transcript → 模型接着说」
跑完了；云端要你自己 while 循环、自己配对 `tool_call_id`。这个形状冲突无法消除，只能双实现。

能统一的部分比预期多，因为三件事恰好对齐：

| 维度 | 为什么能对齐 |
| --- | --- |
| 参数 schema | 两边**都能在运行期构造**。端侧走 `DynamicGenerationSchema`，云端本来就是 JSON |
| 工具结果类型 | `Tool.Output` 的约束是 `PromptRepresentable` 而**不是** `Generable`，`String` 直接满足；云端的 tool message `content` 也是字符串 |
| schema 方言 | 端侧 `GenerationSchema` 编码出来就是 JSON Schema 方言，剥掉 `x-order` / `title` 即可发给云端，且天然带 `additionalProperties: false` + 全字段 `required`，**接近 OpenAI strict 模式的要求** |

不能统一、必须双实现的是四件事：循环归属、错误语义、工具选择控制、流式期间的工具可见性。
详见[统一抽象的设计结论](#统一抽象的设计结论)。

## 端侧：`Tool` 协议

签名照抄自 `.swiftinterface`（第 1196–1204 行）：

```swift
public protocol Tool<Arguments, Output> : Swift.Sendable {
  associatedtype Output : FoundationModels.PromptRepresentable
  associatedtype Arguments : FoundationModels.ConvertibleFromGeneratedContent
  var name: Swift.String { get }
  var description: Swift.String { get }
  var parameters: FoundationModels.GenerationSchema { get }
  var includesSchemaInInstructions: Swift.Bool { get }
  func call(arguments: Self.Arguments) async throws -> Self.Output
}
```

默认实现分三处，决定了**你实际只需要写 `description` 和 `call`**（当 `Arguments: Generable` 时）：

| 成员 | 默认实现 | 实测行为 |
| --- | --- | --- |
| `name` | 有（`.swiftinterface` 里看不到实现体） | 返回 **Swift 类型名**。`struct StaticTool: Tool` 不写 `name` → `"StaticTool"` |
| `includesSchemaInInstructions` | 有 | `true`。只有模型被训练过、天然知道这个工具时才该设 `false` |
| `parameters` | **仅当 `Arguments: Generable`** 时有 | 由 `@Generable` 宏生成 |

标量 `Arguments` 被**显式毒化**：`String` / `Int` / `Double` / `Float` / `Decimal` / `Bool`
各有一份 `@available(*, unavailable)` 的 `parameters`，提示语是
「Use '@Generable' struct instead」。也就是说参数必须是结构体，不能是裸标量。

两条来自 doc comment 的关键约束：

- **`call` 抛的错不会喂回模型**，而是被包成 `LanguageModelSession.ToolCallError`
  从 `respond()` 抛到调用点。官方文档给的替代做法是自己咽掉错误、
  把说明**当成正常 output 字符串返回**（"Cannot access the database."）。
- **`call` 可能被并发调用**：doc 原文 "This method may be invoked concurrently with itself
  or with other tools."，这也是 `Tool: Sendable` 是协议级强制要求的原因。

`name` 的 doc 举的三个例子是 `get_weather` / `toggleDarkMode` / `search contacts` ——
注意第三个**带空格**，说明端侧对工具名的字符集没有约束。云端有（见下），
所以统一抽象要按云端的严格集合来。

## 端侧最有价值的发现：`GenerationSchema` 是 `Codable`

`GenerationSchema` 声明了 `init(from:)` / `encode(to:)`（`.swiftinterface` 1403–1404），
[官方文档](https://developer.apple.com/documentation/foundationmodels/generationschema)
也列出了 `Decodable` / `Encodable` conformance。**实测**它的编解码形态就是
JSON Schema（2020-12 风格，带 `$defs` / `$ref`）**加一个非标准的 `x-order` 键**：

```json
{
  "type": "object", "title": "WeatherArgs", "additionalProperties": false,
  "properties": {
    "city": { "type": "string", "description": "City name, e.g. Beijing" },
    "days": { "type": "integer", "description": "Days ahead", "minimum": 0, "maximum": 7 }
  },
  "required": ["city", "days"],
  "x-order": ["city", "days"]
}
```

嵌套 `@Generable` 类型会被提到 `$defs` 里用 `$ref` 引用；`@Generable enum` 编码成
`{"type":"string","enum":[...]}`；`String?` 属性出现在 `properties` 但不进 `required`。
`debugDescription` 输出的就是同一份 JSON。

⚠️ **这个编码格式没有任何官方文档。** 下面这张表是我逐条试出来的解码要求：

| 情况 | 结果 |
| --- | --- |
| 根节点缺 `title` | FAIL：`Missing top level 'title' key containing the type's name` |
| 缺 `x-order` | FAIL：`keyNotFound("x-order")` |
| 缺 `properties` / `required` | FAIL |
| 节点缺 `type` | FAIL：`None of these keys were present: 'type', 'const', '$ref', 'anyOf'` |
| 嵌套 object 缺 `title` / `x-order` | FAIL（必须逐层补） |
| `x-order` 漏写某个属性 | **OK，但该属性被静默丢弃** —— 连 `required` 里也消失 |
| `x-order` 写了不存在的属性 | FAIL：`Missing property: 'zzz'` |
| `required` 写了不存在的属性 | OK，静默忽略 |
| `$schema` / `format` 等未知关键字 | OK，静默丢弃（`pattern` / `minimum` / `maximum` / `minItems` / `maxItems` / `enum` 会保留） |
| 外部 `$ref` + `definitions` | 「成功」但被改写成 `#/$defs/#/definitions/X` —— **实质不支持** |

结论：**外部标准 JSON Schema 不能直接 decode**，但补上 `title` + `x-order`（逐层）就能。
`x-order` 同时充当属性白名单，漏写就静默丢字段 —— 这是个会咬人的坑。

**所以不要走 `Codable` 这条路。** 依赖 `x-order` 这种连官网都没提的私有键，
Apple 换一版就可能崩；而外部 schema 本来就得写转换器，那就该转成公开 API
`DynamicGenerationSchema`（`.swiftinterface` 1281–1304），它支持嵌套 / 数组 / `anyOf` / 引用：

```swift
public struct DynamicGenerationSchema : Swift.Sendable {
  public init(name: String, description: String? = nil, properties: [Property])
  public init(name: String, description: String? = nil, anyOf choices: [DynamicGenerationSchema])
  public init(name: String, description: String? = nil, anyOf choices: [String])
  public init(arrayOf itemSchema: DynamicGenerationSchema,
              minimumElements: Int? = nil, maximumElements: Int? = nil)
  public init<Value>(type: Value.Type, guides: [GenerationGuide<Value>] = []) where Value : Generable
  public init(referenceTo name: String)
}
// 最后一步：GenerationSchema(root:dependencies:) throws
```

`Codable` 那条路留作快速原型和 debug 手段就好。

## 端侧可以完全在运行期注册工具

这是统一抽象能成立的前提，**已编译并实跑验证**。关键在于 `Tool.Arguments` 的约束只是
`ConvertibleFromGeneratedContent`，**不是 `Generable`** —— 只有 `parameters` 的*默认实现*
才要求 `Generable`。所以把 `Arguments` 定成 `GeneratedContent` 本身、
把 `parameters` 做成**存储属性**去覆盖那个默认实现，就得到一个纯运行期构造的工具：

```swift
struct DynamicTool: Tool {
    typealias Arguments = GeneratedContent   // 只需 ConvertibleFromGeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema         // 存储属性覆盖协议扩展的默认实现
    let handler: @Sendable (GeneratedContent) async throws -> String
    func call(arguments: GeneratedContent) async throws -> String { try await handler(arguments) }
}
```

实测：`LanguageModelSession(tools: [dynamicTool], instructions: …)` 接受它，
`transcript` 里的 `toolDefinitions` 正确显示 `[name: description]`，
参数侧 `args.value(String.self, forProperty: "city")` 能取到值。

`GeneratedContent`（`.swiftinterface` 199–255）是另一半拼图：`init(json:) throws`、
`jsonString`、`value(_:forProperty:)`、`kind`（`.null` / `.bool` / `.number` / `.string` /
`.array` / `.structure(properties:orderedKeys:)`）、`isComplete`。

## 端侧的可观测性：`Transcript`

「调了哪个工具、参数是什么、返回了什么」三样**都能拿到**：

```swift
public enum Entry {                       // .swiftinterface 708-939
  case instructions(Transcript.Instructions)   // 含 toolDefinitions
  case prompt(Transcript.Prompt)
  case toolCalls(Transcript.ToolCalls)         // RandomAccessCollection
  case toolOutput(Transcript.ToolOutput)       // toolName + segments
  case response(Transcript.Response)
}
public struct ToolCall { var id: String; var toolName: String; var arguments: GeneratedContent }
```

`ToolCalls` 是 `RandomAccessCollection` —— **一个 entry 装多个 call，这本身就是并行工具调用的
结构性证据**。单次请求的入口是 `Response<Content>.transcriptEntries: ArraySlice<Entry>`。

三个坑：

- **`Transcript.ToolDefinition` 在 26.2 上只有 `name` / `description` 两个 getter**，
  `parameters` 只出现在 init 里（实测 `d.parameters` 报 `has no member 'parameters'`）。
  schema 写得进去、读不出来 —— 所以**抽象层必须自己留一份 schema 的权威副本**，
  别指望从 transcript 反查。iOS 27 才补上这个 getter。
- **`ToolCall == ToolCall` 在序列化往返后为 `false`**（实测 id / toolName /
  `arguments.jsonString` / `kind` 全都相同）。做去重或 diff 要用 `id` + `arguments.jsonString`。
- **中途更换工具集只能重建 session**（`init(tools:transcript:)`）。实测框架会**按新的 `tools:`
  参数重写 instructions 条目里的工具声明**，不沿用旧 transcript 里的 —— 这条官方文档没写。
  代价是丢掉 session 内部状态（KV cache、prewarm 效果）。

顺带一个可能有用的观察：`Transcript` 本身 `Codable`，**实测**它序列化出来的形状惊人地接近
OpenAI —— `toolCalls[].arguments` 也是 JSON 编码的字符串，工具结果条目也是
`role: "tool"` + `toolCallID`。⚠️ 但这是无文档的私有格式（带 `"version":1`），**不要拿它当协议用**。

## 云端：OpenAI 兼容的 `tool_calls`

依据是官方 OpenAPI spec [`openai/openai-openapi`](https://github.com/openai/openai-openapi/blob/master/openapi.yaml)
（`info.version: 2.3.0`）加
[Function calling 指南](https://developers.openai.com/api/docs/guides/function-calling?api-mode=chat)。
注意 `platform.openai.com/docs/...` 现在 301 跳到 `developers.openai.com`。

**Chat Completions 把函数嵌一层 `function`**（Responses API 是扁平的，别抄错）：

```json
{ "type": "function",
  "function": {
    "name": "get_weather", "description": "Retrieves current weather.", "strict": true,
    "parameters": { "type": "object", "additionalProperties": false,
      "properties": { "location": { "type": "string" } }, "required": ["location"] } } }
```

- `name` 约束：`a-z A-Z 0-9` + 下划线 + 短横线，**最长 64 字符**。
- `parameters` 可省略（= 空参数表）。
- `strict` **默认 `false`**。开了要求：每层 object 必须 `additionalProperties: false`，
  `properties` 里**所有**字段都要进 `required`，可选字段用 `"type": ["string","null"]` 表达。
- ⚠️ **工具数量硬上限查不到**：spec v2.3.0 的 `tools` 没有 `maxItems`（`maxItems: 128`
  只挂在**已废弃**的 `functions` 上）。文档只给软建议「fewer than 20 functions」。

控制参数：

| 参数 | 取值 | 默认 |
| --- | --- | --- |
| `tool_choice` | `"none"` / `"auto"` / `"required"` / `{"type":"function","function":{"name":…}}` | 无 tools 时 `none`，有 tools 时 `auto` |
| `parallel_tool_calls` | `boolean` | **`true`**；设 `false` 则「exactly zero or one tool is called」 |

响应侧（非流式）：`choices[].message.tool_calls[]`，每个含 `id` / `type` /
`function.name` / `function.arguments`，`finish_reason: "tool_calls"`。
**`arguments` 是字符串**，spec 明确警告模型「does not always generate valid JSON, and may
hallucinate parameters not defined by your function schema」—— 必须自己校验。
只调工具时 `content` 为 `null`，但 spec 不禁止两者同时非空，**两种都要能处理**。

### 流式拼接：全部契约就是 `required: [index]`

`ChatCompletionMessageToolCallChunk` 里**除 `index` 外每个字段都可缺席**。规则：

- 按 `index` 建表（这个 `index` 是该 call 在 `message.tool_calls` 里的下标，
  **与 `choices[].index` 无关**）；
- `id` / `type` / `function.name` **只在该 index 的首帧出现**
  （SDK 把缺席物化成 `null`，裸 SSE 里是整个键不存在）；
- `function.arguments` **逐帧追加**。

官方拼接代码就是 `accumulated.id ??= chunk.id; accumulated.function.arguments += chunk.function?.arguments ?? ""`。
并行调用就是 `index: 0` / `index: 1` 的帧**交错到达** —— 只认「当前工具调用」的客户端
会把并行输出串味。
⚠️ 官方文档没有发布工具调用的**裸 SSE 帧**样本，只有 `delta.tool_calls` 数组形态。

### 回传结果

```json
{ "role": "tool", "tool_call_id": "call_12345xyz", "content": "{\"temperature\": 18}" }
```

- 必须**先把带 `tool_calls` 的 assistant 消息原样回填**，再为**每个 `tool_call_id`
  各发一条** tool 消息。⚠️ 这个顺序与一对一规则**官方文档没有明文**，是 API 运行期强制的。
- **`name` 在 spec v2.3.0 的 tool message 里根本不存在**（带 `name` 的是废弃的
  `role: "function"`）。建议不发，但服务端要容忍。
- **错误没有官方结构化约定**：指南只说结果「typically be a string, where the format is up to
  you (JSON, error codes, plain text, etc.)」。把错误文本放进 `content` 即可，
  **不要自造 `is_error` 字段，更不能省掉这条消息** —— 省掉会让请求变成非法。

## 差异清单

| 维度 | 端侧 FoundationModels 26.2 | OpenAI 兼容 Chat Completions |
| --- | --- | --- |
| 工具定义载体 | Swift 类型（`Tool` 实例），schema 编译期由宏生成 | 纯 JSON，每次请求下发 |
| schema 格式 | JSON Schema + **必需的 `x-order`**，要 `title` | 标准 JSON Schema；strict 模式要 `additionalProperties: false` |
| 工具名约束 | 无（官方示例含空格） | `[a-zA-Z0-9_-]`，≤ 64 字符 |
| 参数形态 | 强类型 `Arguments`（已解析） | JSON **字符串**，可能非法，必须自行校验 |
| **谁跑循环** | **框架内部自动循环**，`respond()` 一次返回终态 | **你自己循环** |
| 结果回传 | `call` 的返回值（`Output: PromptRepresentable`） | 手写 tool 消息，与 `tool_call_id` 一一对应 |
| 调用 ID | 框架生成，只能读 | 服务端生成，必须原样回传 |
| 强制/禁止调工具 | **不支持**（iOS 27 才有 `toolCallingMode`） | `tool_choice` |
| 并行调用 | 支持；`call` 可能被并发调用 | 支持，默认开，靠 `index` 区分 |
| 工具抛错 | 包成 `ToolCallError` **抛给调用方**，transcript 回滚，错误**不进模型** | 无专门机制；错误文本当普通 `content`，**模型能看到并继续** |
| 流式时工具可见性 | 26.2 只能轮询 `session.transcript` | `delta.tool_calls` 分片 |
| 工具数量的成本 | 名称+描述+schema **原样进 4096 token 上下文** | 计入输入 token，按量计费 |

### 官网（iOS 27）与本机 26.2 的漂移

这一节很重要：**照着官网写的工具代码在 26.2 上编不过。**

| 项 | 26.2 本机 | 官网（iOS 27） |
| --- | --- | --- |
| `Tool` 协议本体 | 6 个成员 | **完全相同**，可放心照抄 |
| `ToolDefinition.parameters` | 只有 init 参数，**无 getter** | 有 getter（BETA） |
| `ResponseStream.Snapshot` | `content` / `rawContent` | 另加 `transcriptEntries` / `usage`（BETA） |
| 工具调用模式 | **不存在** | `GenerationOptions.toolCallingMode`（`.allowed` / `.required` / `.disallowed`） |
| 错误处理策略 | **不存在** | `transcriptErrorHandlingPolicy(_:)` / `.preserveTranscript` |
| `Transcript.Entry` | 恰好 5 个 case | 加 `case reasoning(...)`，官方示例已写 `@unknown default` |
| `DynamicProfile` / `@SessionProperty` / `.onToolCall {}` | **不存在** | 存在。官网「Configure the tool calling mode」整节在 26.2 上不可用 |

实测：[官方 tool calling 文档](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)
里的 `WeatherTool` 返回 `struct Forecast: Encodable`，在 26.2 上报
`type 'WeatherTool' does not conform to protocol 'Tool'` —— `Encodable` 不满足
`Output: PromptRepresentable`。同页正文自己写的是「Tool output can be a string, a
`GeneratedContent` object, or any `@Generable` type」，**示例和正文互相矛盾**。
iOS 27 的 `Tool.Output` 约束仍是 `PromptRepresentable`，所以这大概是文档 bug 而非新能力。

另外 [FoundationModels 更新记录](https://developer.apple.com/documentation/updates/foundationmodels)
确认 **iOS 26.4 换了模型并明确提到改进了 tool-calling 能力** ——
26.2 和 26.4 的工具调用可靠性不是同一回事，做实测必须标清模型版本。

## 统一抽象的设计结论

### 能统一：工具定义 + 单次执行

一份中立的工具描述 —— `name` / `description` / 参数 schema /
`(输入) async throws -> String` —— 可以同时驱动两侧。三条设计取舍：

- **schema 用一个内部 DSL 作单一事实源，向两侧各出一个 adapter**，
  并且**以端侧的表达力为最小公倍数**来设计（`type` / `const` / `$ref` / `anyOf` +
  `minimum` / `maximum` / `minItems` / `maxItems` / `enum` / `pattern`）。
  这样就不会出现「云端能表达、端侧表达不了」的漏。
- **工具名按云端的严格集合约束**（`[a-zA-Z0-9_-]`，≤ 64）。端侧无约束所以一定兼容。
  别用端侧 `name` 的默认值（Swift 类型名），那不受控。
- **结果类型取 `String`**，两边的公共分母。工具实现不必为端侧额外做 `@Generable` 建模。
- ⚠️ 未验证：往云端发的 schema 必须**先剥掉 `x-order` / `title`** 这些非标准键 ——
  OpenAI strict 模式对未知关键字的容忍度我没有测。

### 不能统一：四件事必须双实现

1. **循环归属。** 抽象层只能暴露「一次 `generate` 可能触发若干工具执行」这个语义，
   云端实现里自己补 while 循环、补 `tool_call_id` 配对。**不要**试图让端侧暴露单步 ——
   它做不到。
2. **错误语义。** 端侧默认抛出并回滚 transcript，云端默认把错误文本喂回模型让它自愈。
   要行为一致只能**统一收敛到云端语义**：在端侧工具的 `call` 里 catch 掉所有业务错误、
   返回描述字符串，只让真正致命的错误抛出。否则同一个工具在两侧会产生完全不同的
   用户可见行为。
3. **工具选择控制。** 26.2 端侧没有 `tool_choice` 等价物。如果抽象层暴露 `toolChoice`：
   `.auto` 原生支持；`.none` 可以用「不传 tools 的新 session」模拟；
   **`.required` 和「指定某个工具」无法实现**，只能如实失败。
   这条要写进抽象层的能力声明，**别静默降级** —— 同架构不变量 2 的道理。
4. **流式期间的工具可见性。** 云端能逐帧看到工具调用在成形；26.2 端侧的 `Snapshot` 里
   什么都没有，只能靠 `@Observable` 的 `session.transcript` 轮询/订阅。
   两侧事件时序无法对齐，UI 上的「正在调用 XX 工具」要按 provider 分别实现。

另外**上下文预算不对等**：端侧工具定义原样进 4096 token 池子，云端只是计费。
同一套工具集在端侧可能直接把上下文挤爆 —— 抽象层应允许**按 provider 声明不同的工具子集**。

### 落地顺序

1. ✅ `AICore` 里定义中立的 `AgentTool`（名称 / 描述 / schema DSL / `call`）与
   `ToolCallRequest` / `ToolCallResult`；
2. ✅ 云端侧实现 `tools` 下发 + `tool_calls` 解析（含流式按 `index` 拼接）+ tool 消息回传，
   用 stub 服务器测；这一步**现在就能完整验证**；
3. ⬜ 端侧适配器用上面那个 `DynamicTool` 形状，**只做编译期验证**，运行期行为等硬件；
4. ⬜ 把「模型何时决定调工具、并行时序、错误回滚边界、流式与工具的交错」做成
   **可替换的策略点**，先对着 mock 写。

## 已落地的实现（2026-09-03）

第 1、2 步已经写完并通过测试。**这一节记录代码里实际的形状，与上面的设计结论对照着看。**

中立层（`Packages/AICore/Sources/AICore/`）：

| 文件 | 内容 |
| --- | --- |
| `ToolSchema.swift` | schema DSL 单一事实源，`jsonSchema(strict:)` 出 JSON Schema。表达力**按端侧的能力封顶**：不提供 `$ref` / `anyOf` / `const` |
| `AgentTool.swift` | `ToolName`（按云端严格集合校验）/ `ToolArguments`（容忍非法 JSON）/ `AgentTool` / `ToolChoice` / `ToolRegistry` |
| `CloudToolCalling.swift` | 中立类型 ↔ 线上格式的转换，以及流式 `ToolCallAccumulator` |

几条实现取舍，都是上面结论的直接兑现：

- **工具集挂在 provider 上，不在 `ModelRequest` 里。** 端侧 `LanguageModelSession(tools:)` 只在
  初始化时收工具，请求级传工具两侧形状对不上；另外 `AgentTool` 带闭包，放进 `ModelRequest`
  会让它失去 `Equatable`。每次请求可变的只有 `ModelRequest.toolChoice`。
- **`ToolArguments` 不保证持有合法 JSON。** spec 明确警告模型会吐非法 JSON，所以取值时才报错，
  且 `null` 与「压根没给」同义 —— strict 模式下可选字段就是用 `null` 表达的。
- **未知工具、工具抛错都产出 `isError` 的文本结果，不抛。** 少一条 tool 消息整个云端请求就非法。
- **`maximumToolIterations`（默认 5）给客户端侧的循环封顶**，超限抛
  `ModelError.toolLoopLimitExceeded` 而不是把最后一轮的空回答当答案。云端每一轮都是真实计费请求。
- **强制类 `tool_choice` 只在第一轮下发。** `.required` 每轮都发等于要求模型永远调工具，
  永远轮不到它给答案，循环只会撞上迭代上限。
- **`ModelError.unsupportedCapability`** 已就位，供端侧适配器在 `.required` / `.specific`
  上如实失败 —— 不静默降级。
- **`ModelResponse.toolInvocations`** 暴露「模型替我做了什么」。工具调用是副作用，
  调用方不能只拿到最后那段文字。

已验证 / 未验证的边界，说清楚：

- ✅ **打本地 stub 服务器（真 `URLSession` + 真 socket + 真 SSE 字节流）跑通全闭环**：
  `Tests/AICoreTests/CloudToolCallingTests.swift`（12 个用例）覆盖非流式闭环、回传消息的精确形状、
  并行调用、未知工具、循环上限、`tool_choice` 只发第一轮、无工具时省字段、strict 开关；
  流式侧覆盖工具轮不吐终片、交错分片按 `index` 归位、边说边调工具时快照前缀不变量、流式循环上限。
  纯逻辑部分在 `ToolAbstractionTests.swift`（19 个用例）。
- ⚠️ **没对任何真实厂商端点发过请求。** 断言的是「我们发出的字节符合 spec」，
  不是「某个真实服务端接受它」。`usesStrictToolSchema` 留了开关就是为这个 ——
  自建网关不认 `strict` 时遇 400 先关掉。
- ⬜ **流式还没有把工具事件暴露给下游。** `ModelResponseChunk` 只有累积文本，
  UI 现在做不出「正在调用 XX 工具」。这是设计结论第 4 条（两侧事件时序无法对齐）的未完成部分，
  要等端侧适配器一起定形状，否则会做出一个只适配云端的事件模型。
- ⬜ 端侧适配器整个还没写。


## 未验证清单

端侧结论分两类。**已在 iOS 26.2 模拟器实跑验证**：签名、`GenerationSchema` 编解码、
`DynamicTool` 能被 session 接受、transcript 结构、换工具集会重写 `toolDefinitions`。
**完全未验证**（需要 Apple Intelligence，本机没有）：

- 模型何时决定调工具、调得准不准
- 并行工具调用的实际时序
- 错误回滚的确切边界（26.2 上没有 `transcriptErrorHandlingPolicy`，回滚**应该**是唯一行为）
- 工具执行期间流是否停顿、工具调用是否会在流里产生可见事件

## 参考来源

- 本机 `.swiftinterface`：
  `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface`
  （1536 行，module version 1.1.7）。同目录 `.swiftdoc` 里有 doc comment，可用 `strings` 提取
- [Expanding generation with tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling) —
  ⚠️ 已切到 iOS 27 文档，且示例代码与正文矛盾（见上）
- [`Tool` 协议](https://developer.apple.com/documentation/foundationmodels/tool)、
  [`GenerationSchema`](https://developer.apple.com/documentation/foundationmodels/generationschema)、
  [`Transcript`](https://developer.apple.com/documentation/foundationmodels/transcript)
- [FoundationModels 更新记录](https://developer.apple.com/documentation/updates/foundationmodels) —
  26.4 换模型 + 改进 tool calling
- [`openai/openai-openapi` openapi.yaml](https://github.com/openai/openai-openapi/blob/master/openapi.yaml) —
  权威字段定义（`info.version: 2.3.0`）
- [Function calling 指南（Chat Completions 模式）](https://developers.openai.com/api/docs/guides/function-calling?api-mode=chat) —
  ⚠️ "Tool choice" 那一节**没有跟随 api-mode 切换**，展示的是 Responses 的扁平形状
