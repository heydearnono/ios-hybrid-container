# Core ML 与 MLX Swift：iOS 端侧自带模型推理选型

- **更新时间**：2026-09-03
- **适用版本**：iOS 26.2 SDK（CoreML user-module-version 3505.4.1）/ Xcode 26.2 (17C52) / Swift 6.2.3 / coremltools 9.0 / PyTorch 2.14.0 / mlx-swift 0.31.4 与 0.31.6
- **验证方式**：官方文档 + 本机 iOS 26.2 SDK `.swiftinterface` 与 ObjC 头文件逐条核对 + **本笔记的 Core ML 代码骨架在本机 `swiftc -target arm64-apple-ios26.2-simulator -swift-version 6 -typecheck` 零错误通过** + iOS 26.2 模拟器实跑探针（compute device / 内存 API）+ 本机 coremltools 9.0 实际转换与压缩（8 项转换 + 8 种压缩配置）+ mlx-swift 实际依赖解析与构建尝试。**无真机，因此全部性能数字（延迟、吞吐、峰值内存、热节流）均为「未实测」**
- **相关 spike**：[`spikes/coreml-mlx-01/`](../../spikes/coreml-mlx-01/) —— 本次的验证脚本已从 `/tmp` 收进仓库，
  `./run.sh` 一条命令重跑类型检查 + 宿主探针 + 模拟器探针（模型产物只落 `mktemp`，不入库）；
  转换与压缩探针要另装 PyTorch，见该目录 README

## 一句话结论

**要交付就用 Core ML，要跑开源 LLM 权重就用 MLX Swift —— 但在本机这台设备上，只有 Core ML 这条路能部分验证。**
Core ML 是唯一能碰到 ANE 的路径，转换链路（PyTorch → `.mlpackage`）在本机完整跑通了；
MLX Swift 在本机被**双重阻塞**：官方明确说 iOS 模拟器跑不了（Metal `MTLGPUFamily` 不够），
且 0.31.5 起要求 Swift 6.3 工具链，Xcode 26.2 连依赖都解析不了。
最大的坑不是性能而是**验证不了**：模拟器没有 ANE（实测 compute device 只有 2 个而宿主 3 个）、
不发内存警告、报的是宿主 Mac 的 16 GiB 内存 —— 一切「能跑多大模型」的结论必须等真机。

## 能做什么

### Core ML（iOS 26.2 SDK 实际存在的能力）

| 能力 | API | 起始版本 |
| --- | --- | --- |
| 加载/推理 | `MLModel`、`MLModelConfiguration` | iOS 11.0 |
| 选择计算单元 | `MLComputeUnits`：`.cpuOnly` / `.cpuAndGPU` / `.all` / `.cpuAndNeuralEngine` | `.cpuAndNeuralEngine` 起 iOS 16.0 |
| 枚举可用设备 | `MLComputeDevice.allComputeDevices`、`MLModel.availableComputeDevices` | iOS 17.0 |
| 指定设备 | `MLModelConfiguration.preferredMetalDevice`（仅 GPU） | iOS 11.0 |
| 离线查看算子落在哪个后端 | `MLComputePlan`（`DeviceUsage {supported, preferred}`、`Cost.weight: Double` ∈ [0.0, 1.0]）、`MLModelStructure` | iOS 17.4 |
| 张量式推理，免手搓 `MLMultiArray` | `MLTensor`、`MLModel.prediction(from: [String: MLTensor])` | iOS 18.0 |
| KV cache 等可变状态 | `MLState`、`MLModel.makeState()`（**Swift 侧不是 `newState()`**）、`prediction(from:using:)` | iOS 18.0 |
| 一个包多个函数（prefill / extend 共享权重） | `MLModelAsset.modelAssetWithURL:`、`MLModelConfiguration.functionName` | iOS 18.0 |
| 加载/编译策略提示 | `MLOptimizationHints.reshapeFrequency`（iOS 17.4）、`.specializationStrategy`（`.fastPrediction`，iOS 18.0） | iOS 17.4 / 18.0 |
| Int8 数组元素 | `MLMultiArrayDataType.int8`、`Int8: MLShapedArrayScalar` | **iOS 26.0** |

iOS 26 在 Core ML Swift 层的增量非常小：对着本机 `.swiftinterface` 比对，只有 `Int8`
的 `MLMultiArray`/`MLShapedArray` 支持，以及 `MLTensor.pointwiseMin`/`pointwiseMax` 的标量重载。
**不要期待 iOS 26 给 Core ML 带来新的模型能力** —— 2026 年的新东西都在另一个框架（见边界一节的 Core AI）。

### coremltools 9.0（转换与压缩）

