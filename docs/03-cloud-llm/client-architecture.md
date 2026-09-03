# 客户端架构与密钥方案

- **更新时间**：2026-09-03
- **适用版本**：iOS 26.2 SDK / Xcode 26.2（17C52）/ Swift 6.2.3；对应代码为 `Packages/AICore`
- **性质**：⚠️ **这是设计文档，不是文档摘录。** Apple 对第三方云端 LLM 的接入没有任何官方指引
  （见 [`README`](README.md)「与其他主线的区别」），所以除了明确标注链接的 Apple / 标准侧事实，
  其余是本项目的设计取舍。凡未在本机跑过的都标了 ⚠️ 未验证。
- **相关 backlog**：03 P0（后端代理最小形态与凭证发放/撤销）、03 P1（断线重连，已答）
- **相关 ADR**：[001](../decisions/001-ios-foundation-and-model-abstraction.md)、
  [002](../decisions/002-cloud-provider-wire-format-and-testing.md)

## 一句话结论

**设备侧只做三件事：拿一个短命凭证、把请求发给自己的代理、把流式字节还原成累积快照。**
厂商 Key 只存在于代理进程的环境变量里，任何形式的「藏进 App」都不成立。
这个形状已经在 `Packages/AICore` 里落实：`CloudProviderConfiguration` **在类型上拒绝字符串常量**，
只接受 `CloudCredentialProvider = @Sendable () async throws -> String?`。

