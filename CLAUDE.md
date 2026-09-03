# iOS AI Lab

## 项目定位

面向 iOS 平台 AI 能力的学习与调研项目（AI Builder Lab），**整个项目由 AI 开发**。

「由 AI 开发」不是工作方式的描述，而是一条硬性工程约束：**每一步都必须能被机器无人工干预地验证**。
不点 Xcode、不弹签名对话框、不依赖真机。任何做不到这一点的方案（手工维护 pbxproj、
只能在 Xcode GUI 里跑的测试、必须真机才能验证的核心逻辑）都不采用。

## 阶段规划

| 阶段 | 状态 | 目标 | 产出物 |
| --- | --- | --- | --- |
| Phase 0 调研 | ✅ 主要结论已成型 | 建立 iOS AI 能力地图，明确每条路径的能力/成本/限制 | `docs/` 笔记 + `docs/decisions/` |
| Phase 1 最小验证 | ✅ 已建立方法 | 用单文件 `swiftc` + `simctl spawn` 验证 API 与运行时行为 | `spikes/` |
| Phase 2 iOS 底座 | **进行中** | 可跑可测的 App 骨架 + 模型能力抽象层 + mock | `project.yml` / `Packages/` / `App/` |
| Phase 3 接真实提供方 | **进行中** | 后端代理 + 云端提供方实现；端侧待环境解冻 | `Packages/AICore` 新增实现 |

Phase 3 当前进度：云端**传输层已实现并测试**（真 `URLSession` + 真 SSE，打本地 stub 服务器验证，
见 [`docs/03-cloud-llm/streaming-in-swift.md`](docs/03-cloud-llm/streaming-in-swift.md) 与 ADR 002）。
但**默认装配仍是 mock** —— 后端代理不存在，`baseURL` 无处可指。
断线重连已实现（语义是「失败即重发整个请求」，吐过内容后禁止重连）。
云端 tool calling 已实现（中立 `AgentTool` 抽象 + 下发/解析/回传/循环上限，流式按 `index` 拼接，
见 [`docs/05-agent-arch/tool-calling.md`](docs/05-agent-arch/tool-calling.md)）；
端侧工具适配器、流式里的工具事件、多轮会话、用量统计仍未做。

## 怎么验证

```bash
./scripts/verify.sh          # 全量：逻辑测试 + 生成工程 + 构建 + 模拟器实跑
./scripts/verify.sh logic    # 只跑包内逻辑测试（秒级，日常改代码用这个）
./scripts/verify.sh app      # 只做工程生成 + 构建 + 模拟器冒烟
```

**改完代码必须跑 `verify.sh`**，不要只靠肉眼判断。业务逻辑放 `Packages/`，
因为 `swift test` 在宿主 macOS 上跑，秒级返回；只有 UI 外壳需要走 iOS 模拟器构建。

## 目录结构

```
.
├── CLAUDE.md              # 本文件：项目约定
├── project.yml            # xcodegen 工程定义（改这个，不改 .xcodeproj）
├── scripts/verify.sh      # 唯一验证入口
├── Packages/
│   ├── AICore/            # 模型能力抽象层：Provider 协议、路由、超时、mock
│   └── AIFeatures/        # 业务逻辑与视图状态（不含 SwiftUI 视图）
├── App/                   # 薄 SwiftUI 外壳
├── docs/
│   ├── README.md          # 知识库索引（新增笔记必须更新这里）
│   ├── backlog.md         # 调研待办 + 待解答问题清单
│   ├── 00-overview/       # 能力地图、环境基线（全局视角）
│   ├── 01-on-device-llm/  # 端侧 LLM（Foundation Models）
│   ├── 02-coreml-mlx/     # Core ML / MLX 自带模型推理
│   ├── 03-cloud-llm/      # 云端大模型 + Swift 客户端架构
│   ├── 04-multimodal/     # Vision / Speech / 系统 AI 框架
│   ├── 05-agent-arch/     # Agent、Tool Calling、App Intents
│   ├── decisions/         # ADR：选型决策记录
│   └── templates/         # 笔记与对比模板
└── spikes/                # 最小验证代码
```

## 架构不变量