- 前端：`torch.jit.trace` 出的 TorchScript（**本机实测可用**）、`torch.export` 出的
  `ExportedProgram`（**必须先 `.run_decompositions({})`**，实测原始 `TRAINING` dialect 直接报错）、
  TensorFlow 2 / Keras、已有 `.mlmodel`。
- 后端：`convert_to="mlprogram"`（默认，`.mlpackage`）与旧 `neuralnetwork`。新项目一律 mlprogram。
- 部署目标：`ct.target.iOS13` … `ct.target.iOS18`、`ct.target.iOS26`（**实测 spec version = 10，
  这是 coremltools 9.0 的天花板，没有 iOS 27**）。
- 灵活形状：`ct.RangeDim`（**必须给有限 upper_bound**）、`ct.EnumeratedShapes`。
- 有状态模型：`ct.StateType(wrapped_type=ct.TensorType(...), name=...)`，Python 侧
  `model.make_state()` 可直接验证跨次调用的状态累积（**本机实测两次调用得到 1.0 → 2.0**）。
- 训练后压缩 `coremltools.optimize.coreml`：`linear_quantize_weights`（int8/int4，
  per-tensor / per-channel / per-block）、`palettize_weights`（1–8 bit，kmeans，
  per-tensor / per-grouped-channel）、`prune_weights`（magnitude / 阈值），可联合使用。
- 需要标定或 QAT 时走 `coremltools.optimize.torch`，在 PyTorch 侧插桩后再转换。

### MLX Swift（0.31.4）

- `MLXArray` + 惰性求值的数组库，`MLXNN` 提供层，`MLXOptimizers`、`MLXRandom`、`MLXFFT`、`MLXLinalg`。
- 量化：`QuantizedLinear`、`quantized(...)`，`QuantizationMode` 含 `.affine`、`.mxfp4`、`.mxfp8`、`.nvfp4`。
- 内存治理是**公开一等 API**：`MLX.Memory.cacheLimit` / `.memoryLimit` / `.snapshot()` /
  `.clearCache()` / `.withWiredLimit`。官方 iOS 指南直接给出 `MLX.Memory.cacheLimit = 20 * 1024 * 1024`。
- 上层 `mlx-swift-examples` / `mlx-swift-lm` 提供 `MLXLLM`、`MLXVLM`、`MLXLMCommon`、`MLXEmbedders`，
  可直接吃 Hugging Face 上的 MLX 格式权重 —— 这是它对 Core ML 的核心优势：**不需要转换**。
- 支持训练/微调（有梯度），Core ML 在 iOS 上没有对等能力。

## 不能做什么 / 边界

### 1. 本机环境：三条阻塞，都实测过

**模拟器没有 ANE。** iOS 26.2 模拟器（iPhone 17 Pro）里 `MLComputeDevice.allComputeDevices`
实测返回 **2** 个：`Apple iOS simulator GPU` 和 CPU。同一份代码在宿主 macOS 上返回 **3** 个，
含 `neuralEngine: totalCoreCount = 16` 和 `gpu: Apple M4`。
所以模拟器能验证「模型加载得起来、输出对不对」，**不能验证任何与 ANE 相关的结论** ——
而 ANE 恰恰是 Core ML 相对 MLX 的唯一结构性优势。

**模拟器无法验证内存。** 探针实测 `os_proc_available_memory()` 返回 **0**
（Apple 文档说明非 App bundle 的进程返回 0），`ProcessInfo.processInfo.physicalMemory` 返回
**17179869184** —— 那是宿主 Mac 的 16 GiB，不是手机。Apple 另有明确说明：模拟器基于 macOS，
**不发内存警告、不做 OOM 终止**。结论：模型规模上限在模拟器里测不出来，只能靠算术推演 + 真机确认。

**MLX Swift 在本机完全跑不了。** 两个独立原因：
- 官方文档原文：*"It isn't possible to use the iOS simulator for developing MLX applications,
  since MLX requires a modern Metal `MTLGPUFamily` and the simulator does not provide that."*
  症状是运行时断言 `failed assertion 'Dispatch Threads with Non-Uniform Threadgroup Size is not
  supported on this device'`。官方给的两条绕路都需要真实 GPU：`Mac (Designed for iPad)` 目标，
  或做 multiplatform App。模拟器只能开发 UI，**求值不了任何 `MLXArray`**。
- 版本墙（本机实测）：`swift package resolve` 指向 mlx-swift `0.31.6` 直接失败 ——
  `'mlx-swift' >= 0.31.5 contains incompatible tools version (6.3.0)`。Xcode 26.2 / Swift 6.2.3
  解析不了 tools-version 6.3。只有钉死 `exact: "0.31.4"`（tools 5.12）才能解析成功。
