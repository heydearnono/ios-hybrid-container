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
| [README](02-coreml-mlx/README.md) | 主线范围与目标 | ✅ |

## 03 · 云端 LLM

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| [README](03-cloud-llm/README.md) | 主线范围与目标 | ✅ |

## 04 · 多模态与系统 AI 框架

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| [README](04-multimodal/README.md) | 主线范围与目标 | ✅ |

## 05 · Agent 架构

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| [README](05-agent-arch/README.md) | 主线范围与目标 | ✅ |

## 决策与流程

| 文件 | 内容 |
| --- | --- |
| [backlog.md](backlog.md) | 调研待办与待答问题清单 |
| [decisions/001-...](decisions/001-ios-foundation-and-model-abstraction.md) | **ADR 001**：iOS 底座形态与模型能力抽象（SPM + xcodegen；云端为主，端侧增强） |
| [decisions/](decisions/) | 技术选型决策记录（ADR）索引 |
| [templates/调研笔记模板.md](templates/调研笔记模板.md) | 新建笔记用 |
| [templates/技术选型对比模板.md](templates/技术选型对比模板.md) | 做方案对比用 |
