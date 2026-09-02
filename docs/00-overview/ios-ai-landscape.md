# iOS AI 能力全景地图

- **更新时间**：2026-09-01
- **适用版本**：iOS 26.2 SDK / Xcode 26.2（17C52）/ Swift 6.2.3
- **验证方式**：官方文档 + 本机 iOS 26.2 SDK `.swiftinterface` 符号核对（确认框架与类型真实存在），
  未做性能实测
- **相关 spike**：[`spikes/foundation-models-01/`](../../spikes/foundation-models-01/)

## 一句话结论

**先找现成的系统框架，找不到再上模型** —— 这也是 Apple 自己写在文档里的顺序。
端侧生成式（Foundation Models）只是五条路径中的一条，而且是限制最多的一条
（4096 token、必须开 Apple Intelligence、机型受限、中国大陆不可用）。
真正需要自己训模型的场景，比动手前想象的少得多。

## 五条路径

| # | 路径 | 典型能力 | 关键限制 | 边际成本 | 本项目目录 |
| --- | --- | --- | --- | --- | --- |
| 1 | **系统 AI 框架** | OCR、人体/人脸、分词词性、语音转写、声音分类、翻译 | 能力固定，不能改行为；部分需下载资源 | 0（系统内置） | [04-multimodal](../04-multimodal/) |
| 2 | **端侧生成式 LLM**<br>Foundation Models | 摘要、改写、分类、结构化抽取、Tool Calling | 4096 token/会话；需 Apple Intelligence；iPhone 15 Pro / 16+；中国大陆不可用 | 0（无 API 费用） | [01-on-device-llm](../01-on-device-llm/) |
| 3 | **自带模型推理**<br>Core ML / MLX / MPSGraph | 跑自己或开源的模型，行为完全可控 | 内存/发热/包体；模型转换与量化工作量大 | 0（但研发成本最高） | [02-coreml-mlx](../02-coreml-mlx/) |
| 4 | **云端 LLM** | 最强模型能力、长上下文、多模态 | 联网、延迟、隐私合规、按 token 计费；**需自建代理，密钥不能进客户端** | 按调用量付费 | [03-cloud-llm](../03-cloud-llm/) |
| 5 | **系统入口与 Agent 化**<br>App Intents / Image Playground | 把能力暴露给 Siri、快捷指令、Spotlight；调起系统图像生成 | 交互形态由系统定；生成式入口需 Apple Intelligence | 0 | [05-agent-arch](../05-agent-arch/) |

这五条不是互斥选项，正常产品会**同时用三条以上**：
系统框架做感知（1）→ 端侧模型做轻量理解（2）→ 复杂任务降级到云端（4）→ 通过 App Intents 暴露（5）。
路径 3 只在前面几条都满足不了需求时才考虑。

## 系统 AI 框架清单

下表框架均已在本机 iOS 26.2 SDK 中确认存在（`$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/`）。
「需 AI」列指是否依赖 Apple Intelligence（即受机型 + 用户开关 + 地区限制）。

| 框架 | 干什么 | 需 AI | 已核对的关键类型 |
| --- | --- | --- | --- |
| **Vision** | 图像理解：文字识别、文档结构、人体姿态、主体抠图 | ❌ | `RecognizeTextRequest`、`RecognizeDocumentsRequest`、`DetectHumanBodyPose3DRequest`、`GenerateForegroundInstanceMaskRequest` |
| **NaturalLanguage** | 分词、词性、命名实体、语言识别、词向量 | ❌ | `NLTagger`、`NLEmbedding` |
| **Speech** | 语音转写。iOS 26 新增 `SpeechAnalyzer` 流式栈 | ❌ | `SpeechAnalyzer`(actor)、`SpeechTranscriber`、`DictationTranscriber`、`AssetInventory` |
| **SoundAnalysis** | 声音事件分类（内置 300+ 类，可接自训模型） | ❌ | `SNClassifySoundRequest` |
| **Translation** | 设备端翻译，可批量、可查语言可用性 | ❌ | `TranslationSession`、`LanguageAvailability`、`TranslationSession.BatchResponse` |
| **FoundationModels** | 端侧 LLM（见路径 2） | ✅ | `SystemLanguageModel`、`LanguageModelSession` |
| **ImagePlayground** | 调起系统图像生成 | ✅ | `ImageCreator`、`ImagePlaygroundViewController`、`ImagePlaygroundStyle` |
| **AppIntents** | 把 App 能力暴露给 Siri / 快捷指令 / Spotlight | ❌（生成式联动才需要） | `AppIntent`、`AppEntity` |
| **CoreML** | 跑 `.mlpackage` 模型 | ❌ | `MLModel`、`MLModelConfiguration` |
| **CreateML** | ⚠️ iOS SDK 里也有此框架（端侧训练/微调），不是 macOS 那个 GUI App | ❌ | 框架存在（4108 行接口），具体能力**未细查** |
| **MetalPerformanceShadersGraph** | 手写算子图，Core ML 兜不住时的底层方案 | ❌ | `MPSGraph` |

**没有的东西**：iOS 26.2 上没有系统级的文本嵌入向量 API 用于语义检索
（`NLEmbedding` 是词向量，不是句向量），也没有开放的端侧图像理解 LLM
（Foundation Models 在 26.2 是**纯文本**，已通过 `Transcript.Segment` 只有 `.text`/`.structure` 确认）。

