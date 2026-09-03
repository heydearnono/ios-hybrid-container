# spikes

一次性验证代码。

spike 的唯一目的是回答一个具体问题（「这个 API 到底能不能这么用」「这个模型在 iPhone 上多快」），
回答完就完成使命。不追求代码质量，追求最快拿到结论。

## 现有 spike

| 目录 | 回答的问题 | 对应笔记 |
| --- | --- | --- |
| [`foundation-models-01/`](foundation-models-01/) | Foundation Models 的 API 形状与硬限制；本机能不能跑 | [`01-on-device-llm/foundation-models-overview.md`](../docs/01-on-device-llm/foundation-models-overview.md) |
| [`text-embedding-01/`](text-embedding-01/) | iOS 有没有能用的中文句向量 API | [`04-multimodal/text-embedding.md`](../docs/04-multimodal/text-embedding.md) |
| [`app-intents-01/`](app-intents-01/) | App Intents 能否直接当 Agent 工具层 | [`05-agent-arch/app-intents-as-tools.md`](../docs/05-agent-arch/app-intents-as-tools.md) |
| [`coreml-mlx-01/`](coreml-mlx-01/) | Core ML API 形状、模拟器能验证什么、转换链路的坑、压缩体积、MLX 能不能用 | [`02-coreml-mlx/coreml-vs-mlx.md`](../docs/02-coreml-mlx/coreml-vs-mlx.md) |

## 约定

- 一个 spike 一个目录：`spikes/<主题>-<序号>/`，例如 `spikes/foundation-models-01/`
- 每个 spike 目录里放一个 `README.md`，写清：**要验证的问题**、**怎么跑**、**结论**
- spike 拿到的结论必须回写到 `docs/` 对应笔记的「实测数据」一节，并在笔记里链接 spike 目录
- 结论回写后 spike 可以留着当参考，但不要在上面继续加功能——那是 Phase 2 的事
- 模型权重、大文件不进 git（见 `.gitignore`）

## 跑法优先级

能用更轻的方式验证就别建工程：

1. `swift` 单文件脚本 / Swift Package `executableTarget` —— 验证纯逻辑、网络、SDK 调用
2. Swift Playground —— 验证 API 形状
3. 最小 SwiftUI 工程 —— 只有涉及 UI、权限、真机能力（端侧 LLM、相机、麦克风）时才建
