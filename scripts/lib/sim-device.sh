#!/usr/bin/env bash
# 挑一台可用的 iOS 模拟器。这一份被 verify.sh / spike-origin.sh / probe.sh 共同 source，
# 不在三个脚本里各写一遍 —— 三份同样的设备选择逻辑迟早漂成三种行为。
#
# 为什么不按机型名交给 xcodebuild 解析：
#   -destination "platform=iOS Simulator,name=<机型>"
# 不带 OS 时，xcodebuild 按「最新已安装运行时」解析。装了多个运行时的机器上，机型只存在于
# 旧运行时就会报
#   Unable to find a device matching the provided destination specifier:
#           { platform:iOS Simulator, OS:latest, name:iPhone 17 Pro }
# 机型在、运行时也在，只是这个组合不存在。所以先自己解析出 UDID，之后 xcodebuild 与 simctl
# 一律按 id 用，绕开这层解析。
#
# 为什么不用 jq 解析 `simctl list -j`：jq 既不在 Xcode 里、也不是 macOS 自带，机器上不一定装，
# 验证链条不该多一个「装没装看运气」的依赖。`simctl list devices available` 的纯文本按
# `-- iOS <版本> --` 分组，awk 足够解析，且 awk 一定在。

# select_sim_device [机型名]
#
#   给了机型名 → 在同名的可用设备里取运行时最高的那台
#   没给机型名 → 在全部可用 iPhone 里取运行时最高的那台
#
# 成功后设好三个全局变量 SIM_NAME / SIM_RUNTIME / SIM_UDID，并打印一行选中结果；
# 一台都挑不出来就打印怎么补运行时并返回 1（调用方都开着 set -e，不会默默往下走）。
#
# 自动挑的代价：不同机器可能挑到不同设备，所以那行选中结果要留在运行记录里。M1–M4 没有
# 一条判据依赖屏幕尺寸，挑到哪台不影响结论，但得看得见这一跑用的是哪台。
select_sim_device() {
  local want="${1:-}" list picked

  if ! list="$(xcrun simctl list devices available 2>&1)"; then
    printf '❌ 读不到模拟器清单（xcrun simctl list devices available 失败）：\n%s\n' "$list" >&2
    return 1
  fi

  # 分组行形如 "-- iOS 26.3.1 --"，设备行形如 "    iPhone 17 Pro (<UDID>) (Shutdown)"。
  picked="$(printf '%s\n' "$list" | awk -v want="$want" '
    # 运行时分组头。非 iOS 的分组（tvOS/watchOS/xrOS）整段跳过。
    /^-- / { runtime = ($2 == "iOS") ? $3 : ""; next }
    runtime == "" { next }

    # 机型名自己也可能带括号（"iPad Pro 13-inch (M5)"、"iPad (A16)"），所以按 UDID 的形状
    # 定位——括号里五段十六进制、四个连字符——而不是数第几个括号。
    # 刻意不写 {8}-{4} 这种区间量词：老 macOS 自带的 awk 不支持它，不匹配时的表现是「一台
    # 设备也挑不出来」，排查起来看不出是正则的事。
    match($0, /\([0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+\)/) {
      udid = substr($0, RSTART + 1, RLENGTH - 2)
      name = substr($0, 1, RSTART - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)

      if (want != "") {
        if (name != want) next
      } else if (name !~ /^iPhone/) {
        next
      }

      # 运行时版本拼成定长键，才能直接比大小（"26.3.1" 与 "27.0" 要逐段比，字面量比不对）。
      split(runtime, seg, ".")
      key = sprintf("%05d%05d%05d", seg[1] + 0, seg[2] + 0, seg[3] + 0)
      # 严格大于：同一运行时里保留 simctl 的原始顺序，取先列出的那台。
      if (key > best) { best = key; out = name "\t" runtime "\t" udid }
    }

    END { if (out != "") print out }
  ')"

  if [[ -z "$picked" ]]; then
    {
      if [[ -n "$want" ]]; then
        printf '❌ 没有可用的模拟器叫「%s」（任何已装运行时上都没有）。\n' "$want"
        echo '   不设 CRAB_SIM_DEVICE 就在全部可用 iPhone 里自动挑一台。'
      else
        echo '❌ 一台可用的 iPhone 模拟器都没有。'
      fi
      echo '   模拟器运行时不随 Xcode 打包，要单独下：'
      echo '   Xcode → Settings（Cmd+,）→ Components → 下一个 iOS 运行时。'
      echo '   现有清单：xcrun simctl list devices available'
    } >&2
    return 1
  fi

  IFS=$'\t' read -r SIM_NAME SIM_RUNTIME SIM_UDID <<<"$picked"
  printf '→ 模拟器：%s · iOS %s · %s\n' "$SIM_NAME" "$SIM_RUNTIME" "$SIM_UDID"
}
