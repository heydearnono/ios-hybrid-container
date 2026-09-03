# 调研待办

问题驱动的清单。**一个条目 = 一个能被答案关闭的具体问题**，不写「学习 Core ML」这种没有终点的条目。

状态：⬜ 未开始 · 🟡 进行中 · 🚧 被阻塞（卡在前置阻塞项）· ✅ 已答（结论落在哪个笔记里要写清）· ❌ 已废弃

优先级：**P0** 决定技术路线，必须先答 · **P1** 影响实现方案 · **P2** 知道更好

---

## 00 · 前置阻塞项

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ⬜ | **P0** | 有没有可用的测试真机？机型和 iOS 版本是什么？—— 没有真机，端侧 LLM 主线只能停在读文档 |
| ⬜ | **P0** | **宿主 macOS 要不要升到 26（Tahoe）？** 已实测：不升级则连模拟器都跑不了 Foundation Models（见 `01-on-device-llm/foundation-models-overview.md`）。升级 or 真机，二选一必须解决 |
| ⬜ | P1 | 目标产品的最低支持机型定在哪？这决定了端侧路径是否可用 |
| ⬜ | P1 | 目标市场是否包含中国大陆？—— 若包含，Apple Intelligence 不可用，端侧 LLM 只能当增强 |

## 01 · 端侧 LLM

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| 🚧 | P1 | 中文能力实际表现如何？（必须实测，官方文档不会给这个答案）—— **被前置阻塞项卡住** |
| 🚧 | P1 | 结构化输出的可靠性：复杂嵌套类型能否稳定生成？`decodingFailure` 触发率？—— **被前置阻塞项卡住** |
| 🚧 | P1 | 安全护栏被触发时如何感知与处理？误伤率如何？—— 机制已查清（见笔记），误伤率需实测 |
| ⬜ | P1 | 后台限流的实际数值是多少？官方只说「system defined」，没给数字 |
| ⬜ | P2 | 上下文溢出的实际余量：是否不到 4096 token 就抛错？ |

## 02 · Core ML / MLX

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ⬜ | P1 | iPhone 上单个 App 的实际可用内存上限是多少？超了会怎样？ |
| ⬜ | P1 | 在 iPhone 上跑开源模型，参数量与量化的实用上限在哪？ |
| ⬜ | P1 | Core ML 与 MLX Swift 在 iOS 上分别适合什么场景？ |
| ⬜ | P1 | PyTorch → Core ML 转换的标准流程和常见失败原因？ |
| ⬜ | P2 | Transformer 的 KV cache 在 Core ML 上怎么处理？ |
| ⬜ | P2 | 如何用 Xcode / Instruments 量化首 token 延迟、吞吐、峰值内存、热节流？ |

## 03 · 云端 LLM

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ⬜ | **P0** | 自建后端代理的最小可行形态是什么？设备侧凭证怎么发怎么撤？ |
| 🟡 | P1 | Swift 侧 SSE 流式响应的标准实现（含取消、超时、断线重连）？—— 取消/超时/错误映射**已实现并测试**，见 [`03-cloud-llm/streaming-in-swift.md`](03-cloud-llm/streaming-in-swift.md)；**断线重连未做**，故不关闭 |
| ⬜ | P1 | 断线重连怎么做？大模型厂商的流普遍不为事件分配 `id`，`Last-Event-ID` 续传可能不成立 —— 是否只能退化为「重连即重发整个请求」？ |
| ⬜ | P1 | 端侧与云端的路由判定规则怎么设计？降级链路怎么走？ |
| ⬜ | P2 | 成本测算：按典型会话长度估算单用户月成本 |

## 04 · 多模态与系统能力

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ✅ | P1 | 系统 AI 框架完整清单，以及「什么时候用框架、什么时候上模型」的判断标准 —— 见 [`00-overview/ios-ai-landscape.md`](00-overview/ios-ai-landscape.md) |
| ⬜ | P1 | iOS 上有没有可用的**句向量/文本嵌入** API 做语义检索？（`NLEmbedding` 只是词向量） |
| ⬜ | P2 | `CreateML` 框架在 iOS SDK 里也存在，端侧训练/微调的实际能力边界是什么？ |
| ⬜ | P2 | 语音转写用系统 API 的效果与限制（时长、语言、离线）？iOS 26 的 `SpeechAnalyzer` 与旧 `SFSpeechRecognizer` 怎么选？ |
| ⬜ | P2 | Image Playground / Genmoji 对第三方 App 开放到什么程度？ |

## 05 · Agent 架构

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ⬜ | **P0** | 端侧模型与云端模型的 Tool Calling 协议差异有多大？能否抽象成统一接口？ |
| ⬜ | P1 | App Intents 能否直接复用为 Agent 的工具层？代价是什么？ |
| ⬜ | P1 | 上下文窗口小的情况下，多轮对话的裁剪/摘要策略？ |
| ⬜ | P2 | Agent 任务完成度如何评测？端侧能否做自动化评测？ |

---

## 已答问题归档

结论都在 [`01-on-device-llm/foundation-models-overview.md`](01-on-device-llm/foundation-models-overview.md)（2026-09-01）：

| 优先级 | 问题 | 结论摘要 |
| --- | --- | --- |
| **P0** | Foundation Models 完整 API 面？会话/流式/结构化/工具调用怎么写？ | 全部查清并在 iOS 26.2 SDK 上编译验证。流式吐**累积快照**不是 delta；`Tool` 只需实现 `description` + `call`；见笔记「关键 API」 |
| **P0** | 硬限制：上下文多大？支持哪些语言？是否限流？ | **4096 token/session，进出共用**；中文约 1 字符/token（≈4000 汉字天花板）；官方 16 种语言含简体中文，实测 `supportedLanguages` 返回 23 个标识；`rateLimited` 仅后台超限 |
| **P0** | 哪些机型 + 哪个 OS 起可用？降级判定 API？ | iPhone 15 Pro / 16+、M1+ iPad、Apple 芯片 Mac；iOS 26.0+；需用户开启 Apple Intelligence + 7GB 存储。判定用 `SystemLanguageModel.availability`，`UnavailableReason` 三个 case 且非 `@frozen` |
| P1 | Apple Intelligence 在 iOS 26.2 模拟器上能否跑通？ | **不能**。模拟器复用宿主 Mac 模型资源，本机 macOS 15.7.3 无 Apple Intelligence → `.unavailable(.modelNotReady)`。已转为前置阻塞项「宿主 macOS 是否升 26」 |
| P2 | LoRA 适配器的门槛与维护代价？ | **别碰**。每个系统模型版本都要重训，工具包 26.0.0 是末版且不兼容 27，iOS 27 文档页已 404 |

