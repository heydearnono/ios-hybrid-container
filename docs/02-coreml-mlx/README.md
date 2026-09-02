# 02 · Core ML / MLX（自带模型上设备）

**主线目标**：当系统内置模型不够用、又必须在端侧跑时，如何把自己的模型放到 iPhone 上并跑得动。

**核心矛盾**：iPhone 的内存上限与散热决定了能跑多大的模型，这是硬约束，不是优化问题。

## 范围

- Core ML：模型格式（`.mlpackage`）、编译、计算单元选择（CPU/GPU/Neural Engine）
- coremltools 转换链路：PyTorch → Core ML，量化与调色板压缩
- Transformer 类模型的特殊问题：KV cache、有状态模型、变长输入
- MLX / MLX Swift：跑开源权重模型，与 Core ML 的分工
- 性能基准方法：吞吐、首 token 延迟、峰值内存、能耗、热节流

## 待答问题

见 [`../backlog.md`](../backlog.md) 中 `02-CoreML-MLX` 分组。

## 笔记

| 文件 | 主题 | 状态 |
| --- | --- | --- |
| `coreml-basics.md` | Core ML 基础与转换链路 | 待建 |
| `mlx-on-ios.md` | MLX Swift 在 iOS 上的可行性 | 待建 |
| `benchmark-method.md` | 端侧推理基准测试方法 | 待建 |

## 注意

⚠️ 模型权重文件不进 git（见 `.gitignore`）。转换脚本进仓库，产物不进。
