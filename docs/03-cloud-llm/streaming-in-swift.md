# Swift 侧 SSE 流式响应

- **更新时间**：2026-09-03
- **适用版本**：Swift 6.2.3 / Xcode 26.2 (17C52) / iOS 26.2 SDK。逻辑测试跑在宿主 macOS 15.7.3
- **验证方式**：本地 stub HTTP 服务器 + 真实 `URLSession` + 真实 socket，`swift test` 全绿。
  ⚠️ **从未对任何真实厂商端点发过请求** —— 线格式（wire format）本身仍属未验证
- **相关 spike**：无。实现直接落在 `Packages/AICore/`，因为它是要长期留下的产品代码

## 一句话结论

能用，而且整条链路可以在**不持有任何厂商凭证、不联外网**的前提下被机器验证完 ——
方法是在测试里起一个只绑 `127.0.0.1` 的真 HTTP 服务器。

三个最容易踩的坑，都已经用测试钉住了：**UTF-8 多字节字符会被 TCP 分片切断**（所以解析器必须缓冲字节而不是字符串）、
**服务端可能不发 `[DONE]` 就关连接**（不补终片 UI 会永远停在「正在回答」）、
**HTTP 200 里也能藏失败**（`finish_reason: content_filter`，只看状态码会把它当成功）。

唯一没做的是**断线重连**（SSE 的 `Last-Event-ID` / `retry` 机制），见下文边界一节。

## 能做什么

已实现且有测试覆盖（`Packages/AICore/`）：

| 能力 | 实现位置 | 测试 |
| --- | --- | --- |
| 增量喂字节的 SSE 解析（`data:` / `event:` / `id:` / `retry:`） | `SSEParser.swift` | `SSEParserTests`（18） |
| 非流式 chat completions 往返 | `CloudLanguageModelProvider.swift` | `CloudProviderTests`（8） |
| 流式 delta → **累积快照** 转换 | `CloudLanguageModelProvider+Streaming.swift` | 同上 |
| 厂商失败 → `ModelError` 映射 | `CloudProviderConfiguration.swift` 内 `CloudFailureMapper` | `CloudErrorMappingTests` + `CloudFailureMapperTests`（15） |
| 超时兜底（连上了但服务端挂着不吐字节） | `ModelRouter.withTimeout` | 同上，`.hang` 场景 |
| 取消（消费者中途 `break`） | `Task.checkCancellation()` + 流的 `onTermination` | 同上 |

配置形态刻意收窄：`CloudProviderConfiguration` **不接受字符串常量作为密钥**，
只接受 `CloudCredentialProvider = @Sendable () async throws -> String?` 闭包。
理由见 [`README.md`](README.md) 的安全底线一节 —— 这不是风格问题。

## 不能做什么 / 边界

- 🔴 **断线重连没做**。SSE 规范定义了 `id:` 字段 + `Last-Event-ID` 请求头 + `retry:` 重连间隔，
  `SSEParser` 已经把三者都解析出来了，但上层没有消费它们。
  流中途断开当前表现为抛错，不会自动续传。**backlog 03 P1 因此只能算部分回答。**
  真要做，还得先确认后端代理是否为事件分配稳定 `id` —— 大模型厂商的流普遍不分配，
  所以更可能的落点是「重连即重发整个请求」而不是断点续传。
- 🔴 **线格式未对真实端点验证**。用的是 OpenAI 兼容的 `/v1/chat/completions` schema
  （事实标准，多数厂商与自建代理都兼容），但 stub 服务器是我自己写的 ——
  它只能证明「我的解析器和我的假设一致」，不能证明「我的假设和厂商一致」。
- ⬜ **多轮会话没做**。`ModelRequest` 只有单个 `prompt` + 可选 `systemInstructions`，
  没有 message 列表。上下文裁剪/摘要策略是 backlog 05 P1。
- ⬜ **Tool calling 没做**。`tools` / `tool_calls` 字段完全没碰。这是 ADR 001 列的头号风险
  （端侧与云端协议差异），仍是 backlog 05 P0。