- 附带一条：mlx-swift 需要编译 `.metal`，而 **Xcode 26.2 默认不带 Metal Toolchain**。
  实测 `xcodebuild -showComponent MetalToolchain -json` 返回 `"status":"uninstalled"`，
  构建在 `scaled_dot_product_attention.metal` / `rms_norm.metal` 上报
  `cannot execute tool 'metal' due to missing Metal Toolchain`。需要额外下载约 704.6 MB。
  ⚠️ 未验证：下载被我中止（网速约 150 KB/s），因此**「mlx-swift 0.31.4 能否为 iOS 模拟器成功构建」这一点没有验证**，
  只验证到它在缺 Metal Toolchain 时必然失败。

### 2. Core ML 自身的硬边界

- **计算单元只能「建议」，不能强制。** `MLComputeUnits` 是偏好；实际算子分派由运行时决定，
  单个算子可能落回 CPU。只能用 `MLComputePlan` 离线查看，**运行时没有 API 告诉你某次推理真的跑在哪**。
- **`MLComputePlan.Cost.weight` 不是毫秒**。官方定义是「该算子在整个模型执行中的估计工作量占比，
  取值 `[0.0, 1.0]`」（*"The estimated workload of executing the operation over the total model
  execution. The value is between [0.0, 1.0]."*）。它只能告诉你哪个算子贵，给不出绝对延迟。
- **float32 的 mlprogram 拿不到 ANE**，必须 `compute_precision=ct.precision.FLOAT16`（默认即是）。
- **`RangeDim` 不允许无上界**。本机实测报错原文：`For mlprogram, inputs with infinite
  upper_bound is not allowed. Please set upper_bound to a positive value`。
  也就是说变长序列必须自己定一个最大长度，超了就得重新编译或换 function。
- **灵活形状代价高**：`EnumeratedShapes` 每个形状都要单独特化，形状多则加载慢、包变大；
  `RangeDim` 通常比枚举形状更容易被踢出 ANE。⚠️ 未验证：「RangeDim 掉出 ANE」这条在本机无法测（模拟器无 ANE）。
- **iOS 27 是断层。** coremltools 9.0 没有 `ct.target.iOS27`。2026 年 Apple 的新推理栈是另一套
  **Core AI** 框架（`.aimodel`、`coreai-torch` / `coreai-opt`、`xcrun coreai-build`），
  需要 Xcode 27。本机 Xcode 26.2 完全接不上。⚠️ 未验证：Core AI 的能力边界与它和 Core ML 的共存方式
  本机无法验证，只能等升级；不要把它写进任何交付计划。
- **KV cache 需要自己搭。** `MLState` 提供的是「运行时保留一块可变 buffer」，
  形状在转换时就固定了。滑窗、驱逐、多序列 batch 都要自己在图里表达。
- **自定义算子是最后手段。** 优先 composite operator（用已有 MIL 算子拼）；真写 custom operator
  就要在 App 里提供 Swift/Metal 实现，**且该算子永远拿不到 ANE**。
- **`.mlmodelc` 才是设备上真正跑的东西**，`.mlpackage` 需要编译。本机实测
  `xcrun coremlcompiler compile` 在 M4 上编译 48 MiB 模型耗时 0.43 s，产物同为 48.0 MiB。
  ⚠️ 未验证：设备上首次加载的编译/特化耗时未实测（需真机），这通常是首启动延迟的主要来源。
- ⚠️ 未验证：把预编译好的 `.mlmodelc` 直接放进 App bundle 或下载后加载，是否在审核与长期兼容上安全
  （`.mlmodelc` 是编译产物，跨 OS 版本的兼容性 Apple 未承诺）。

### 3. MLX Swift 自身的硬边界

- **没有 ANE。** MLX 是 Metal/GPU + 统一内存路线，不使用 Neural Engine。功耗与并发抢占上劣于 ANE。
- **没有 Apple 官方文档承诺**。它是 `ml-explore` 下的研究导向项目，API 会变
  （`GPU.set(cacheLimit:)` 已被 `MLX.Memory.cacheLimit` 取代），也没有 Apple 平台级兼容承诺。
- **权重体积就是内存占用**，没有 ANE 那种权重按需分页的优化路径。
- ⚠️ 未验证：MLX 实际能跑起来的最老 iPhone 机型。官方只说需要「modern `MTLGPUFamily`」，
  没给机型清单。

### 4. 模型规模与量化的实用上限（这是本节最重要的部分）

先把**可测的部分**测掉。本机 coremltools 9.0 实测，25.2M 参数（6×2048×2048 Linear）：

