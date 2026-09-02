# 环境基线

- **更新时间**：2026-09-01
- **采集方式**：本机命令行实测

重新采集：

```bash
sw_vers
xcodebuild -version
swift --version
xcrun simctl list runtimes
xcrun simctl list devices available
```

## 系统与工具链

| 项目 | 版本 |
| --- | --- |
| macOS | 15.7.3（Darwin 24.6.0） |
| 架构 | Apple Silicon（arm64） |
| Xcode | 26.2（Build 17C52） |
| Swift | 6.2.3（swiftlang-6.2.3.3.21，clang-1700.6.3.2） |
| Git | 2.50.1 |
| Node | 24.6.0 |
| Python | 3.9.6（系统自带） |
| uv | 0.11.8 |

## 模拟器

运行时：**iOS 26.2（23C54）** — 仅此一个。

可用机型：iPhone 17 Pro、iPhone 17 Pro Max、iPhone Air、iPhone 17、iPhone 16e、
iPad Pro 13-inch (M5)、iPad Pro 11-inch (M5)、iPad mini (A17 Pro)、iPad (A16)、
iPad Air 13-inch (M3)、iPad Air 11-inch (M3)。

## 未安装的相关工具

按需再装，不预装：

| 工具 | 用途 | 安装 |
| --- | --- | --- |
| xcodegen | 用 YAML 生成 .xcodeproj，避免工程文件冲突 | `brew install xcodegen` |
| tuist | 更重的工程生成与模块化方案 | `brew install tuist` |
| swiftformat | 代码格式化 | `brew install swiftformat` |
| swiftlint | 静态检查 | `brew install swiftlint` |
| coremltools | PyTorch/TF → Core ML 模型转换（Python） | `uv pip install coremltools` |

## 影响调研的环境约束

- **Python 3.9 偏旧**：`coremltools` 等 ML 工具链通常要求更高版本。做模型转换前用
  `uv venv --python 3.12` 单独建虚拟环境，不要动系统 Python。
- **只有 iOS 26.2 运行时**：无法在本机做跨版本行为对比（比如 iOS 26.0 与 26.2 的 API 差异）。
  需要时通过 Xcode 下载历史运行时。
- **🚫 Apple Intelligence 在本机模拟器上不可用（2026-09-01 实测）**：
  iOS 26.2 模拟器（iPhone 17 Pro）上 `SystemLanguageModel.default.availability`
  返回 `.unavailable(.modelNotReady)`。原因是 iOS 模拟器**复用宿主 Mac 的模型资源**，
  而本机是 **macOS 15.7.3（Sequoia），没有 Apple Intelligence**。
  → **要实测端侧 LLM，只有两条路：宿主升级到 macOS 26（Tahoe）并开启 Apple Intelligence，或者用真机。**
  验证代码见 [`spikes/foundation-models-01/`](../../spikes/foundation-models-01/)，
  结论详见 [`01-on-device-llm/foundation-models-overview.md`](../01-on-device-llm/foundation-models-overview.md)。
- **纯 API 形状验证这条路是通的**：不需要模型资源，`swiftc -typecheck` 对着 iOS 26.2 SDK 就能验证，
  且本机 SDK 的 `.swiftinterface` 是 26.2 API 的权威来源（官网文档已切到 iOS 27，存在改名差异）。
- **真机情况待补充**：目前没有登记可用的测试真机与其 OS 版本，这会限制端侧 LLM 主线的推进。