- ⬜ **token 计数与用量没做**。`usage` 字段未解析，所以成本测算（03 P2）还无从下手。
- ⬜ **重试与退避没做**。`.rateLimited(retryAfter:)` 把服务端给的秒数如实带出来了，
  但没有任何一层会自动重试 —— 决定权留给调用方。

## 关键 API

三层，各自可独立测试。**分层的动机是可测性**：`SSEParser` 是纯值类型，
不碰网络，所以能穷举分片边界；网络那层就只剩「把字节交给它」这一件事。

```swift
import AICore

// 1) 解析层：纯函数式，喂字节吐事件。不知道 HTTP 的存在。
var parser = SSEParser()
let events: [SSEEvent] = parser.consume(someBytes)   // 可反复调用，跨调用保持状态
let tail = parser.finish()                            // 连接关闭时冲刷残留

// 2) 提供方层
let provider = CloudLanguageModelProvider(
    configuration: CloudProviderConfiguration(baseURL: proxyURL, model: "some-model"),
    credential: { await CredentialStore.shared.currentToken() }  // 闭包，不是字符串
)

// 3) 消费：每片都是**累积快照**，UI 直接赋值，不要 append
for try await chunk in provider.streamResponse(to: ModelRequest(prompt: "你好")) {
    label.text = chunk.cumulativeText
    if chunk.isFinal { break }
}
```

`SSEEvent` 的 `event:` 字段在 Swift 里叫 `type` —— `event` 作为属性名跟类型名读起来会打架。

字节流的取用方式是 `URLSession.bytes(for:)`，拿到 `URLSession.AsyncBytes`（`Element == UInt8`）。
冲刷策略：**遇到 `\n` 立刻交给解析器**，另外加一个 4096 字节的上限兜底。
按行冲刷是为了首 token 最快到 UI；上限只是防一个不吐换行的坏服务端把内存吃光。

## 三个非显然的结论

### 1. 解析器必须缓冲 `[UInt8]`，不能缓冲 `String`

真实网络分片不会体贴地落在字符边界上。一个汉字 3 字节、emoji 4 字节，
`String(decoding:as:UTF8.self)` 遇到半个字符会静默替换成 `U+FFFD`，
于是**乱码是不可逆的** —— 下一片再来也拼不回去了。

测试 `streamingSurvivesByteLevelSplits` 直接把整个响应**逐字节**推送（每片 1 字节），
断言最终文本仍是 `汉字🎉表情混合ab`。另有 `chunkSizeInvariant`：同一份数据用
1...N 的所有分片大小切一遍，结果必须完全一致。

### 2. 刻意偏离 SSE 规范一处：末尾不完整事件要派发，不能丢

规范说得很清楚：流结束时，尚未以空行结尾的不完整事件**应当丢弃**
（见 [WHATWG SSE 处理模型](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation)）。

但真实服务端经常在最后一帧之后直接关连接，不补那个空行。严格照规范做，
用户会稳定丢掉最后一个 token。**丢数据比偏离规范更糟**，所以 `finish()` 会补一次派发。

同源的另一个问题：服务端可能连 `[DONE]` 都不发。流式实现在字节耗尽后无条件补一个
`isFinal: true` 的终片 —— 否则 UI 永远停在「正在回答」，而实际上已经没有后续了。
测试 `missingDoneSentinelStillFinishes` 钉住这条。

### 3. HTTP 200 不等于成功

`finish_reason` 可以是 `content_filter` / `safety`，而**状态码仍是 200**。
只看状态码就会把它当成功，用户拿到一个莫名截断的空回答，且没有任何错误提示。
流式和非流式两条路径都要单独识别（`CloudWire.contentFilterFinishReasons`）。

同理，200 的响应体里也可能带 `error` 载荷。另外 `error.code` 在不同厂商里
**有时是字符串、有时是整数**，所以 `ErrorPayload` 写了自定义 `init(from:)` 两种都吃。

## 错误映射表

