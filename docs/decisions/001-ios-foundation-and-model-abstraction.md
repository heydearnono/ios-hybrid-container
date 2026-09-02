# 001 · iOS 底座形态与模型能力抽象

- **日期**：2026-09-02
- **状态**：已采纳
- **相关调研**：[`00-overview/ios-ai-landscape.md`](../00-overview/ios-ai-landscape.md)、
  [`01-on-device-llm/foundation-models-overview.md`](../01-on-device-llm/foundation-models-overview.md)、
  [`00-overview/environment.md`](../00-overview/environment.md)

## 背景

项目要求**整个工程由 AI 开发**。这不是工作方式偏好，而是一条会推翻很多常规做法的工程约束：
凡是需要人在 Xcode 里点一下、需要处理签名弹窗、需要插真机才能验证的环节，AI 都做不了。

同时 Phase 0 调研得出两个硬约束：

- 端侧 LLM（Foundation Models）受「机型 + Apple Intelligence 开关 + 地区」三重限制；
- **本机环境下端侧模型一行都跑不起来** —— 宿主 macOS 15.7.3 没有 Apple Intelligence，
  而 iOS 模拟器复用宿主的模型资源，实测 `.unavailable(.modelNotReady)`。

所以底座必须在「核心能力无法实机验证」的前提下，仍然让全链路逻辑可被机器验证。

## 考虑过的选项

**工程形态**

1. **传统 `.xcodeproj` 入库** — 最接近常规 iOS 项目习惯。放弃：AI 增删文件要手改数千行、
   满是 UUID 交叉引用的 `project.pbxproj`，损坏概率高且冲突难解，与「AI 开发」目标直接冲突。
2. **纯 xcodegen，代码全在 app target** — 结构简单。放弃：每次跑测试都要走完整 iOS 模拟器
   构建，反馈从秒级退化到分钟级；逻辑与 UI 耦合也不利于写单测。
3. **SPM 模块 + xcodegen 生成薄壳** — 采纳。

**模型主线**

1. **端侧为主，云端兜底** — 隐私和成本更优。放弃：当前环境下 AI 完全无法验证端侧代码，
   且中国大陆与老机型不可用，不能作为唯一实现。
2. **两条对等，由路由决定** — 设计最干净但工作量最大，且端侧那一半始终无法验证。放弃。
3. **云端为主，端侧做增强** — 采纳。

## 决策

1. 业务逻辑全部放 Swift Package（`Packages/AICore`、`Packages/AIFeatures`），
   `App/` 只留薄 SwiftUI 外壳；`.xcodeproj` 由 `project.yml` 经 xcodegen 生成，**不入库**。
2. 模型能力收敛到 `LanguageModelProvider` 协议，由 `ModelRouter` 做「云端为主、端侧增强」的路由。
3. 第一版交付**骨架 + 抽象层 + mock**，不接真实模型。
4. 唯一验证入口是 `./scripts/verify.sh`：包内 `swift test` + `xcodebuild build` +
   模拟器 install/launch 冒烟。

## 理由

- `swift test` 在宿主 macOS 上跑，21 个测试 0.7 秒返回；iOS 模拟器构建要分钟级。
  把逻辑放包里，AI 的改-验循环快两个数量级。
- 抽象层让「端侧不可用」从阻塞变成一种**可测状态**：mock 复刻实测的
  `.unavailable(.modelNotReady)`，于是降级路径和隐私拒绝路径现在就能被真实触发，
  不用等硬件。
- 模拟器构建关掉签名（`CODE_SIGNING_ALLOWED: NO`），全流程无人工交互。
- 云端是当前唯一能被机器端到端验证的路径，与全景地图的结论一致。

## 代价与风险

- **端侧提供方尚无任何实现**，只有接口形状。真实接入时可能发现协议需要调整
  （例如 Tool Calling 的参数模型差异比预期大）。
- **`withTimeout` 超时后会泄漏一个任务**。因为上游可能不响应取消，这是有意接受的取舍：
  泄漏一个任务好过 UI 永久卡死。若将来发现泄漏累积，需要改为进程级熔断。
- **流式统一到累积快照**，意味着云端 SSE 适配层要自己累加，且无法向调用方暴露「纯增量」语义。
- **`xcodebuild test` 目前不跑任何测试**（测试都在包里）。App target 的 UI 行为没有自动化覆盖，
  只有「能启动且 10 秒内不崩」这一条冒烟。
- 依赖 xcodegen 这个第三方工具；它若停止维护需要迁移到 Tuist 或手写工程。
- **真机验证是 AI 做不到的唯一环节**，必须由人完成。

## 什么情况下应该重新评估

- 宿主升级到 macOS 26 或拿到真机 —— 端侧变得可验证，第 2 条的「主线/增强」划分要重新权衡。
- 确认目标市场不含中国大陆、且最低机型在 iPhone 15 Pro 以上 —— 端侧可以升格为主线候选。
- 端侧上下文窗口显著超过 4096 token —— 会改变端云分工的边界。
- App target 出现足量 UI 逻辑 —— 届时需要补 UI 测试 target，`verify.sh` 相应扩展。
