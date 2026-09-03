# spike: app-intents-01

- **日期**：2026-09-03
- **环境**：macOS 15.7.3（Darwin 24.6.0）/ Xcode 26.2（17C52）/ Swift 6.2.3 /
  iOS 26.2 SDK（`AppIntents` user-module-version 300.2.3.1）/ 无真机 / 宿主无 Apple Intelligence
- **对应笔记**：[`docs/05-agent-arch/app-intents-as-tools.md`](../../docs/05-agent-arch/app-intents-as-tools.md)

## 要验证的问题

1. iOS 26.2 SDK 里 App Intents 的核心形状（`AppIntent` / `@Parameter` / `AppEntity` /
   `AppShortcutsProvider` / `perform()` 返回类型体系）到底是什么？文档上的写法能不能编译过？
2. **iOS 26.2 有没有官方桥接把 `AppIntent` 变成 FoundationModels 的 `Tool`？**
3. `@Parameter` 的类型表达力边界在哪？嵌套结构体、字典、嵌套数组、无 `defaultQuery` 的 `AppEntity`
   分别会怎样？
4. **AppIntent 定义在 SPM 包里，能不能在宿主 macOS 上被 `swift test` 直接测？
   构建期元数据抽取还会不会跑？** ——这是本题最关键的一条，决定 App Intents 会不会
   把业务逻辑逼进 App target（那样反馈就从秒级退化到分钟级）。
5. 手写 `AppIntent` → `Tool` 适配层要写多少、重复在哪；泛型适配器为什么做不到。

## 怎么跑

统一的 typecheck 命令（不需要模拟器）：

```bash
TC() { xcrun swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios26.2-simulator -swift-version 6 "$@" ; }
```

### 1. 正向形状验证

```bash
TC intent-typecheck.swift            # 期望 EXIT=0
```

### 2. 参数类型边界（负向，逐个 case 单独编）

```bash
for C in CASE_A CASE_B CASE_C CASE_D; do
  TC -D $C param-limits-negative.swift > /tmp/$C.log 2>&1; echo "$C EXIT=$?"
done
```

### 3. 手写适配层 + 泛型适配器负向验证

```bash
TC intent-tool-adapter.swift         # 期望 EXIT=0
TC generic-adapter-negative.swift    # 基线，期望 EXIT=0
for C in CASE_GENERIC CASE_RESULT CASE_INTENT_AS_TOOL; do
  TC -D $C generic-adapter-negative.swift > /tmp/$C.log 2>&1; echo "$C EXIT=$?"
done
```

> `intent-tool-adapter.swift` 只做 `-typecheck`。本机跑不了端侧模型
> （见 [`docs/01-on-device-llm/foundation-models-overview.md`](../../docs/01-on-device-llm/foundation-models-overview.md)），
> 所以适配层的**运行时**行为未实测。

### 4. 包内 Intent 的宿主测试（`HostTest/`）

```bash
cd HostTest && swift test          # 4 个 swift-testing 用例，在 macOS 15.7.3 宿主上跑
```

### 5. 构建期元数据抽取（`AppBuild/`）

```bash
cd AppBuild
xcodegen generate
xcodebuild build -scheme IntentSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcode

APP=.build/xcode/Build/Products/Debug-iphonesimulator/IntentSpike.app
ls "$APP/Metadata.appintents"
python3 -c "
import json
d = json.load(open('$APP/Metadata.appintents/extract.actionsdata'))
for k, v in d['actions'].items():          # 注意 actions 是 dict，按短名索引
    print(k, '=>', v.get('fullyQualifiedTypeName'),
          '| params:', [p.get('name') for p in v.get('parameters', [])])
print('enums:', [(e.get('identifier'), e.get('fullyQualifiedTypeName')) for e in d['enums']])
"
cat "$APP/Metadata.appintents/extract.packagedata"
```

对照实验（去掉 App 侧的 `AppIntentsPackage` 声明）：

```bash
xcodebuild build -scheme IntentSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcode-nopkg \
  OTHER_SWIFT_FLAGS='-D NO_PACKAGE_DECL'
```

> `AppBuild/IntentSpike.xcodeproj` 和 `.build/` 都是生成物，跑完已删除，不入库
> （架构不变量 5）。

## 结论

