# 上手踩坑清单

- **更新时间**：2026-09-04
- **适用版本**：Xcode 26.2（Build 17C52）/ Swift 6.2.3 / iOS 26.2 SDK
- **采集方式**：本机命令行实测；另有一台 Xcode 16.3 的机器提供了真实报错样本

新人第一次跑这个基座，卡住的原因**几乎都不是代码问题**，而是三件事：
仓库不含 `.xcodeproj`、工程要求 Xcode 26.2 以上、模拟器运行时要单独下载。
下面每条都给出报错原文、真正的成因、修法，以及一条能自证修好了的命令。

## 先跑这段自检

```bash
sw_vers -productVersion                  # 需 >= 15.6（Xcode 26.2 的最低系统要求）
uname -m                                 # arm64 / x86_64，决定下哪个 Xcode 安装包
xcodebuild -version                      # 需 Xcode 26.2 以上
xcodegen --version                       # 需 2.46.0 以上
xcrun simctl list runtimes | grep -i ios  # 必须有 iOS 26.0 以上的运行时
```

五项都满足，直接 `./scripts/verify.sh`，退出码 0 就算通了。
缺哪一项，对应下面同名小节。

## 速查表

| 报错原文关键片段 | 真正的原因 | 小节 |
| --- | --- | --- |
| `Failed to open a document ...，but no underlying error was returned` | 仓库里没有 `.xcodeproj`，它是生成物 | [1](#1-用-xcode-打开文件夹失败) |
| `package 'aicore' is using Swift tools version 6.2.0 but the installed version is 6.1.0` | Xcode 太老 | [2](#2-swift-tools-版本不匹配) |
| `No supported iOS devices are available` + `A build only device cannot be used to run this target` | 可运行目标列表为空 | [3](#3-没有可用的运行目标) |
| `Xcode doesn't support My Mac's macOS ...` | 选了 My Mac（Designed for iPad）这个目标 | [4](#4-选错成-my-mac) |
| 真机上装不上 / 卡在签名 | 签名是**刻意**关掉的 | [5](#5-真机跑不起来) |
| 回答内容是假的、固定的 | 默认装配就是 mock | [6](#6-回答不是真实模型给的) |

## 1. 用 Xcode 打开文件夹失败

**症状**：clone 之后 `open .` 或在 Xcode 里选这个目录，报
`Failed to open a document for ...，but no underlying error was returned`。
文案没说清缺什么，容易以为仓库坏了。

**原因**：`.xcodeproj` 是 xcodegen 的生成物，按约定不入库（见 `.gitignore` 与
[ADR 001](../decisions/001-ios-foundation-and-model-abstraction.md)）。Xcode 在目录里找不到
`.xcodeproj` / `.xcworkspace` / 根级 `Package.swift`，就吐这句。

**修法**：在**仓库根目录**（`project.yml` 所在那层）生成工程。

```bash
brew install xcodegen        # 没装过才要
xcodegen generate            # 产出 AILab.xcodeproj
open AILab.xcodeproj
```

`xcodegen generate` 默认读**当前目录**下的 `project.yml`（`--spec` 的默认值就是它），
输出目录取 spec 所在目录，所以必须在根目录跑。从别处跑要显式指定：
`xcodegen generate --spec /path/to/ios/project.yml`。

`./scripts/verify.sh` 不受此限制 —— 它在 `scripts/verify.sh:13-14` 自己算出仓库根并 `cd` 过去，
从任何子目录调用都行，且第一步就是 `xcodegen generate`。

**自证**：`ls AILab.xcodeproj` 存在。

## 2. Swift tools 版本不匹配

**症状**：
`package 'aicore' is using Swift tools version 6.2.0 but the installed version is 6.1.0`

**原因**：两个包的清单都声明 `// swift-tools-version: 6.2`，需要 Swift 6.2 工具链，
即 **Xcode 26.x**。报出 6.1.0 的是老 Xcode（⚠️ 未验证：6.1.0 精确对应 Xcode 16.3，
16.4 是 6.1.2 —— 版本映射来自记忆，未对官方矩阵核对，但结论「16.x 一律不行」是确定的）。

**修法**：升级到 Xcode 26.2 以上。**不需要升 macOS 26** —— 见第 7 节。

**注意这条错和第 3 节的错通常一起出现，且是同一个根因**，
但属于两个独立的失败点：这条是「代码根本编不了」，第 3 节是「选不了设备」。

**自证**：

```bash
xcodebuild -version                                              # Xcode 26.2 以上
xcodebuild -project AILab.xcodeproj -scheme AILab -resolvePackageDependencies
# 正常应输出 resolved source packages: AIFeatures, AICore
```

## 3. 没有可用的运行目标

**症状**：点运行报
`No supported iOS devices are available. Connect a device to run your application or choose a
simulated device as the destination.`，伴随
`A build only device cannot be used to run this target.`

**原因**：Xcode 为这个 scheme 算出的合格目标是**空的**，只剩 `Any iOS Device` 这个
build-only 占位项。三种成因，可能同时成立：

**(a) Xcode 太老。** 工程的 deployment target 是 iOS 26.0（`project.yml:12-13`），
Xcode 会把低于它的模拟器全部过滤掉。Xcode 16.x 带的是 iOS 18.x SDK 与运行时
（⚠️ 未验证的细节：16.3 对应 18.4、16.4 对应 18.5；确定的是 18.x < 26.0，全部不合格），
所以那台机器上装再多模拟器也一个都不合格。老 Xcode 也**用不了**新下载的 iOS 26.2 运行时 ——
运行时需要对应 Xcode 的 SDK 支持，不被支持就不会列进目标。

**(b) 没装 iOS 运行时。** 这是升级完 Xcode 后最容易再撞一次的坑，报错一模一样，
看起来像「升级没生效」。**iOS 模拟器运行时不随 Xcode 打包**，是单独下载的组件 ——
本机 `xcrun simctl runtime list` 显示它是一个独立的 Disk Image（7.8 G 压缩、挂载后 16 G），
放在 `/Library/Developer/CoreSimulator/`，不在 `Xcode.app` 里面。
装完 Xcode 要进 **Xcode → Settings（Cmd+,）→ Components** 下载 **iOS 26.2 Simulator**。

**(c) 目标停在了一台离线真机上。** Xcode 记住上次选的设备，设备一断开就退化成 build-only 目标。
本机 `xcrun devicectl list devices` 就有一台配对过但状态 `unavailable` 的 iPhone。
修法：工具栏 scheme 名右边的目标下拉菜单 → iOS Simulators 分组里选一台，例如 `iPhone 17 Pro`。

**自证**：这条命令打印的就是 Xcode 认可的目标列表，不用开 Xcode 猜。

```bash
xcodebuild -project AILab.xcodeproj -scheme AILab -showdestinations
```

本机健康输出是 11 条 `OS:26.2` 的模拟器（iPhone 17 Pro / iPhone Air / iPad Pro 13-inch (M5) 等）。
如果只吐出 `Any iOS Device` 占位项、后面跟着一片 `Ineligible destinations`，就是上面三种成因之一。

## 4. 选错成 My Mac

**症状**：目标选 `My Mac (Designed for iPad)`，报
`Xcode doesn't support My Mac's macOS 15.7.3 (24G419)`（本机 `-showdestinations` 实测到这条
`Ineligible destinations`）。

**原因**：「Designed for iPad」要求宿主 macOS 能支撑对应 iOS SDK 的运行环境，
macOS 15.x 撑不起 iOS 26 的 Mac Catalyst/iPad 兼容运行。

**修法**：这个目标在本项目里没用，选 iOS 模拟器就行。不必尝试修它。

## 5. 真机跑不起来

**原因**：签名是**刻意关掉的**，`project.yml:47-50`：

```yaml
# 模拟器构建不需要签名。这样 CI 与 AI 都不会撞上需要人工处理的签名交互。
CODE_SIGNING_ALLOWED: NO
CODE_SIGNING_REQUIRED: NO
CODE_SIGN_IDENTITY: ""
```

这直接来自项目的硬约束「每一步都必须能被机器无人工干预地验证」：真机路径会拉起签名交互，
一有人工对话框，AI 与 CI 的闭环就断了。

**所以真机不是「配一下就能跑」，而是当前不支持的路径。** 真要上真机：恢复签名设置、配好
Development Team、设备系统 ≥ iOS 26.0，并且明白这条路上的验证不再是无人工的。

## 6. 回答不是真实模型给的

**症状**：App 能跑，聊天能出字，但内容固定、明显是假的。

**原因**：**默认装配就是 mock**，这是当前阶段的既定状态，不是 bug。云端传输层
（真 `URLSession` + 真 SSE）已经实现并测过，但后端代理不存在，`baseURL` 无处可指。
详见 [ADR 002](../decisions/002-cloud-provider-wire-format-and-testing.md) 与
[streaming-in-swift.md](../03-cloud-llm/streaming-in-swift.md)。

端侧同理，而且更彻底：见第 7 节。

## 7. 要不要升到 macOS 26

**构建这个工程：不需要。** Xcode 26.2 自身的 `LSMinimumSystemVersion` 是 **15.6**
（读 `/Applications/Xcode.app/Contents/Info.plist` 得到），本机就是 macOS 15.7.3 +
Xcode 26.2，`verify.sh` 全绿。所以只要 ≥ 15.6，装 Xcode 26.2 就够。

**想实测端侧 LLM（Foundation Models）：必须升，或者用真机。** iOS 模拟器复用宿主 Mac 的
Apple Intelligence 模型资源，而 macOS 15.x 没有 Apple Intelligence，
本机实测 `SystemLanguageModel.default.availability == .unavailable(.modelNotReady)`。
细节见 [environment.md](environment.md)。换一台同样是 macOS 15.x 的机器**不会**改变这一点。

## 8. 磁盘空间

安装前留够空间，本机实测占用：

| 项目 | 体积 |
| --- | --- |
| `Xcode.app`（解压后） | 4.7 GB |
| iOS 26.2 运行时（挂载后） | 16 GB |
| iOS 26.2 运行时磁盘映像（压缩态） | 7.8 GB |

加上 `.xip` 本身和解压中间态，**建议预留 30 GB 以上**（这个数字是估算，不是实测）。
空间不足时 `.xip` 解压会在末尾失败，且不会明确告诉你是空间问题。

## 9. 下哪个 Xcode 安装包

Apple 下载页给两个包：Apple silicon 版和 Universal 版。`uname -m` 输出 `arm64` 就下
Apple silicon 版（体积更小，功能无差异）；输出 `x86_64` 是 Intel 机器，必须下 Universal 版。

装多个 Xcode 时，命令行默认指向哪个由 `xcode-select` 决定，改完记得核对：

```bash
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version        # 应输出 Xcode 26.2 / Build 17C52
```

## 10. 报错像是「修了也不消失」

Xcode 的 Issue navigator 会留着上一次构建的问题，升级 Xcode 后不重新构建，
旧的 `tools version` 报错还挂在那里，看起来像没修好。
⚠️ 未验证（未在本机复现，属于合理推断）：Cmd+Shift+K 清理 →
File → Packages → Reset Package Caches → 重新构建，应该就清掉了。

判断是不是残留有个可靠办法：命令行不读 Xcode 的 UI 状态，
`xcodebuild -resolvePackageDependencies` 通过就说明当前工具链没问题。

顺带一个诊断经验：**先确认报错来自哪台机器。** 本机只有一个
`/Applications/Xcode.app`（26.2）、`/Library/Developer/Toolchains` 与
`~/Library/Developer/Toolchains` 都不存在、`TOOLCHAINS` 未设置、Xcode 偏好里无 toolchain 覆盖 ——
这种配置下不可能报出 6.1.0。出现旧版本号，就是另一台机器或旧报错残留。

## 门槛表：每条约束写在哪

改动这些数字之前先知道它由谁决定，否则会漏改。

| 约束 | 值 | 写在哪 |
| --- | --- | --- |
| App 运行时下限 | iOS 26.0 | `project.yml:12-13` `deploymentTarget.iOS` |
| 包的平台下限 | iOS 26 / macOS 14 | 两个 `Package.swift` 的 `platforms` |
| SwiftPM 清单工具链 | Swift 6.2 | 两个 `Package.swift` 首行 `swift-tools-version` |
| Swift 语言模式 | 6.0 严格并发 | `project.yml:37-38`；包内 `.swiftLanguageMode(.v6)` |
| xcodegen 下限 | 2.46.0 | `project.yml:14` `minimumXcodeGenVersion` |
| 签名 | 全部关闭 | `project.yml:47-50` |

## 这些是设计使然，不要「修」

| 现象 | 为什么 |
| --- | --- |
| 仓库没有 `.xcodeproj` | 生成物不入库，工程结构改 `project.yml`；避免 AI 去动几千行带 UUID 的 pbxproj |
| 签名全关 | 保证验证链条无人工交互 |
| 默认走 mock | 后端代理还不存在，`baseURL` 无处可指 |
| 业务逻辑不在 App target 里 | 包内 `swift test` 在宿主 macOS 上秒级返回，模拟器构建是分钟级 |
| `PrivacyRequirement.onDeviceOnly` 端侧不可用时直接失败 | 静默降级到云端会把隐私承诺变成谎言 |

## 一个待决问题：iOS 26.0 这个下限有必要吗

**当前构建产物里没有用到任何 iOS 26 独有的 API。** `Packages/*/Sources` 与 `App` 的全部 import
只有 `Foundation`、`SwiftUI`、`Observation`、`AICore`、`AIFeatures`；`FoundationModels` /
`SystemLanguageModel` / `@Generable` 只出现在注释里。真正的技术地板是
`ChatStore.swift:9` 的 `@Observable`，那是 iOS 17.0。

所以 iOS 26.0 目前是**声明性的下限**，不是代码需要的。它还和架构不变量第一条
「云端为主线，端侧做增强」有张力：地板卡在 26 意味着 App 只能装在 iOS 26 设备上，
而恰好只有 iOS 26 才可能有端侧能力，「主线」与「增强」的受众就重合了。

降下来要动三处（`project.yml` 的 deployment target、两个 `Package.swift` 的 `platforms`、
可选地把 `swift-tools-version` 降到 6.0），代价是端侧代码将来必须用
`@available(iOS 26, *)` 加 `#if canImport(FoundationModels)` 双重门控；
而且**本机只有 iOS 26.2 一个运行时，降了下限也无法机器验证向下兼容** ——
要先下载一个低版本运行时，否则只是改了个数字。这条记在
[backlog.md](../backlog.md)，未拍板。

