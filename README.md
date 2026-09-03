# iOS AI Lab

iOS 平台 AI 能力项目。**整个工程由 AI 开发** —— 因此每一步都必须能被机器无人工干预地验证：
不点 Xcode、不弹签名对话框、不依赖真机。

当前阶段：**Phase 2 — iOS 底座**。已有可跑可测的 App 骨架、模型能力抽象层与 mock；
尚未接入任何真实模型。

## 跑起来

⚠️ **仓库里没有 `.xcodeproj`** —— 它是 xcodegen 的生成物，不入库（改工程请改 `project.yml`）。
所以 clone 之后**直接用 Xcode 打开这个文件夹会失败**，报
`Failed to open a document for ...，but no underlying error was returned`
（Xcode 找不到 `.xcodeproj` / `.xcworkspace` / 根级 `Package.swift` 时就是这个文案）。

先生成工程：

```bash
brew install xcodegen         # 没装过才要
xcodegen generate            # 产出 AILab.xcodeproj
open AILab.xcodeproj         # 之后 Cmd+R
```

只想跑测试、不开 Xcode：

```bash
./scripts/verify.sh          # 全量：逻辑测试 + 生成工程 + 构建 + 模拟器实跑（第一步就是 xcodegen generate）
./scripts/verify.sh logic    # 只跑逻辑测试（秒级）
```

环境要求：**Xcode 26.2 以上**（deployment target iOS 26.0、Swift 语言模式 6.0，更低版本构建不过）、
xcodegen 2.46.0 以上。

## 代码结构

| 位置 | 职责 |
| --- | --- |
| [`Packages/AICore`](Packages/AICore) | 模型能力抽象：`LanguageModelProvider` 协议、`ModelRouter` 路由、超时保护、mock |
| [`Packages/AIFeatures`](Packages/AIFeatures) | 业务逻辑与视图状态（`ChatStore`、装配点），不含 SwiftUI 视图 |
| [`App/`](App) | 薄 SwiftUI 外壳 |
| [`scripts/verify.sh`](scripts/verify.sh) | 唯一验证入口 |

逻辑刻意不放在 App target 里：包内 `swift test` 在宿主 macOS 上秒级返回，
而 iOS 模拟器构建是分钟级。这个差别决定了 AI 改-验循环的速度。

## 从哪里开始

| 想做什么 | 去哪里 |
| --- | --- |
| 了解 iOS 上 AI 能力的全貌 | [`docs/00-overview/ios-ai-landscape.md`](docs/00-overview/ios-ai-landscape.md) |
| 了解底座为什么长这样 | [`docs/decisions/001-...`](docs/decisions/001-ios-foundation-and-model-abstraction.md) |
| 查某个主题已有的调研结论 | [`docs/README.md`](docs/README.md) 索引 |
| 看还有哪些问题没答 | [`docs/backlog.md`](docs/backlog.md) |
| 写一篇新调研笔记 | 复制 [`docs/templates/调研笔记模板.md`](docs/templates/调研笔记模板.md) |
| 了解本机工具链版本与阻塞 | [`docs/00-overview/environment.md`](docs/00-overview/environment.md) |

## 五条能力主线

1. **端侧 LLM** — Apple Foundation Models，零成本、离线、隐私。🚫 本机完全跑不通（见环境基线）
2. **Core ML / MLX** — 自带模型上设备，模型转换、量化、性能基准
3. **云端 LLM** — 当前的主线：唯一能被机器端到端验证的路径
4. **多模态与系统能力** — Vision、Speech、Translation、Image Playground 等现成框架
5. **Agent 架构** — Tool Calling、App Intents、端云协同的任务编排

## 项目约定

见 [`CLAUDE.md`](CLAUDE.md)：架构不变量、验证要求、文档必须带来源链接与适用版本。
