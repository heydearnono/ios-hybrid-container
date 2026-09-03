# 知识库索引

调研结论都在这里。**新增或重命名笔记必须同步更新本表。**

- 📌 = 建议先读
- ✅ 有可用结论 · 🟡 进行中 · ⬜ 未开始

## 00 · 总览

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| 📌 [ios-ai-landscape.md](00-overview/ios-ai-landscape.md) | iOS AI 能力全景地图：五条路径取舍 + 系统框架清单 + 选路顺序 | ✅ |
| [environment.md](00-overview/environment.md) | 本机工具链版本与环境约束 | ✅ |

## 01 · 端侧 LLM（Foundation Models）

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| 📌 [foundation-models-overview.md](01-on-device-llm/foundation-models-overview.md) | 框架总览：API 全貌、4096 token 等硬限制、iOS 26↔27 版本漂移 | ✅ |
| [README](01-on-device-llm/README.md) | 主线范围与目标、当前阻塞 | ✅ |

## 02 · Core ML / MLX

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| 📌 [coreml-vs-mlx.md](02-coreml-mlx/coreml-vs-mlx.md) | Core ML vs MLX Swift：交付选 Core ML（唯一能碰 ANE）、MLX 在本机双重阻塞；PyTorch→Core ML 全流程与 `trace` 静默烧死分支的坑；8 种压缩的体积实测；内存/分发体积/热节流三道墙 | ✅ |
| [README](02-coreml-mlx/README.md) | 主线范围与目标、本机环境的硬约束 | ✅ |

## 03 · 云端 LLM

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| 📌 [streaming-in-swift.md](03-cloud-llm/streaming-in-swift.md) | SSE 流式实现：字节级解析、delta→累积快照、错误映射表、退避重连、用真服务器而非 `URLProtocol` 的测试策略 | ✅ |
| [client-architecture.md](03-cloud-llm/client-architecture.md) | 客户端架构与密钥方案：为什么必须有代理、代理最小形态、设备凭证生命周期、端云路由规则、真续传需要什么 | ✅ |
| [README](03-cloud-llm/README.md) | 主线范围与目标 | ✅ |

## 04 · 多模态与系统 AI 框架

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| [text-embedding.md](04-multimodal/text-embedding.md) | 文本嵌入与语义检索：`NLEmbedding` 句向量确实存在但中文判别力不足（top-1 1/5、反义句比近义句更近）、`NLContextualEmbedding` 模拟器加载不起来 | ✅ |
| [README](04-multimodal/README.md) | 主线范围与目标 | ✅ |

## 05 · Agent 架构

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| 📌 [tool-calling.md](05-agent-arch/tool-calling.md) | 端侧 `Tool` 协议 vs 云端 `tool_calls`：签名、schema 运行期构造、流式拼接、统一抽象切在哪一层，以及云端侧的落地实现 | ✅ |
| [app-intents-as-tools.md](05-agent-arch/app-intents-as-tools.md) | App Intents 复用为工具层：26.2 无官方桥接，参数要用 `@Generable` 重声明；但 Intent 可以定义在 SPM 包里并在宿主上测 | ✅ |
| [README](05-agent-arch/README.md) | 主线范围与目标 | ✅ |

## 决策与流程

| 文件 | 内容 |
| --- | --- |
| [backlog.md](backlog.md) | 调研待办与待答问题清单 |
| [decisions/001-...](decisions/001-ios-foundation-and-model-abstraction.md) | **ADR 001**：iOS 底座形态与模型能力抽象（SPM + xcodegen；云端为主，端侧增强） |
| [decisions/002-...](decisions/002-cloud-provider-wire-format-and-testing.md) | **ADR 002**：云端提供方线格式（OpenAI 兼容）、流式统一为累积快照、集成测试打本地真服务器 |
| [decisions/](decisions/) | 技术选型决策记录（ADR）索引 |
| [templates/调研笔记模板.md](templates/调研笔记模板.md) | 新建笔记用 |
| [templates/技术选型对比模板.md](templates/技术选型对比模板.md) | 做方案对比用 |