| 配置 | `.mlpackage` 体积 | 相对 fp32 |
| --- | --- | --- |
| fp32（参考值，未落盘） | 96 MiB | 1.00× |
| fp16（`compute_precision=FLOAT16`） | **48.0 MiB** | 0.50× |
| int8 per-channel | **24.1 MiB** | 0.25× |
| int4 per-block(32) | **13.5 MiB** | 0.14× |
| palettize 6-bit, group 16 | **18.1 MiB** | 0.19× |
| palettize 4-bit, group 16 | **12.1 MiB** | 0.13× |
| palettize 3-bit, group 16 | **9.1 MiB** | 0.09× |
| palettize 2-bit, group 16 | **6.0 MiB** | 0.06× |
| magnitude prune 50% | **27.0 MiB** | 0.28× |

三条可以直接用的推论：
- **权重体积几乎线性可预测**：`参数量 × 每权重比特数 / 8`，加一点 scale/LUT 开销。
  4-bit 就是「参数量的一半 MiB」—— 7B 模型 4-bit ≈ 3.5 GiB，这个数字是纯算术，不需要真机。
- **剪枝不是压缩手段**：50% 稀疏只从 48 MiB 降到 27 MiB（稀疏表示要存 bitmask），
  远不如直接 4-bit。剪枝要和量化联合用才有意义。
- **小权重不会被压**：`OpLinearQuantizerConfig.weight_threshold` 本机实测默认 **2048**，
  元素数少于阈值的权重原样保留。所以「压缩后体积没到理论值」通常不是 bug。

**真正的墙是内存，而内存上限 Apple 不公布。**
- iOS 用 **jetsam** 按进程的 dirty memory 上限杀进程，Apple 从不公开每机型的具体字节数。
  唯一的程序化查询是 `os_proc_available_memory()`（返回距离该进程上限的剩余量），
  **它在模拟器/非 bundle 进程里返回 0**，所以本机测不到任何真数。
- 想突破默认上限要申请 `com.apple.developer.kernel.increased-memory-limit`
  （配合 `extended-virtual-addressing`），**Apple 同样不公布它能放宽到多少字节**，
  且只在部分机型生效。
- ⚠️ 未验证：任何具体的「iPhone 某机型单 App 可用 X GB」数字。网上流传的比例（如物理内存的
  50%～60%）无官方来源，本项目**不采用**。这条必须真机 `os_proc_available_memory()` 实测关闭。

**第二道墙是分发体积**，这条有官方数字：App Store 上 iOS build 的**未压缩体积上限 4 GB**，
**单个可执行文件 500 MB**（口径是二进制里所有 `__TEXT` section 之和）。
所以 GiB 级权重**不能打进 App**，必须走 **Background Assets** ——
Apple 那张体积上限表自己就把超限场景指向了它。
⚠️ 未验证：Background Assets 由 Apple 托管的资产包具体上限（每包 / 每 App 总量）未能从官方页面取到原文，
不要引用任何未经核对的 GB 数字。
另外 On-Demand Resources 不要再选：`NSBundleResourceRequest` 已在 **iOS 27.0 标记弃用**，
官方弃用说明就是一句 "Use Background Assets instead."

**第三道墙是热节流**，只能 `ProcessInfo.thermalState` 观测，⚠️ 未验证 —— 模拟器恒为
`.nominal`（实测 rawValue = 0），持续解码下的降频行为必须真机长跑。

综合上面三道墙，**结论只能给到「体积算得准、内存与速度算不准」这个程度**：
4-bit 下 1B 级 ≈ 0.5 GiB 权重、3B 级 ≈ 1.5 GiB、7B 级 ≈ 3.5 GiB，再加 KV cache 与激活。
哪一档在目标机型上不被 jetsam 杀掉，**本项目当前无法回答**。

### 5. 转换链路的边界（含一个静默出错的坑）

- **`torch.jit.trace` 会静默烧死数据相关分支。** 本机实测：一个 `if x.sum() > 0` 的模块，
  用全 1 输入 trace，然后喂全 -1 —— PyTorch 给 `[-101, -101, -101, -101]`，
  Core ML 给 `[-2, -2, -2, -2]`。**转换成功、不报错、结果错**。这是最危险的失败模式，
  必须靠数值对齐测试兜住，不能靠转换器报错。
- `torch.jit.trace` 在 torch 2.14 已 deprecated（实测 `FutureWarning`），官方推荐 `torch.export`；
  但 `torch.export` 的原始产物是 `TRAINING` dialect，coremltools 拒绝，
  必须 `.run_decompositions({})` 后再转（本机实测 2a 失败 / 2b 成功）。