设计原则：**同一个失败在流式和非流式两条路径上必须给出同一个 `ModelError`**。
测试用 `expectSameErrorOnBothPaths` 把每个失败都跑两遍来强制这一点 ——
两条路径各写一遍错误处理，迟早会漂移。

| 服务端表现 | 映射为 | 为什么要单独区分 |
| --- | --- | --- |
| 401 | `.unavailable(.notConfigured)` | 凭证问题，重试无用，该去刷新 token |
| 403 且提到 country/region/territory | `.unavailable(.regionUnsupported)` | 直接关联 backlog「目标市场是否含中国大陆」，不能混进泛化网络错误 |
| 403 其他 | `.unavailable(.notConfigured)` | |
| 429 | `.rateLimited(retryAfter:)` | 解析 `Retry-After` **秒数**；HTTP 日期格式不解析，如实返回 `nil` 而不是猜 |
| 400 且提到 maximum context length | `.contextWindowExceeded(limit:)` | 该裁剪上下文，不是该重试。`limit` 尽力解析，抠不出来给 `nil` |
| 400 且提到 content_filter | `.guardrailViolation` | 改写 prompt 才有用 |
| 5xx | `.network(detail:)` | 可重试 |
| `URLError.timedOut` | `.timedOut(duration)` | |
| `URLError.cancelled` / `CancellationError` | `.cancelled` | 用户主动取消不该弹错误 UI |
| 已经是 `ModelError` | 原样透传 | 包一层会丢掉语义 |

响应体会被截断到 500 字符（`CloudFailureMapper.bodyLimit`）——
网关出错时返回整页 HTML 是常态，把它塞进错误信息只会污染日志。

## 测试策略：为什么起真服务器，而不是打桩 `URLProtocol`

自定义 `URLProtocol` 能让测试更快，也是常见做法。**但它绕过了整个网络栈**，
而这条链路上最容易出错的部分恰好全在网络栈里：分片边界、连接关闭时机、状态码处理。
用 `URLProtocol` 测出来的绿，证明不了真实网络下也绿。

所以 `Tests/AICoreTests/Support/StubHTTPServer.swift` 用 `Network` 框架的 `NWListener`
起了一个真的 HTTP/1.1 服务器，走真 socket、真 `URLSession`。四种应答模式：

| 模式 | 用途 |
| --- | --- |
| `.complete(status:...)` | 带 `Content-Length` 的一次性响应，测状态码与错误映射 |
| `.sse(frames:perFrameDelay:)` | 按帧推送，帧间可插延迟 |
| `.rawChunks(_:perChunkDelay:)` | 按任意字节切分推送 —— 用来把 UTF-8 序列切在分片边界上 |
| `.hang` | 接受连接后什么都不回也不关，测超时兜底 |

两个约束值得记下来：

- **只绑 `127.0.0.1`**。既是隔离，也是为了不触发 macOS 防火墙的「是否允许接受传入连接」
  弹窗 —— 那个弹窗需要人点，会直接破坏「机器无人工干预地验证」这条硬约束。
  写之前先用一个独立小程序验过：回环监听不弹窗。
- **端口交给系统分配**（`port: .any`），避免测试并发时抢端口。
- 不带 `Content-Length` 的响应用 `Connection: close` 界定结束 ——
  HTTP/1.1 允许，`URLSession` 也认。SSE 就是靠这个收尾的。

## 实测数据

| 指标 | 环境 | 数值 | 备注 |
| --- | --- | --- | --- |
| 逻辑测试耗时 | 宿主 macOS 15.7.3，`swift test` | AICore 55 tests / 7 suites ≈ 0.42s；AIFeatures 7 tests ≈ 0.50s | 其中 19 个用例真的起了 socket |
| 超时兜底生效 | `.hang` 服务器，请求超时设 400ms | 流式与非流式均在 5s 内抛 `.timedOut` | 契约是「一定会返回」，不是「哪一层先超时」 |
| 首 token 延迟 | — | **未实测** | 打本机 stub 测这个没有意义，要等真实端点 |
| 吞吐 / 成本 | — | **未实测** | `usage` 字段还没解析 |

