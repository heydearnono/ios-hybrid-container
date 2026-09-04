# 调研待办

问题驱动的清单。**一个条目 = 一个能被答案关闭的具体问题**，不写「学习 Core ML」这种没有终点的条目。

状态：⬜ 未开始 · 🟡 进行中 · 🚧 被阻塞（卡在前置阻塞项）· ✅ 已答（结论落在哪个笔记里要写清）· ❌ 已废弃

优先级：**P0** 决定技术路线，必须先答 · **P1** 影响实现方案 · **P2** 知道更好

---

## 00 · 前置阻塞项

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ⬜ | **P0** | 有没有可用的测试真机？机型和 iOS 版本是什么？—— 没有真机，**端侧两条路线都停在读文档**：Foundation Models 连模拟器都跑不通；Core ML / MLX 的性能与内存结论全部测不出（模拟器无 ANE、`os_proc_available_memory()` 返回 0、`thermalState` 恒为 `.nominal`） |
| ⬜ | **P0** | **宿主 macOS 要不要升到 26（Tahoe）？** 已实测：不升级则连模拟器都跑不了 Foundation Models（见 `01-on-device-llm/foundation-models-overview.md`）。升级 or 真机，二选一必须解决 |
| ⬜ | P1 | 目标产品的最低支持机型定在哪？这决定了端侧路径是否可用 |
| ⬜ | P1 | **deployment target 要不要从 iOS 26.0 降下来？** 当前构建产物里没用到任何 iOS 26 独有 API，真正的技术地板是 `@Observable`（iOS 17.0）；26.0 是声明性下限，且与「云端为主线、端侧做增强」有张力。降下来要动三处版本声明，代价是端侧代码需 `@available` + `#if canImport` 双重门控，并且**本机只有 iOS 26.2 一个运行时，不下载低版本运行时就无法机器验证向下兼容**。分析见 [`00-overview/troubleshooting.md`](00-overview/troubleshooting.md#一个待决问题ios-260-这个下限有必要吗) |
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
| ✅ | P1 | Core ML 与 MLX Swift 在 iOS 上分别适合什么场景？—— **交付用 Core ML，跑开源 LLM 权重才考虑 MLX**，见 [`02-coreml-mlx/coreml-vs-mlx.md`](02-coreml-mlx/coreml-vs-mlx.md)：Core ML 是唯一能碰 ANE 的路径；MLX 无 ANE、无 Apple 兼容承诺，且**本机双重阻塞**（模拟器缺 `MTLGPUFamily`；≥0.31.5 要 Swift 6.3 工具链） |
| ✅ | P1 | PyTorch → Core ML 转换的标准流程和常见失败原因？—— 全流程在本机跑通（8 项转换探针），见同一笔记。最危险的是 **`torch.jit.trace` 静默烧死数据相关分支**：转换成功、不报错、结果错，必须配数值对齐断言 |
| 🚧 | P1 | iPhone 上单个 App 的实际可用内存上限是多少？超了会怎样？—— **机制已查清**（jetsam 按 dirty memory 杀进程，`os_proc_available_memory()` 是唯一查询手段，Apple 不公布数值），但**模拟器实测返回 0**，具体数字**必须真机** —— 被 00 P0 卡住 |
| 🚧 | P1 | 在 iPhone 上跑开源模型，参数量与量化的实用上限在哪？—— **体积算得准**（4-bit ≈ 参数量的一半 MiB：1B≈0.5 / 3B≈1.5 / 7B≈3.5 GiB，8 种压缩配置已实测），**内存与速度算不准**，哪一档不被 jetsam 杀掉需真机 —— 被 00 P0 卡住 |
| ✅ | P2 | Transformer 的 KV cache 在 Core ML 上怎么处理？—— 用 `MLState` + `MLModel.makeState()`（注意**不是** `newState()`），转换侧 `ct.StateType`；Apple 官方数据（**M1 Max Mac，非 iPhone**）显示 `MLState` 式比走模型输入输出快 13 倍吞吐。滑窗/驱逐要自己在图里表达，见同一笔记 |
| 🚧 | P2 | 如何用 Xcode / Instruments 量化首 token 延迟、吞吐、峰值内存、热节流？—— 模拟器上这四项全部测不出（无 ANE、无内存约束、`thermalState` 恒为 `.nominal`），方法论待真机时和实测一起做 |
| ⬜ | P2 | `increased-memory-limit` entitlement 实际能放宽到多少、哪些机型生效？（Apple 不公布，需真机实测） |
| ⬜ | P2 | Core AI（iOS 27 / Xcode 27）与 Core ML 的关系与迁移代价？—— coremltools 9.0 没有 `ct.target.iOS27`，本机 Xcode 26.2 完全接不上，**不要写进任何交付计划** |

## 03 · 云端 LLM

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| 🟡 | **P0** | 自建后端代理的最小可行形态是什么？设备侧凭证怎么发怎么撤？—— **形态已设计**，见 [`03-cloud-llm/client-architecture.md`](03-cloud-llm/client-architecture.md)（三个端点、五项代理职责、短命凭证 + Keychain + 撤销）。剩下的是**决策**：代理放哪、用哪个厂商 —— 见 00 分组 |
| ✅ | P1 | Swift 侧 SSE 流式响应的标准实现（含取消、超时、断线重连）？—— 取消/超时/错误映射/退避重连**已实现并测试**，见 [`03-cloud-llm/streaming-in-swift.md`](03-cloud-llm/streaming-in-swift.md) |
| ✅ | P1 | 断线重连怎么做？—— **已落地为「失败即重发整个请求」，且吐过内容之后禁止重连**（厂商不给事件 `id`，`Last-Event-ID` 续传不成立） |
| 🚧 | P1 | **真正的流中途续传**要什么？—— 两种方案（稳定事件 `id` + 重放 / 幂等键 + 偏移量）都要求代理保存生成中间态，不再无状态，见 [`client-architecture.md`](03-cloud-llm/client-architecture.md)。**随 03 P0 一起定** |
| ✅ | P1 | 端侧与云端的路由判定规则怎么设计？降级链路怎么走？—— **只有三条规则**且已实现（`ModelRouter`），含「`onDeviceOnly` 绝不降级」与「不按任务难度猜」的取舍，见 [`client-architecture.md`](03-cloud-llm/client-architecture.md#端云路由与降级) |
| ⬜ | P2 | 成本测算：按典型会话长度估算单用户月成本 |

## 04 · 多模态与系统能力

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ✅ | P1 | 系统 AI 框架完整清单，以及「什么时候用框架、什么时候上模型」的判断标准 —— 见 [`00-overview/ios-ai-landscape.md`](00-overview/ios-ai-landscape.md) |
| ✅ | P1 | iOS 上有没有可用的**句向量/文本嵌入** API 做语义检索？—— **API 有，能力不够**，见 [`04-multimodal/text-embedding.md`](04-multimodal/text-embedding.md)：`NLEmbedding.sentenceEmbedding` 自 iOS 14 就有（zh-Hans 640 维），但中文检索 top-1 仅 1/5、反义句相似度反而更高；`NLContextualEmbedding.load()` 在模拟器上恒失败。**中文语义检索走系统框架不通**，用云端 embedding 或自带 Core ML 模型 |
| ⬜ | P2 | `CreateML` 框架在 iOS SDK 里也存在，端侧训练/微调的实际能力边界是什么？ |
| ⬜ | P2 | 语音转写用系统 API 的效果与限制（时长、语言、离线）？iOS 26 的 `SpeechAnalyzer` 与旧 `SFSpeechRecognizer` 怎么选？ |
| ⬜ | P2 | Image Playground / Genmoji 对第三方 App 开放到什么程度？ |

## 05 · Agent 架构

| 状态 | 优先级 | 问题 |
| --- | --- | --- |
| ✅ | **P0** | 端侧模型与云端模型的 Tool Calling 协议差异有多大？能否抽象成统一接口？—— 见 [`05-agent-arch/tool-calling.md`](05-agent-arch/tool-calling.md)：可以抽象，但只能切在「工具定义 + 单次执行」层，循环归属/错误语义/工具选择/流式可见性四项必须双实现。**中立层 + 云端侧已实现并测试**（`AgentTool` / `ToolSchema` / `ToolRegistry` + 打 stub 服务器的 31 个用例）。端侧适配器与「流式里的工具事件」另开条目 |
| 🚧 | P1 | 端侧 `DynamicTool` 适配器：编译期能否成立已验证，但**运行期行为要等硬件** —— 被 00 P0 卡住 |
| ⬜ | P1 | 流式响应要不要把工具事件暴露给 UI（「正在调用 XX 工具」）？两侧事件时序无法对齐，形状要和端侧适配器一起定 |
| ✅ | P1 | App Intents 能否直接复用为 Agent 的工具层？代价是什么？—— **不能直接复用**，见 [`05-agent-arch/app-intents-as-tools.md`](05-agent-arch/app-intents-as-tools.md)：26.2 SDK 无官方桥接，参数必须用 `@Generable` + `@Guide` 重声明一遍；但担心的「逻辑被逼进 App target」不成立，包内 Intent 能在宿主 `swift test` 里跑 |
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