- **算子缺失会硬报错**（这反而是好事）。实测 `torch.linalg.matrix_exp` →
  `NotImplementedError: PyTorch convert function for op 'linalg_matrix_exp' not implemented.`
- **coremltools 9.0 未测试 torch 2.14**。实测警告原文：*"Torch version 2.14.0 has not been tested
  with coremltools... Torch 2.7.0 is the most recent version that has been tested."*
  生产转换应钉在被测过的 torch 版本上。
- **输入名不会自动跟你的想法一致**：不显式给 `ct.TensorType(name=...)`，实测会拿到
  `x_1` 之类的自动名，`predict` 时报 `KeyError`。转换脚本里永远显式命名输入输出。
- ⚠️ 未验证：`EnumeratedShapes` 的形状数量上限、以及多输入同时用枚举形状的行为
  （文档提到从 iOS 18 起才支持多输入枚举形状）。本机只验证了单输入两形状可用。

## 关键 API

### Core ML 推理（iOS 18.0+ 写法；下面这段在本机 `xcrun swiftc -target arm64-apple-ios26.2-simulator -swift-version 6 -typecheck` **零错误通过**）

```swift
import CoreML

// 1) 看清这台设备有什么 —— 模拟器上实测只有 GPU + CPU，没有 .neuralEngine
for device in MLComputeDevice.allComputeDevices {
    switch device {
    case .cpu(let cpu):            print("cpu", cpu)
    case .gpu(let gpu):            print("gpu", gpu)
    case .neuralEngine(let ne):    print("ANE cores:", ne.totalCoreCount)
    @unknown default:              break
    }
}

// 2) 配置：计算单元 + 加载策略提示
// 注意 Swift 侧 MLOptimizationHints 是 struct（ObjC 是 class + MLReshapeFrequencyHint 全局枚举，
// 头文件标了 NS_REFINED_FOR_SWIFT），嵌套枚举名是 .ReshapeFrequency / .SpecializationStrategy
let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine          // 只是偏好，不是强制
config.optimizationHints.reshapeFrequency = .infrequent      // iOS 17.4+
config.optimizationHints.specializationStrategy = .fastPrediction  // iOS 18.0+，另一个 case 是 .default

// 3) 多函数模型：prefill / extend 共享同一份权重（iOS 18.0+）
let asset = try MLModelAsset(url: modelURL)        // 传的是已编译的 .mlmodelc
config.functionName = "extend"
let model = try await MLModel.load(asset: asset, configuration: config)

// 4) MLTensor + MLState 做带 KV cache 的推理（iOS 18.0+）
let state = model.makeState()          // 注意：不是 newState()，见「踩坑记录」
let inputs: [String: MLTensor] = [
    "tokens": MLTensor(shape: [1, 1], scalars: [Int32(tokenID)], scalarType: Int32.self)
]
let outputs = try await model.prediction(from: inputs, using: state)

// 5) 上线前离线确认算子落在哪个后端（iOS 17.4+）
let plan = try await MLComputePlan.load(contentsOf: compiledModelURL, configuration: config)
if case .program(let program) = plan.modelStructure,
   let main = program.functions["main"] {
    for op in main.block.operations {
        let usage = plan.deviceUsage(for: op)     // .supported / .preferred
        let cost  = plan.estimatedCost(of: op)    // cost?.weight 是占总执行量的比例 [0.0, 1.0]，不是毫秒
        print(op.operatorName, usage?.preferred as Any, cost?.weight as Any)
    }
}
```

### PyTorch → Core ML 标准流程（coremltools 9.0，本机实跑通过）

```python
import numpy as np, torch, coremltools as ct

model = MyModule().eval()                     # 必须 eval()
example = torch.rand(1, 64)

# 前端 A：TorchScript（成熟，但会烧死数据相关分支）
traced = torch.jit.trace(model, example)

# 前端 B：torch.export（未来方向，必须先 run_decompositions）
# ep = torch.export.export(model, (example,)).run_decompositions({})

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="x", shape=(1, 64), dtype=np.float16)],   # 永远显式命名
    outputs=[ct.TensorType(name="logits", dtype=np.float16)],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS18,   # 9.0 上限是 ct.target.iOS26
    compute_precision=ct.precision.FLOAT16,      # float32 拿不到 ANE
)

# 数值对齐 —— 这一步不能省，它是唯一能抓住「trace 烧死分支」的手段
ref = model(example).detach().numpy()
got = list(mlmodel.predict({"x": example.numpy()}).values())[0]
assert np.allclose(ref, got, atol=1e-2), np.abs(ref - got).max()

mlmodel.save("Model.mlpackage")
```