## 踩坑记录

- **`NWListener` 的 `newConnectionHandler` 必须在 `start()` 之前装好。**
  装晚了 listener 会拒掉先到的连接，客户端表现为 `-1004 Could not connect to the server`。
  这个现象非常像「端口没绑上」，实际是回调时序问题 —— 我先用一个独立小程序证明了
  回环监听本身没问题，才定位到时序。
  连带的坑：想在闭包里捕获 `self` 就得让 `self` 先完成初始化，
  所以 `port` 声明成 `private(set) var port: UInt16 = 0`（给默认值），
  拿到系统分配的端口后再回填。

- **`swift test --filter` 匹配的是类型名，不是 `@Suite` 的显示名。**
  `--filter "SSE 解析器"` 匹配 0 个用例，要写 `--filter SSEParserTests`。

- **`#expect(throws: ModelError.self)` 会造成假通过。**
  `undecodableFrameFails` 本意是验证解析失败，但连不上服务器时抛的也是 `ModelError`，
  测试照样变绿。已改成捕获返回的错误再 `guard case .decodingFailure`，
  不匹配就 `Issue.record`。**只断言「抛了错」等于没断言。**

- **同一个错误别在两处各写一遍。** 流式和非流式最初各自处理状态码，很快就漂移了。
  抽出 `CloudFailureMapper` 让两条路径共用，并用一个跑两遍的测试辅助函数锁住。

- **顶层裸字符串的 JSON 编码在不同 Foundation 版本上行为不一致**，
  所以测试辅助里的 `jsonString(_:)` 是手写的转义，没用 `JSONEncoder`。
  测试辅助代码不该踩这种坑。

- **`verify.sh` 一次假失败**：AICore 全绿但 AIFeatures 报
  `cannot find type 'CloudCredentialProvider' in scope`。三个符号确认都是 `public`，
  删掉两个 `.build` 目录从干净状态重跑就绿了 —— 增量构建产物过期，不是代码问题。
  **结论：改了跨包的 public API 之后，绿了也要从干净状态复验一次。**

## 结论与下一步

- 选型倾向：**用**。这套三层结构（纯解析器 / 提供方 / 路由）可以直接进生产，
  后端代理就位后要改的只有 `baseURL` 和凭证来源，UI 一行不用动。
- 默认装配**仍然是 mock**（`ProviderFactory.makeDefaultRouter()`），
  因为没有后端代理，`baseURL` 无处可指。真实装配走 `ProviderFactory.makeRouter(cloudBaseURL:model:credential:)`。
- 待验证问题（已登记到 [`../backlog.md`](../backlog.md)）：
  - 断线重连（03 P1 的剩余部分）—— 需先确认后端是否分配稳定事件 `id`
  - 自建后端代理的最小形态与凭证发放/撤销（03 **P0**，只有用户能决定）
  - 真实端点上的线格式核对：`usage`、`tool_calls`、错误载荷的实际形状

## 参考来源

- [WHATWG HTML · Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html) —
  字段语义、行终止符（CRLF/LF/CR）、`data:` 后单个前导空格的剥离、BOM 处理、
  以及「末尾不完整事件应丢弃」那条（本实现刻意偏离，理由见上）
- [`URLSession.bytes(for:delegate:)`](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:)) —
  拿到 `AsyncBytes` 逐字节消费响应，流式的入口
- [`NWListener`](https://developer.apple.com/documentation/network/nwlistener) —
  测试用本地服务器的基础；`requiredLocalEndpoint` 用来强制只绑回环
- [MDN · `Retry-After`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Retry-After) —
  两种合法格式（delay-seconds 与 HTTP-date），本实现只解析前者
- OpenAI Chat Completions 的流式响应格式（`platform.openai.com/docs/api-reference/chat/streaming`，
  该站点拒绝自动化访问，需人工打开）—— 事实标准 schema 的来源。
  ⚠️ 未验证：本项目未对该端点发过任何请求
