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
| 📌 [coreml-vs-mlx.md](coreml-vs-mlx.md) | Core ML vs MLX Swift 选型、PyTorch→Core ML 转换链路与压缩实测、三道墙（内存 / 分发体积 / 热节流） | ✅ 2026-09-03 |
| `benchmark-method.md` | 端侧推理基准测试方法 | 待建（需真机才有意义） |

原计划的 `coreml-basics.md` 与 `mlx-on-ios.md` 并入 `coreml-vs-mlx.md` ——
两者的核心结论是「选哪条路」，拆成两篇会让对比散掉。

## 本机环境的硬约束

⚠️ 本目录的**性能类结论一律无法在本机验证**，原因已实测（见笔记）：

- 模拟器**没有 ANE**（`MLComputeDevice.allComputeDevices` 实测 2 个，宿主 3 个）——
  而 ANE 正是 Core ML 相对 MLX 的唯一结构性优势；
- 模拟器**测不出内存上限**（`os_proc_available_memory()` 返回 0，`physicalMemory` 报的是宿主 16 GiB），
  也不发内存警告、不做 OOM 终止；
- **MLX Swift 在模拟器上根本跑不起来**（官方明确：需要 modern `MTLGPUFamily`），
  且 ≥ 0.31.5 要求 Swift 6.3 工具链，Xcode 26.2 连依赖都解析不了。

能在本机钉死的只有两件事：**API 形状**（`-typecheck`）与**权重体积**（coremltools 实跑）。

## 注意

⚠️ 模型权重文件不进 git（见 `.gitignore`）。转换脚本进仓库，产物不进。