改代码时不要破坏这几条，它们都有测试覆盖：

1. **云端为主线，端侧做增强**。端侧受「机型 + Apple Intelligence 开关 + 地区」三重限制，
   不能作为唯一实现。
2. **`PrivacyRequirement.onDeviceOnly` 绝不降级到云端**。端侧不可用就如实失败。
   静默降级会把隐私承诺变成谎言。
3. **超时由抽象层强制施加**，不信任提供方。端侧模型不可用时 `respond()` 会挂死且不抛错，
   且不响应取消 —— 所以 `withTimeout` 用两个非结构化任务竞速，不能用 `withThrowingTaskGroup`。
4. **流式输出携带累积快照，不是增量**。UI 赋值而非 append。
5. **`.xcodeproj` 是生成物**，不入库。工程结构改 `project.yml`。

## 工作约定

**文档**
- 一个主题一个文件，结论写在开头，过程和证据写在后面。
- 新建调研笔记一律基于 `docs/templates/调研笔记模板.md`；技术路线对比用 `技术选型对比模板.md`。
- **每条非显然的事实必须带来源链接**。无法从官方文档确认的，显式标注 `⚠️ 未验证`，不要含糊过去。
- **所有 API 结论必须注明适用的 OS / Xcode / SDK 版本**，这个领域半年就会过时。
- 笔记头部 `更新时间` 用绝对日期（`2026-09-01`），不要写「上周」「最近」。
- 选型拍板写进 `docs/decisions/`，文件名 `NNN-<短标题>.md`，包含背景 / 选项 / 决策 / 代价。

**代码**
- 业务逻辑放 `Packages/`，UI 放 `App/`。**逻辑不要写进 App target** —— 那样就只能靠模拟器构建来验证，反馈从秒级退化到分钟级。
- 新增 Swift 文件不需要改工程文件（`sources: App` 按目录纳入；包内按 SPM 约定）。新增 target 才改 `project.yml`。
- 一次性验证代码放 `spikes/<主题>-<序号>/`，允许粗糙，但必须在对应调研笔记里反向链接。
- 文档正文用中文，代码标识符、文件名、目录名用英文。

## 环境基线（2026-09-01 实测）

- macOS 15.7.3（Darwin 24.6.0），Apple Silicon
- Xcode 26.2（Build 17C52）、Swift 6.2.3
- 模拟器运行时仅 iOS 26.2；可用机型含 iPhone 17 Pro / iPhone Air / iPad Pro 13-inch (M5)
- **已安装**：xcodegen 2.46.0
- **未安装**：tuist、swiftformat、swiftlint（需要时再装，不预装）
- 🚫 **Apple Intelligence 在本机完全不可用**：宿主 macOS 15.7.3 没有 Apple Intelligence，
  而 iOS 模拟器复用宿主的模型资源 → 端侧 LLM 连模拟器都跑不通（已实测）。
  端侧路径在「宿主升级到 macOS 26」或「拿到真机」之前只能对着 mock 开发。

详见 `docs/00-overview/environment.md`。

## 常用命令

```bash
./scripts/verify.sh                     # 验证入口（最常用）
xcodegen generate                       # 改完 project.yml 后重新生成工程
xcrun simctl list devices available     # 可用模拟器
xcrun simctl list runtimes              # 已装运行时
```

## 给 AI 助手的提示

1. 回答 API 问题前**先看 `docs/` 是否已有结论**，避免重复调研；已有结论但过时，就更新它而不是新建文件。
2. 涉及 iOS 26 新框架（Foundation Models、SpeechAnalyzer 等）**不要凭记忆作答**——查官方文档，
   然后**对着本机 `.swiftinterface` 核对**（官网文档已切到 iOS 27，存在改名），最后把结论回写进笔记。
3. 每次新增或重写笔记，同步更新 `docs/README.md` 索引和 `docs/backlog.md` 的问题状态。
4. 改完代码跑 `./scripts/verify.sh`，不要只靠肉眼判断。测试失败就如实报告，不要含糊过去。
5. 端侧模型相关的代码**无法在本机验证**。写这类代码时明确说明哪部分是编译期验证过的、
   哪部分要等硬件 —— 不要把未验证的实现说成能用。