带状态（KV cache 雏形）与压缩：

```python
# 有状态模型：states= 声明的 buffer 在推理间保留
ml = ct.convert(
    torch.jit.trace(acc_module, torch.ones(4)),
    inputs=[ct.TensorType(name="x", shape=(4,))],
    outputs=[ct.TensorType(name="y")],
    states=[ct.StateType(wrapped_type=ct.TensorType(shape=(4,)), name="acc")],
    minimum_deployment_target=ct.target.iOS18,
)
st = ml.make_state()
ml.predict({"x": np.ones(4, np.float32)}, state=st)   # 实测 1.0 → 再调一次 2.0

# 训练后压缩
import coremltools.optimize.coreml as cto
cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
    mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32))
small = cto.linear_quantize_weights(ml, cfg)         # 实测 48.0 → 13.5 MiB

cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
    nbits=4, mode="kmeans", granularity="per_grouped_channel", group_size=16))
small = cto.palettize_weights(ml, cfg)               # 实测 48.0 → 12.1 MiB
```

编译成设备上真正加载的产物：

```bash
xcrun coremlcompiler compile Model.mlpackage ./out    # 产出 out/Model.mlmodelc
```

### MLX Swift（0.31.4；本机只能验证到依赖解析，无法运行）

```swift
// Package.swift —— 0.31.5+ 需要 Swift 6.3 工具链，Xcode 26.2 解析失败，必须钉死
.package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4")
```

```swift
import MLX

MLX.Memory.cacheLimit = 20 * 1024 * 1024   // 官方 iOS 指南给的值，防 jetsam
let before = Memory.snapshot()
let y = (a.matmul(b) + c)                  // 惰性
y.eval()                                   // 模拟器上这一步会触发 Metal 断言
print(before.delta(Memory.snapshot()).description)
```

## 实测数据

| 指标 | 环境 | 数值 | 备注 |
| --- | --- | --- | --- |
| `MLComputeDevice.allComputeDevices` 数量 | iOS 26.2 模拟器 / iPhone 17 Pro | **2** | GPU（`Apple iOS simulator GPU`）+ CPU，**无 ANE** |
| 同上 | 宿主 macOS 15.7.3 / M4 | **3** | 含 `neuralEngine: totalCoreCount = 16`、`gpu: Apple M4` |
| `os_proc_available_memory()` | iOS 26.2 模拟器 | **0** | 非 App bundle 进程返回 0；模拟器无内存约束 |
| `ProcessInfo.physicalMemory` | iOS 26.2 模拟器 | **17179869184** | 宿主 Mac 的 16 GiB，不是手机内存 |
| `ProcessInfo.thermalState` | iOS 26.2 模拟器 | **0（nominal）** | 模拟器测不出热节流 |
| `ct.target.iOS26` spec version | coremltools 9.0 | **10** | 9.0 无 iOS27 target |
| 权重体积（25.2M 参数，8 种压缩） | coremltools 9.0 / 宿主 | 见「模型规模与量化」表 | fp16 48.0 → 4-bit 12.1 MiB |
| `.mlpackage` → `.mlmodelc` 编译 | 宿主 M4，48 MiB 模型 | **0.43 s**，产物 48.0 MiB | **宿主数字，不能当设备首启动耗时** |
| mlx-swift 0.31.6 依赖解析 | Swift 6.2.3 | **失败** | `incompatible tools version (6.3.0)` |
| mlx-swift 0.31.4 依赖解析 | Swift 6.2.3 | **成功** | tools 5.12 |
| mlx-swift iOS 模拟器构建 | Xcode 26.2 | **失败（缺 Metal Toolchain）** | `-showComponent MetalToolchain` → `uninstalled`，需约 704.6 MB |
| 本笔记 Core ML 代码骨架 `-typecheck` | iOS 26.2 模拟器 SDK / Swift 6 | **0 错误** | 只证明 API 名与签名对，**没证明运行时行为**（无模型文件、无 ANE） |
| 首 token 延迟 / 吞吐 / 峰值内存 / 热节流（Core ML） | — | **未实测** | 需真机 |
| 首 token 延迟 / 吞吐 / 峰值内存 / 热节流（MLX） | — | **未实测** | 需真机，且模拟器根本跑不了 |
| iPhone 单 App 可用内存上限 | — | **未实测** | 需真机，且 Apple 不公布 |

### 唯一可引用的 LLM 量级数字：Apple 自己的，且是 Mac 不是 iPhone

