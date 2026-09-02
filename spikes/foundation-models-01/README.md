# spike: foundation-models-01

- **日期**：2026-09-01
- **环境**：macOS 15.7.3 / Xcode 26.2（17C52）/ Swift 6.2.3 / iOS 26.2 模拟器（iPhone 17 Pro）
- **对应笔记**：[`docs/01-on-device-llm/foundation-models-overview.md`](../../docs/01-on-device-llm/foundation-models-overview.md)

## 要验证的问题

1. iOS 26.2 SDK 里 Foundation Models 的 API 形状到底是什么？文档上的写法能不能编译过？
2. Apple Intelligence 能力在**本机 iOS 26.2 模拟器**上能不能跑通？
3. 模型不可用时，直接调 `respond()` 会发生什么？

## 怎么跑

`api-typecheck.swift` —— 只做类型检查，不需要模拟器：

```bash
xcrun swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios26.2-simulator -swift-version 6 \
  api-typecheck.swift
```

`availability-probe.swift` —— 编成 iOS 可执行文件塞进模拟器跑（不需要建 Xcode 工程）：

```bash
xcrun swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios26.2-simulator -swift-version 6 \
  availability-probe.swift -o fmprobe

DEV=$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro (' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
xcrun simctl boot "$DEV"; xcrun simctl bootstatus "$DEV" -b
xcrun simctl spawn "$DEV" "$PWD/fmprobe"
xcrun simctl shutdown "$DEV"
```

注意日志写的是 **stderr**：`stdout` 走管道时是块缓冲，进程被 kill 掉就什么都看不到（第一次跑就踩了这个坑）。

## 结论

1. **API 形状全部验证通过**，`-typecheck` 退出码 0。含可用性判定、`@Generable` / `@Guide`、
   `Tool` 协议、流式 `Snapshot`、`GenerationError` 九个 case、`DynamicGenerationSchema` 运行时建 schema、
   `useCase` / `guardrails` / `adapter` 三种模型变体。
2. **模拟器跑不起来**：`availability == .unavailable(.modelNotReady)`、`isAvailable == false`。
   宿主 Mac 是 macOS 15.7.3，没有 Apple Intelligence，模拟器拿不到模型资源。
3. **不判可用性直接 `respond()` 会挂死**：两次实测（300s / 90s）都没有返回，也**没有抛错**。
   这是最需要防的坑——必须先查 `availability` 再发请求。
4. 附带收获：`supportedLanguages` 和 `supportsLocale(_:)` 在模型不可用时**依然能查**，
   返回 23 个语言标识（含 `zh` / `zh-HK` / `zh-TW`），`supportsLocale(zh_CN) == true`。

完整数值见笔记的「实测数据」一节。
