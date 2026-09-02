# 01 · 端侧 LLM（Foundation Models）

**主线目标**：搞清楚 iOS 系统内置的端侧大模型能做什么、边界在哪，判断它能不能承担实际功能。

**为什么优先**：零调用成本、离线可用、数据不出端、无需自己管理模型文件。如果它够用，就是首选。

## 范围

- Apple Foundation Models 框架：会话、流式输出、结构化输出、Tool Calling
- 可用性判定与降级策略（不支持的机型/未开启 Apple Intelligence 时怎么办）
- 上下文长度、限流、语言支持等硬限制
- 适配器（LoRA）定制的可行性与代价

## 待答问题

见 [`../backlog.md`](../backlog.md) 中 `01-端侧LLM` 分组。

## 笔记

| 文件 | 主题 | 状态 |
| --- | --- | --- |
| [foundation-models-overview.md](foundation-models-overview.md) | 框架总览与 API 全貌、硬限制、版本漂移 | ✅ |

## 相关 spike

| 目录 | 验证内容 |
| --- | --- |
| [`spikes/foundation-models-01/`](../../spikes/foundation-models-01/) | API 形状类型检查；模拟器可用性探针 |

## 当前阻塞

**宿主 macOS 15.7.3 上跑不通**：iOS 模拟器复用宿主 Mac 的模型资源，本机 Mac 没有 Apple Intelligence，
`availability` 恒为 `.unavailable(.modelNotReady)`。要推进实测得升级宿主 macOS 到 26，或者上真机。
详见笔记的「踩坑记录」。

## 状态

⬜ 未开始 · 🟡 进行中 · ✅ 有可用结论