Apple 官方文章《On Device Llama 3.1 with Core ML》给了 Llama-3.1-8B 的完整优化阶梯。
**必须记住它的环境是 M1 Max Mac / macOS 15.2 Beta / GPU，文章里没有任何 iPhone 数字**，
不能挪用来预测手机表现。摘录（TTFT = 首 token 延迟，Extend = 解码吞吐，context 2048）：

| 配置 | TTFT | 解码吞吐 |
| --- | --- | --- |
| Float16 基线（无 KV cache，静态形状） | 5374.15 ms | 0.19 tok/s |
| KV cache 走模型输入/输出 | 933.89 ms | 1.25 tok/s |
| **KV cache 用 Core ML state（`MLState`）** | 128.32 ms | 16.26 tok/s |
| 上一行 + block-wise int4 权重 | **51.91 ms** | **33.67 tok/s** |

两条可以直接迁移的结论（与设备无关，是架构结论）：
- **KV cache 必须用 `MLState`，不能走输入输出**。同一个模型，两者差 13 倍吞吐、7 倍 TTFT。
- **int4 block-wise 在这条链路上又翻了一倍吞吐**，因为 LLM 解码是内存带宽瓶颈；
  模型体积 16 GB → 4.2 GB，与上面「参数量的一半 MiB」的算术吻合（8B × 0.5 ≈ 4 GiB）。

## 踩坑记录

- **`model.newState()` 编译不过**：Swift 报 `'newState()' is unavailable in iOS`。
  原因是 `newState()` 在 iOS 26.2 SDK 的 `.swiftinterface` 里对**所有平台**都标了
  `@available(..., unavailable)` —— 它只是 ObjC 名字的残留，Swift 的正确名字是 **`makeState()`**
  （`@available(iOS 18.0, ...)`）。这就是「不要凭记忆写 API 名」的活样本：
  同一个能力在 ObjC 和 Swift 下名字不同，只有 `-typecheck` 能抓出来。
- **转换成功但结果错**：`torch.jit.trace` 对 `if x.sum() > 0` 只记录 trace 时走过的那条分支
  → 转换器不报错，换输入就错（实测 torch `-101` vs Core ML `-2`）→ 每个转换都配数值对齐断言，
  控制流用 `torch.export` 或改写成无分支形式。
- **`predict` 报 `KeyError: 'Provided key "x_1" ... does not match'`**：没显式命名输入
  → coremltools 自动生成了 `x_1` → `ct.TensorType(name="x", ...)` 显式命名。
- **`torch.export` 直接转报 `Provided Dialect: TRAINING`**：`ExportedProgram` 默认不是 ATEN/EDGE
  dialect → 先 `.run_decompositions({})`。
- **`RangeDim(1, -1)` 报「infinite upper_bound is not allowed」**：mlprogram 不接受无上界
  → 必须给出具体最大长度。
- **`xcodebuild -scheme probe` 报 scheme 不存在**：SwiftPM 生成的 scheme 名是
  `<Package>-Package` → 先 `xcodebuild -list`。
- **构建 mlx-swift 报 `cannot execute tool 'metal'`**：Xcode 26 把 Metal Toolchain 拆成独立组件
  → `xcodebuild -downloadComponent MetalToolchain`（约 704.6 MB）。
- **`uv pip install` 报 `Charles Proxy CA ... certificate is not trusted`**：本机有 Charles 中间人
  代理，curl 信任但 uv 的 SecTrust 路径不信任 → `security find-certificate -a -c "Charles Proxy" -p`
  导出后与 certifi 的 bundle 合并，`SSL_CERT_FILE=/tmp/combined.pem uv pip install ...`。
- **coremltools 文档站是旧版本构建的**：apple.github.io 上那份是 8.1 时代内容，
  版本敏感的结论要去 GitHub 上 `main` 分支的 `docs-guides/source/*.md` 核对，或者直接在本机
  Python 里 introspect（`weight_threshold` 默认值就是这么发现文档与实际不一致的：实测 2048）。

## 结论与下一步

- **选型倾向：Core ML 主用，MLX Swift 待定（不排除，但当前不可验证）。**
  - 用 Core ML 的场景：中小模型、需要 ANE 的低功耗常驻推理（视觉、音频、embedding、
    分类/检测/分割）、要和 Vision/Speech 等系统框架拼装、要进 App Store 的正式交付。
  - 用 MLX Swift 的场景：直接吃开源 LLM/VLM 权重（不想维护转换脚本）、需要端侧训练/微调、
    快速试模型。代价是没有 ANE、没有 Apple 兼容承诺、且**当前环境完全无法验证**。
  - 与 `docs/00-overview/ios-ai-landscape.md` 的判断一致：这条路径的性能/内存结论必须真机，
    模拟器数据没有参考价值。本笔记把「能在宿主上算清的部分」（转换链路、权重体积）钉死了，
    剩下的都明确标为未实测。