1. **形状全部验证通过**（EXIT=0）。`AppIntent` 的 `perform()` 返回 `associatedtype PerformResult:
   IntentResult`，`IntentResult` 的 `value` 是 **Optional**（`var value: Self.Value?`），
   所以适配层取值必须兜底。iOS 26 起 `openAppWhenRun` 被标记 deprecated，改用 `supportedModes`。

2. **没有官方桥接。** 四条独立证据：
   - `AppIntents.swiftinterface`（13301 行）中 `FoundationModels` / `Generable` /
     `LanguageModelSession` 出现次数均为 **0**；
   - `FoundationModels.swiftinterface` 中 "intent"（忽略大小写）出现次数为 **0**；
   - iOS 26.2 SDK 里存在 `_AppIntents_SwiftUI` / `_AppIntents_UIKit` / `_GeoToolbox_AppIntents` /
     `_Photos_AppIntents` 等 cross-import overlay，但**不存在** `_FoundationModels_AppIntents`
     或 `_AppIntents_FoundationModels`；
   - 编译器层面：泛型 `IntentTool<I: AppIntent>: Tool` 写不出来（见第 5 条）。

3. **参数类型边界**：
   | case | 写法 | 结果 |
   | --- | --- | --- |
   | A | `@Parameter var addr: Address`（嵌套 struct） | EXIT=1 `generic class 'IntentParameter' requires that 'Address' conform to '_IntentValue'` |
   | B | `@Parameter var meta: [String: String]` | EXIT=1 同上形状 |
   | C | `@Parameter var matrix: [[String]]` | **EXIT=0**（编得过；运行时/Shortcuts 表现未实测） |
   | D | `AppEntity` 不提供 `defaultQuery` | EXIT=1 `type 'BareEntity' does not conform to protocol 'AppEntity'` |

4. **App Intents 不会把逻辑逼进 App target** —— 本题最重要的一条，且结论与担忧相反：
   - 包内定义的 `SummarizeIntent` 在宿主 macOS 15.7.3 上被 `swift test` 直接测通，
     **4/4 通过**，包括 `await intent.perform()` 并断言 `result.value`。
     （`AppIntents` 是 macOS 13+ 框架，所以宿主能 import；`FoundationModels` 是 macOS 26+，不能。）
   - `xcodebuild` 对包 target 同样执行 `ExtractAppIntentsMetadata`。
     `IntentSpike.app/Metadata.appintents/extract.actionsdata` 的 `actions` 字典里两条并列：
     ```
     AppTargetPingIntent => IntentSpike.AppTargetPingIntent | params: []
     SummarizeIntent     => IntentKit.SummarizeIntent       | params: ['text','maxWords','style']
     enums: [('SummaryStyle', 'IntentKit.SummaryStyle')]
     ```
     `root.ssu.yaml` 里连包内 Intent 的 App Shortcut 语音短语也在
     （`'{${+prefix} }Summarize with ${+applicationName}'`）。
   - 对照实验（`OTHER_SWIFT_FLAGS='-D NO_PACKAGE_DECL'`）：去掉 App 侧 `AppIntentsPackage`
     声明后，两个 Intent **仍然被抽取**，但产物少了 `extract.packagedata`
     （原内容 `{"version":1,"includes":["9IntentKit0aB7PackageV"]}`）。
     运行时后果无真机无法验证。

5. **手写适配层可行，泛型适配器不可行。**
   `intent-tool-adapter.swift` EXIT=0：每个 Intent 一个 `Tool`，参数要用
   `@Generable` + `@Guide` **重新声明一遍**，枚举要手工映射。
   顺带发现 `@Generable enum DualStyle: String, AppEnum` 能编过 ——
   **一个类型可以同时是 `AppEnum` 和 `Generable`**，枚举这一层的重复可以省掉。
   三个负向 case 全部 EXIT=1：
   - `CASE_GENERIC` → `'Parameters' is not a member type of type 'I'` +
     `type 'IntentTool<I>' does not conform to protocol 'Tool'`
   - `CASE_RESULT` → `type 'ResultPassthroughTool<I>' does not conform to protocol 'Tool'`
   - `CASE_INTENT_AS_TOOL` → `type 'DualIntent' does not conform to protocol 'Tool'`

6. **反馈速度实测**（改动包内一个源文件后）：`swift test` 9.89s vs `xcodebuild build` 28.29s；
   空跑 0.91s vs 3.35s；冷启 30.73s vs 56.09s。

完整分析、版本漂移与选型建议见笔记。
