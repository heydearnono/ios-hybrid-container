# 04 · 多模态与系统 AI 框架

**主线目标**：盘清 Apple 已经提供的现成 AI 框架。很多需求不需要 LLM，用系统框架又快又省。

**判断原则**：先问「系统有没有现成框架」，再问「要不要上模型」。顺序反了会做很多无用功。

## 范围

- **Vision** — 图像理解、文字识别、人体/手势、图像分割
- **Speech** — 语音识别与转写
- **Natural Language** — 分词、词性、实体、语义相似度
- **Translation** — 系统翻译能力
- **Sound Analysis** — 声音事件分类
- **Image Playground / Genmoji** — 系统图像生成入口
- **Writing Tools** — 文本改写能力的系统集成
- **Create ML** — 轻量自定义模型训练

## 待答问题

见 [`../backlog.md`](../backlog.md) 中 `04-多模态` 分组。

## 笔记

| 文件 | 主题 | 状态 |
| --- | --- | --- |
| [`../00-overview/ios-ai-landscape.md`](../00-overview/ios-ai-landscape.md) | 系统 AI 框架清单与选择指南（已核对本机 SDK 存在性） | ✅ 写在全景地图里 |
| `speech-transcription.md` | `SpeechAnalyzer` 转写栈实测（可在模拟器推进） | 待建 |
| `vision-ocr.md` | Vision 文字与文档识别 | 待建 |

> 框架清单原计划落在本目录的 `framework-inventory.md`，实际写作时发现它同时是全局选路的依据，
> 因此并入 [`ios-ai-landscape.md`](../00-overview/ios-ai-landscape.md)，本目录只放单个框架的深入笔记。