- 待验证问题（需登记到 `docs/backlog.md`，本次不改该文件）：
  1. 真机上 `os_proc_available_memory()` 的实际数值，以及超限时 jetsam 的具体行为。
  2. `increased-memory-limit` entitlement 实际放宽到多少，哪些机型生效。
  3. 4-bit 量化下 1B / 3B / 7B 三档在目标机型上的可行性（首 token 延迟、tok/s、峰值内存）。
  4. mlx-swift 0.31.4 能否为 iOS 模拟器构建成功（需先装 Metal Toolchain）；以及 MLX 支持的最老机型。
  5. 真机上 `.mlmodelc` 首次加载/特化耗时，及 `.specializationStrategy = .fastPrediction` 的实际收益。
  6. Core AI（iOS 27 / Xcode 27）与 Core ML 的关系与迁移代价 —— 需要升级工具链才能碰。
  7. `MLModelAsset` + `functionName` 做 LLM prefill/extend 双函数共享权重的实际可行性与收益。

## 参考来源

- [MLComputeDevice](https://developer.apple.com/documentation/coreml/mlcomputedevice) — 确认 iOS 17.0 起可枚举计算设备，以及三个 case 的形状
- [MLComputePlan](https://developer.apple.com/documentation/coreml/mlcomputeplan-1w21n) 与 [MLComputePlanCost.weight](https://developer.apple.com/documentation/coreml/mlcomputeplancost/weight) — 确认 iOS 17.4 起可用，且 `weight` 是 [0.0, 1.0] 的工作量占比而非毫秒
- [MLState](https://developer.apple.com/documentation/coreml/mlstate) — 确认有状态模型是 iOS 18.0 起
- [MLModelConfiguration.functionName](https://developer.apple.com/documentation/coreml/mlmodelconfiguration/functionname) — 确认多函数模型入口（iOS 18.0）
- [MLOptimizationHints](https://developer.apple.com/documentation/coreml/mloptimizationhints-swift.struct) — 确认 reshapeFrequency（17.4）与 specializationStrategy（18.0）的版本差
- [MLTensor](https://developer.apple.com/documentation/coreml/mltensor) — 确认 iOS 18.0 起可用张量接口代替 `MLMultiArray`
- 本机 `iPhoneOS26.2.sdk/.../CoreML.swiftmodule/arm64e-apple-ios.swiftinterface` — 唯一可信的 iOS 26.2 API 真相来源；确认 iOS 26 的 Core ML 增量仅 `Int8` 支持
- [coremltools 文档指南](https://apple.github.io/coremltools/docs-guides/) — 转换流程、灵活输入、压缩、有状态模型、composite/custom operator 的官方说明（注意站点由 8.1 构建，版本敏感处以 GitHub `main` 或本机 introspect 为准）
- [apple/coremltools](https://github.com/apple/coremltools) — 版本敏感结论的核对源
- [ml-explore/mlx-swift · running-on-ios.md](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Documentation.docc/Articles/running-on-ios.md) — 决定性来源：明确 iOS 模拟器跑不了 MLX、给出 `MLX.Memory.cacheLimit` 与两条绕路方案
- [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) — 版本与 tools-version 核对
- [Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports) — 确认 iOS 按 dirty memory 上限杀进程，且不公开具体数值
- [os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory) — 确认它是唯一的程序化内存余量查询，且在非 App 场景返回 0
- [com.apple.developer.kernel.increased-memory-limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit) — 确认存在放宽上限的 entitlement，但未公布放宽幅度
- [Maximum build file sizes](https://developer.apple.com/help/app-store-connect/reference/maximum-build-file-sizes) — 核对到 iOS 9.0+ 的 4 GB 未压缩体积 / 500 MB 可执行文件（`__TEXT` 之和）上限，决定 GiB 级权重必须走下载
- [Background Assets](https://developer.apple.com/documentation/backgroundassets) — 大权重的官方分发路径（具体容量上限未取到原文）
- [NSBundleResourceRequest](https://developer.apple.com/documentation/foundation/nsbundleresourcerequest) — 核对到 On-Demand Resources 在 iOS 27.0 弃用，官方指向 Background Assets
- [On Device Llama 3.1 with Core ML](https://machinelearning.apple.com/research/core-ml-on-device-llama) — 唯一可引用的 Core ML LLM 阶梯数字（`MLState` 相对输入输出式 KV cache 差 13 倍吞吐；int4 再翻倍）；同时确认全部数字来自 M1 Max Mac，文中无任何 iPhone 结果