还没定的是**代理放在哪、用哪个厂商、要不要覆盖中国大陆** —— 这三个只能由项目决策者拍板，
不是技术调研能关闭的问题，见[待决策项](#待决策项)。

## 为什么必须有代理：威胁模型

把 Key 打进客户端，攻击者不需要越狱设备也能拿到：

| 攻击面 | 手段 | 混淆能挡住吗 |
| --- | --- | --- |
| App 包体 | 从 App Store 或设备上取出 `.ipa`，解包后 `strings` 扫二进制 / 反汇编 | 不能，只是提高门槛 |
| 网络流量 | 装一个本地 HTTPS 代理 + 信任自签根证书，直接读明文请求头 | 不能，`Authorization` 头必须以明文到达服务端 |
| 运行期内存 | 越狱设备上 dump 内存，或用调试器附加 | 不能 |

第二行是关键：**只要设备直连厂商，Key 就必然以可读形式出现在设备的网络栈里。**
证书固定（[`NSPinnedDomains`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nspinneddomains)）
能挡住「用户自己抓包」这一档，但挡不住有耐心的攻击者，也挡不住 Key 一旦泄露就是**全量额度**这个后果。

反过来，代理架构下泄露一个设备凭证的后果被限制成「这一个用户的额度」，而且可以单独撤销。
这不是「更安全一点」的差别，是**能不能兜住**的差别。

## 分层

```
App（AICore）──①──> 自建代理 ──②──> 厂商 API
   持：短命用户凭证        持：厂商 Key + 配额/审计
```

- ① **我们自己定的协议。** 现在是 OpenAI 兼容形状（ADR 002），因为它是事实标准、
  能用现成 stub 服务器测；但既然两端都是自己的，将来想换随时能换。
- ② 厂商协议，代理负责适配。**模型名也在这里映射** —— App 里写 `configuration.model` 的值
  应该是我们自己的档位名（如 `chat-default`），不是厂商型号，否则换厂商要发版。

## 代理的最小可行形态

「最小」的判据是：**去掉任何一个，客户端就必须做一件它做不好或不该做的事。**

| 端点 | 作用 | 去掉会怎样 |
| --- | --- | --- |
| `POST /v1/auth/token` | 用登录态换一个短命访问凭证（附带过期时间） | 设备只能长期持有一个不会过期的凭证，泄露即永久有效 |
| `POST /v1/chat/completions` | 透传对话请求，支持 `stream: true` | 无从隐藏厂商 Key |
| `POST /v1/auth/revoke`（或后台管理面） | 撤销某个用户/设备的凭证 | 发现滥用时只能改厂商 Key，等于让所有用户下线 |

代理必须承担的职责，按「客户端做不到」排序：

1. **持有厂商 Key**，从环境变量或密钥管理服务读，不写进镜像。
2. **按用户计额度并限流。** 客户端的任何限制都能被绕过 —— 改包、重放请求都行。
   额度耗尽应返回 429 + `Retry-After`，`AICore` 已经把它映射成
   `ModelError.rateLimited(retryAfter:)` 并据此退避（见 `CloudFailureMapper`）。
3. **保留上游错误语义。** 401/403/429/5xx 原样透出，别一律包成 200 + 业务错误码 ——
   `AICore` 的错误映射与重试判定完全建立在状态码上，包成 200 会让所有重试策略失效。
4. **审计日志**（谁在什么时候用了多少 token）。这是成本归因唯一可信的来源，
   客户端上报的用量不可信。
5. **SSE 逐块转发，不缓冲、不重排、不改写字节。** 这是最容易被基础设施悄悄破坏的一条 ——
   反向代理默认会缓冲响应体（nginx 需要显式
   [`proxy_buffering off`](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffering)），
   一缓冲流式就退化成「等全部生成完再一次性吐出」，功能不报错但首 token 延迟从 1 秒变成 20 秒。
   ⚠️ 未验证：具体网关（CDN / 云函数 / API Gateway）的缓冲行为各不相同，接上之后必须实测首片到达时间。

**刻意不放进代理的两件事**：会话状态与提示词模板。会话历史留在客户端（`ModelRequest` 自带全量
消息），代理保持无状态才能横向扩容；提示词模板放代理虽然能热更新，但会让「同一次请求发出去到底
是什么内容」在客户端不可见，调试成本极高。

## 设备侧凭证

### 形态

**短命访问凭证 + 可撤销的长期凭据**，两者分开：

| 项 | 取值 | 理由 |
| --- | --- | --- |
| 访问凭证有效期 | 分钟到小时级 | 泄露窗口有限；`AICore` 每次请求都现取，天然支持轮换 |
| 长期凭据 | 存 Keychain，可被服务端单独撤销 | 撤销粒度必须细到单个用户/设备 |
| 绑定 | 用户 ID + 设备标识 | 同一凭证在异常多的设备上出现即可判定泄露 |

`CloudCredentialProvider` 是 `async throws -> String?` 而不是同步取值，正是为这个形态留的口子：
闭包内部可以先看缓存的访问凭证是否过期、过期就用长期凭据去换新的，再返回。
返回 `nil` 表示「现在没有可用凭证」，provider 会如实报 `.unavailable(.notConfigured)`
而不是发一个注定 401 的请求。

### 存哪里

存 Keychain，可访问性用
[`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)：

- `AfterFirstUnlock` 而不是 `WhenUnlocked` —— 否则锁屏后台刷新凭证会失败；
- `ThisDeviceOnly` 是**必须的**：不带这个后缀的项会进 iCloud Keychain 备份并同步到用户其他设备
  （见 [Keychain item accessibility 常量表](https://developer.apple.com/documentation/security/keychain-services/item-attribute-keys-and-values)），
  设备绑定的凭证跟着同步过去只会制造「凭证在陌生设备上出现」的误报。

不要用 `UserDefaults`：它是明文 plist，备份即泄露。

### 反滥用 ≠ 鉴权

[App Attest / DeviceCheck](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
能证明「请求来自一个未被篡改的、真实设备上的本 App」，用来挡自动化刷额度是合适的。
但它**不能替代用户鉴权**：断言只说明客户端可信，不说明这是谁。两者是叠加关系，不是替代关系。
⚠️ 未验证：本项目没有跑过 App Attest —— 它需要真机（模拟器不支持 attestation）。

### 过期与重放

- **过期**：401 时 `AICore` 报 `.unavailable(.notConfigured)` 且**不重试**
  （见 `ReconnectPolicy`：凭证问题重试只会再失败一次）。所以「换新凭证后重发」这件事
  必须由 `CloudCredentialProvider` 内部完成，不能指望重试机制兜。
- **重放**：HTTPS 已经挡住路径上的被动重放；真正的风险是凭证泄露后的主动重放，
  只能靠短有效期 + 撤销 + 服务端异常检测，客户端做不了。
  ⚠️ 不打算做请求签名（body HMAC）：密钥仍要放在客户端，挡不住反编译，只增加复杂度。

## 代码里已经落实的部分

不需要等后端就能确认的部分，都已经在 `Packages/AICore` 里并有测试覆盖：

| 设计约束 | 落实位置 |
| --- | --- |
| 拒绝硬编码 Key | `CloudProviderConfiguration` 只接受 `CloudCredentialProvider` 闭包 |
| 没凭证不发请求 | `availability()` 只看凭证有无，**不发探测请求**（省钱且探测结果本来就会过期） |
| 错误语义按状态码收敛 | `CloudFailureMapper`，流式与非流式共用同一套映射 |
| 重连语义 | 「失败即重发整个请求」，**吐过内容之后禁止重连**（`ReconnectPolicy`） |
| 工具循环封顶 | `maximumToolIterations`，默认 5，超限抛 `.toolLoopLimitExceeded` |
| 端点可配 | `chatCompletionsPath` / `extraHeaders` / `authorizationScheme`，自建代理挂在别的路径下也能接 |

**默认装配仍然是 mock**（`ProviderFactory.makeDefaultRouter`）—— 代理不存在，`baseURL` 无处可指。
真实装配的入口是 `ProviderFactory.makeCloud(baseURL:model:credential:reconnect:tools:)`，
后端就位后接进 `makeDefaultRouter` 即可，UI 不用改。

## 端云路由与降级

判定规则已经实现在 `ModelRouter` 里，**规则本身只有三条**，刻意不做得更聪明：

| 触发条件 | 走哪条 | `RoutingReason` |
| --- | --- | --- |
| `privacy == .onDeviceOnly` | 只走端侧；端侧不可用就**如实失败** | `.privacyRequiredOnDevice` |
| 云端可用 | 云端 | `.primaryAvailable` |
| 云端不可用且端侧可用 | 端侧，并记下云端的不可用原因 | `.fellBackToOnDevice(primaryReason:)` |
| 两条都不可用 | 抛云端的不可用原因（不是端侧的） | — |

三条设计取舍，每条都有测试覆盖：

- **`onDeviceOnly` 绝不降级到云端。** 静默降级会把隐私承诺变成谎言 —— 这是架构不变量之一。
  连「端侧没配置」也报 `.unavailable(.notConfigured)` 而不是找云端顶上。
- **不按「任务难度」路由。** 「简单问题走端侧、复杂问题走云端」听起来合理，但判断难度本身就需要
  一次模型调用，而且判错的代价（端侧给出低质量回答）比省下的钱贵。
  真要做，应该由业务层显式选档（`ModelRequest` 携带意图），不该由路由器猜。
- **超时由路由器强制施加**，不信任提供方：端侧模型不可用时 `respond()` 会挂死且不抛错、
  也不响应取消。流式侧的看门狗只守「首片」—— 首片到了说明链路是活的，
  之后的停顿属于生成慢，不该被判超时。

⚠️ 端侧那一档目前是 mock（固定报 `.unavailable(.modelNotReady)`，如实复刻本机实测状态）。
所以**降级路径与隐私拒绝路径现在就能被真实触发并测试**，但「端侧真的答一句」还没发生过。

## 真正的流中途续传，需要代理配合

现在的重连语义是**重发整个请求**，而且一旦有内容吐给了 UI 就不再重连 ——
因为重发拿回的是一段全新文本，接不上已经显示出去的部分（详见
[`streaming-in-swift.md`](streaming-in-swift.md)）。这不是偷懒，是厂商侧没给续传所需的东西：

- SSE 标准的续传机制是 `Last-Event-ID`
  （[HTML Standard · Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html#the-last-event-id-header)），
  前提是服务端给每个事件发**稳定的 `id`** 且能从任意 id 之后重放；
- ⚠️ 厂商的 chat completions 流**不发 `id` 字段**（本项目的 `SSEParser` 支持解析 `id`，
  但没有真实厂商流可以验证这一点），所以标准机制在这条链路上不成立。

要做真续传，只能在**我们自己的协议**上加，两种形态：

| 方案 | 代理要做什么 | 代价 |
| --- | --- | --- |
| 稳定事件 id + 重放 | 缓存本次生成已产出的全部增量，按 id 之后重放 | 代理要为每个进行中的请求保存状态，且必须设过期 |
| 幂等键 + 偏移量 | 客户端带 `Idempotency-Key` 和已收到的字符偏移，代理从偏移处继续吐 | 同上，另外要保证同一幂等键不会真的向厂商发第二次 |

两种都要求**代理保存生成中间态**，也就是说它不再无状态。这个取舍要和 03 P0 一起定，
所以本项目现在只做「重发」这一档，并把限制如实写进类型（`ReconnectPolicy` 的注释）。

## 待决策项

这三个只能由项目决策者拍板，技术调研无法关闭。它们都在 [`../backlog.md`](../backlog.md)：

1. **代理放在哪。** 自有服务器 / 云函数 / 容器服务。影响 SSE 缓冲行为（见上）、
   冷启动延迟、以及能不能长连接 —— 有些无服务器平台对响应时长有硬上限，长回答会被截断。
2. **用哪个厂商、哪个档位。** 决定成本模型与 `tools` / `strict` 的实际兼容性
   （`usesStrictToolSchema` 留了开关就是为这个：⚠️ 部分自建网关不认 `strict`，遇 400 先关掉）。
3. **是否覆盖中国大陆。** 若覆盖，端侧 Apple Intelligence 不可用（地区限制），
   端侧路径只能当增强而非兜底；同时厂商与合规要求完全不同。

## 未验证清单

- ⚠️ 全部端到端行为。**本项目没有对任何真实厂商端点或真实代理发过一次请求。**
  已验证的是「我们发出的字节符合 OpenAI 兼容 spec」（打本地 stub 服务器，真 `URLSession` + 真 SSE）。
- ⚠️ 反向代理 / 网关的 SSE 缓冲与超时行为。
- ⚠️ App Attest（需要真机）。
- ⚠️ 真实厂商是否在流里发 `id`、是否支持任何形式的续传。
- ⚠️ 429 的 `Retry-After` 在各厂商的实际存在性与单位（`CloudFailureMapper` 只解析秒数，
  解析不了就返回 `nil` 并退回默认退避）。

## 参考来源

- [`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)、
  [Keychain 属性键与取值](https://developer.apple.com/documentation/security/keychain-services/item-attribute-keys-and-values)
- [Establishing your app's integrity（App Attest / DeviceCheck）](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [`NSPinnedDomains`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nspinneddomains)
- [HTML Standard · Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
- [nginx `proxy_buffering`](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffering)
- 本项目：[`streaming-in-swift.md`](streaming-in-swift.md)、
  [`../05-agent-arch/tool-calling.md`](../05-agent-arch/tool-calling.md)、
  [ADR 002](../decisions/002-cloud-provider-wire-format-and-testing.md)
