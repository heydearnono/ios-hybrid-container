# 运行记录 · 工程修补（模拟器按 UDID 选 / `run_logic` 判包）

- **跑的时间**：2026-09-22
- **环境**：macOS 15.7.3 / Xcode 26.2（17C52）/ xcodegen 2.46.0 / 模拟器运行时只有 iOS 26.2
  （即「环境基线」里的 A 那台。撞出这次修补的是 B 那台 Xcode 27.0 三运行时的机器，本记录不是在它上面跑的）
- **改的是什么**：选设备逻辑抽到 `scripts/lib/sim-device.sh`，解析出 UDID 后 `xcodebuild`
  与 `simctl` 一律按 `id=` 用；`run_logic` 改判 `Package.swift` 在不在
- **判据一个字没动**：`project.yml` 的取值、`probe.sh` 的十六条 slug、deployment target 26.0 都原样

下面是原样输出，不重新叙述一遍。

## 一 · 不设任何环境变量：`./scripts/verify.sh`（退出码 0）

```
==> swift test — 暂无逻辑包
本仓还没有 Packages/：M1 只有一个原生壳子，没有可在宿主 macOS 上跑的逻辑。
M2 起承载常量、路径归一化与配置取值都落在包里，那时这一档才有东西跑。

==> 挑一台模拟器
→ 模拟器：iPhone 17 Pro · iOS 26.2 · 4F1F3256-B45F-4DBF-9FE2-080237178174

==> xcodegen generate
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/wangjian/Desktop/github/ios-hybrid-container/Crab.xcodeproj

==> xcodebuild build（iOS 模拟器）

==> 产物里的取值与 pro 取值表逐项对齐
   CFBundleIdentifier = net.xiaoluzhu.crab
   CFBundleShortVersionString = 0.1.0
   CFBundleDisplayName = 螃蟹

==> 模拟器实跑冒烟测试
Wrote screenshot to: .probe/m1-home.png
→ 截图 .probe/m1-home.png（不入库，看一眼即可）
✅ 装得上、起得来、进程存活（iPhone 17 Pro · iOS 26.2）

==> 全部通过
```

## 二 · 指定机型：`CRAB_SIM_DEVICE='iPhone 17 Pro' ./scripts/verify.sh`（退出码 0）

```
==> 挑一台模拟器
→ 模拟器：iPhone 17 Pro · iOS 26.2 · 4F1F3256-B45F-4DBF-9FE2-080237178174
✅ 装得上、起得来、进程存活（iPhone 17 Pro · iOS 26.2）
==> 全部通过
```

## 三 · 空壳目录：`mkdir -p Packages/Foo && ./scripts/verify.sh logic`（退出码 0）

```
==> swift test — 暂无逻辑包
本仓还没有 Packages/：M1 只有一个原生壳子，没有可在宿主 macOS 上跑的逻辑。
M2 起承载常量、路径归一化与配置取值都落在包里，那时这一档才有东西跑。

==> 全部通过
```

跑完把 `Packages/Foo` 删掉了。改之前这里会走进 `swift test` 并报
`Could not find Package.swift in this directory or any of its parent directories.`

## 四 · 挑选规则本身：喂一台三运行时机器的清单

A 那台只有一个运行时，跑不出「机型只存在于旧运行时」那个组合，所以用 B 那台的 `simctl list
devices available` 输出形状顶掉 `xcrun` 单测 `select_sim_device`（18.6 / 26.3.1 / 27.0 三组，
`iPhone 17 Pro` 只在 26.3.1 上）：

```
[1] 不指定 → 该取 27.0 上的第一台 iPhone
→ 模拟器：iPhone 17 · iOS 27.0 · CCCCCCCC-0000-0000-0000-000000000009
[2] 指定 iPhone 17 Pro（只在 26.3.1 上有）→ 该取 ...004
→ 模拟器：iPhone 17 Pro · iOS 26.3.1 · BBBBBBBB-0000-0000-0000-000000000004
[3] 指定 iPhone 17（两个运行时都有）→ 该取 27.0 那台 ...009
→ 模拟器：iPhone 17 · iOS 27.0 · CCCCCCCC-0000-0000-0000-000000000009
[4] 指定 iPad (A16)（机型名自带括号）→ 该取 ...014
→ 模拟器：iPad (A16) · iOS 27.0 · CCCCCCCC-0000-0000-0000-000000000014
[5] 指定 Apple TV（非 iOS 分组）→ 该失败
❌ 没有可用的模拟器叫「Apple TV」（任何已装运行时上都没有）。
   不设 CRAB_SIM_DEVICE 就在全部可用 iPhone 里自动挑一台。
   模拟器运行时不随 Xcode 打包，要单独下：
   Xcode → Settings（Cmd+,）→ Components → 下一个 iOS 运行时。
   现有清单：xcrun simctl list devices available
如预期失败
```

第 2 条就是 B 那台原本挂住的那个组合。**在真正装了三个运行时的机器上还没实跑过** ——
这四条只证明规则对，没证明 B 那台从头到尾绿；那一跑要到 B 上补，补完贴在这份记录后面。

## 五 · 顺带复跑过的

- `./scripts/spike-origin.sh` 退出码 0，三条回读路（落盘 / console / OSLog）都还通，
  结论与 [`插队核实-承载origin.md`](插队核实-承载origin.md) 一致 —— 换成按 UDID 用没碰坏它
- `./scripts/probe.sh slugs` 仍是十六条、顺序未变；`./scripts/probe.sh` 仍以退出码 2 收场
