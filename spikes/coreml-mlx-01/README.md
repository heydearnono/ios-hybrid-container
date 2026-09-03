# spike: coreml-mlx-01

**要验证的问题**

1. 笔记里那段 Core ML（`MLModelAsset` + `functionName` + `MLState` + `MLComputePlan`）的写法在
   iOS 26.2 SDK 上**到底编不编得过** —— 尤其 `newState()` 还是 `makeState()`。
2. iOS 26.2 模拟器里能不能验证 ANE 与内存约束。
3. PyTorch → Core ML 转换链路上有哪些会**静默出错**、哪些会硬报错。
4. 训练后压缩各配置的实际权重体积。
5. mlx-swift 能不能在本机（Xcode 26.2 / Swift 6.2.3）为 iOS 用起来。

**怎么跑**

```bash
./run.sh              # 类型检查 + 宿主探针 + 模拟器探针（本机已跑通，秒级）
./run.sh typecheck    # 只做类型检查，不需要模拟器
./run.sh convert      # 额外跑 coremltools 转换/压缩探针，需要 python 环境（见下）
```

`convert` 那档需要 `coremltools` + `torch`，本项目不预装（不进 `verify.sh`，因为它要装几个 GB 的
PyTorch）。当时的装法：

```bash
uv venv /tmp/ctenv && uv pip install --python /tmp/ctenv/bin/python coremltools torch
PY=/tmp/ctenv/bin/python ./run.sh convert
```

⚠️ 本机有 Charles 中间人代理，`uv` 的 SecTrust 路径不信任它的根证书。绕法：
`security find-certificate -a -c "Charles Proxy" -p` 导出后与 certifi 的 bundle 合并，
再 `SSL_CERT_FILE=/tmp/combined.pem uv pip install ...`。

模型产物（`.mlpackage` / `.mlmodelc`）只落在 `mktemp` 目录里，跑完删掉，**不入库**。

**文件**

| 文件 | 作用 |
| --- | --- |
| `apicheck.swift` | 笔记「关键 API」那段代码的可编译版本。只 `-typecheck`，不运行（本机没有模型文件、没有 ANE） |
| `probe.swift` | 模拟器探针：`allComputeDevices` / `os_proc_available_memory()` / `physicalMemory` / `thermalState` |
| `hostprobe.swift` | 宿主 macOS 同样的探针，作为对照组 |
| `convert_probe.py` | 8 项转换探针：trace / `torch.export` / 数据相关分支 / 缺失算子 / `RangeDim` / `EnumeratedShapes` / `StateType` / `ct.target.iOS26` |
| `compress_probe.py` | 25.2M 参数模型 × 8 种压缩配置的体积，外加 `coremlcompiler` 编译耗时 |
| `mlx-Package.swift` | 复现 mlx-swift 的版本墙用的最小 `Package.swift`（钉 `exact: "0.31.4"`） |

**结论**（完整版见 [`../../docs/02-coreml-mlx/coreml-vs-mlx.md`](../../docs/02-coreml-mlx/coreml-vs-mlx.md)）

- `apicheck.swift` **0 错误通过**，但过程中抓到：`model.newState()` 在 iOS 26.2 SDK 里对所有平台都标了
  `unavailable`，Swift 的正确名字是 **`makeState()`**。这一条只有类型检查能抓出来。
- 模拟器 **2 个** compute device（GPU + CPU，**无 ANE**），宿主 **3 个**（含 `neuralEngine: 16 核`）；
  `os_proc_available_memory()` 返回 **0**；`physicalMemory` 返回宿主的 16 GiB；`thermalState` 恒为 0。
  → **模型规模与 ANE 相关的结论在本机测不出来**，必须真机。
- 最危险的失败模式：`torch.jit.trace` 静默烧死数据相关分支 —— 转换成功、不报错、结果错
  （torch `-101` vs Core ML `-2`）。缺失算子反而会硬报错。
- 权重体积几乎线性可预测：fp16 48.0 MiB → int4 per-block(32) 13.5 → palettize 4-bit 12.1 MiB；
  50% 剪枝只到 27.0 MiB，**不如直接量化**。
- mlx-swift ≥ 0.31.5 要求 tools-version 6.3，Xcode 26.2 解析不了；钉 0.31.4 能解析，但构建需要
  Metal Toolchain（约 704.6 MB，未装）。⚠️ 因此「0.31.4 能否为 iOS 模拟器构建成功」这条**没有验证**。

**重跑时间**：`./run.sh` 约 20 秒（含模拟器启动）；`./run.sh convert` 数分钟，另需先装 PyTorch。