## 怎么选：决策顺序

Apple 在 Technology Overviews 里给的原则是明确的一句话：

> Minimize the time you spend adding intelligent features to your app by using existing
> system frameworks instead of developing custom models.
> —— [Machine learning and AI](https://developer.apple.com/documentation/technologyoverviews/machine-learning-and-ai)

按这个顺序自问，第一个「是」就停下：

1. **有现成系统框架吗？** OCR / 转写 / 翻译 / 分类这类需求，直接用框架。
   零成本、零包体、随系统升级免费变强 —— 不要用 LLM 去做 Vision 已经做好的事。
2. **是文本的理解或改写，且能容忍不可用降级吗？** 用 Foundation Models。
   注意它是**增强而非依赖**：必须写好 `.unavailable` 分支的降级路径。
3. **需要固定、可复现、可自己迭代的模型行为吗？** 用 Core ML / MLX。
   代价是模型转换、量化、内存与发热调优，工作量以周计。
4. **需要超出端侧能力的推理、长上下文、多模态？** 走云端 —— 并接受联网、延迟、
   费用和隐私合规四项成本。
5. **要让能力被系统调起？** 补 App Intents。这一步是叠加的，不替代前四步。

**关于路径 2 的一个重要判断**：由于「必须开 Apple Intelligence + 机型受限 + 中国大陆不可用」
三重约束叠加，Foundation Models 在可预见的产品里**只能当锦上添花的增强功能**，
不能作为核心链路的唯一实现。任何用到它的功能都要有非 AI 的兜底路径。

## 几个容易搞错的地方

- **Apple Intelligence ≠ 端侧 AI 的全部**。上表 11 个框架里只有 2 个需要 Apple Intelligence。
  Vision / Speech / Translation / Core ML 在任何支持的机型上都能跑，不受用户开关和地区限制。
  「机器学习能力受限」和「生成式能力受限」是两件事，不要混为一谈。
- **中国大陆是硬约束**。Apple Intelligence 在中国大陆的可用性受政策限制
  （⚠️ 具体状态未从官方文档确认，需在拍板前重新核实）。若目标市场含中国大陆，
  路径 2 和 Image Playground 直接从核心方案里划掉。已登记为 backlog 的 P1 前置问题。
- **官网文档现在是 iOS 27 的**。2026 年 6 月后 `developer.apple.com/documentation`
  展示 iOS 27 SDK，照抄示例在 26.2 上会编译失败（Foundation Models 已确认 8 处改名）。
  查 26.x API 请对着本机 `.swiftinterface`，方法见
  [foundation-models-overview.md](../01-on-device-llm/foundation-models-overview.md) 的「版本漂移」一节。
- **Apple 对第三方云 LLM 零指引**。路径 4 的所有架构结论（代理层、凭证下发、SSE 流式、
  降级路由）都**没有官方参考实现**，必须自己设计并自己承担合规责任。
  这一条决定了 [03-cloud-llm](../03-cloud-llm/) 的笔记性质与其他目录不同：那是设计文档，不是文档摘录。
- **`CreateML` 在 iOS SDK 里存在**，容易被误认为只有 macOS 才有。⚠️ 它在 iOS 上的实际
  能力边界（能训什么、需要多少数据与内存）**本次未核查**，已登记待办。

## 对本项目的含义

| 路径 | 当前可推进程度 | 卡在哪 |
| --- | --- | --- |
| 1 系统框架 | ✅ 完全可推进 | 无阻塞，模拟器足够验证大部分能力 |
| 2 端侧 LLM | 🚧 只能读文档 + 编译期验证 | 宿主 macOS 15.7.3 无 Apple Intelligence，且无真机 |
| 3 Core ML / MLX | 🟡 大部分可推进 | 性能/内存结论必须真机，模拟器数据没有参考价值 |
| 4 云端 LLM | ✅ 完全可推进 | 纯架构设计，不依赖设备 |
| 5 Agent 架构 | 🟡 部分可推进 | 协议设计可做；端侧 Tool Calling 实测受路径 2 阻塞 |

**建议的推进顺序**：4（云端架构）和 1（系统框架）优先 —— 这两条不受当前环境阻塞，
能产出立即可用的结论；路径 2 保持在文档 + 编译验证层面，等宿主 macOS 升级或拿到真机再实测。

## 参考来源

- [Machine learning and AI — Technology Overviews](https://developer.apple.com/documentation/technologyoverviews/machine-learning-and-ai) — Apple 官方的路径选择原则，本文决策顺序的依据
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels) — 路径 2 的框架文档（⚠️ 当前展示 iOS 27）
- [Vision](https://developer.apple.com/documentation/vision) / [Speech](https://developer.apple.com/documentation/speech) / [Translation](https://developer.apple.com/documentation/translation) / [SoundAnalysis](https://developer.apple.com/documentation/soundanalysis) — 路径 1 各框架文档
- [Core ML](https://developer.apple.com/documentation/coreml) — 路径 3 的主入口
- [App Intents](https://developer.apple.com/documentation/appintents) — 路径 5
- 本机 iOS 26.2 SDK `.swiftinterface` —— 框架与类型存在性的实证来源，方法见
  [foundation-models-overview.md](../01-on-device-llm/foundation-models-overview.md)
