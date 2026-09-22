#!/usr/bin/env bash
# 本仓的验证入口，AI 与 CI 都只调这个。
#
#   scripts/verify.sh          全量：逻辑测试 + 生成工程 + 构建 + 模拟器实跑
#   scripts/verify.sh logic    只跑包内逻辑测试（秒级，日常改代码用这个）
#   scripts/verify.sh app      只做工程生成 + 构建 + 模拟器实跑
#
# 前提：每一步都要能无人工干预地跑完 —— 不点 Xcode、不弹签名对话框、不需要真机。
# 探针页那十六条断言不在这里，它们由 scripts/probe.sh 跑（M2 起）。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 选设备这一段与 spike-origin.sh / probe.sh 共用一份，见该文件开头的注释。
# shellcheck source=lib/sim-device.sh
source "$ROOT/scripts/lib/sim-device.sh"

# 机型名只是个偏好：不设就自动挑，设了也仍然按 UDID 用（见 select_sim_device）。
SIM_DEVICE_PREF="${CRAB_SIM_DEVICE:-}"
SCHEME="Crab"
# 取值来自 pro 的取值表。这里写死是为了让「产物里的取值漂了」当场报错。
BUNDLE_ID="net.xiaoluzhu.crab"
APP_VERSION="0.1.0"
ZH_DISPLAY_NAME="螃蟹"
DERIVED=".build/xcode"
APP_PATH="${DERIVED}/Build/Products/Debug-iphonesimulator/Crab.app"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '❌ %s\n' "$1" >&2; exit 1; }

run_logic() {
  # 判据是 Package.swift 在不在，不是目录在不在。重建那一笔把源码删了之后，Packages/ 下可能
  # 剩下只含 .swiftpm/ 的空壳目录（全被 .gitignore 忽略，git status 看不见），按目录存在去判
  # 就会走进 swift test 并报 "Could not find Package.swift in this directory or any of its
  # parent directories." —— 看起来像 SwiftPM 坏了，其实是那个目录里没有包。
  local packages=() candidate
  for candidate in Packages/*/; do
    if [[ -f "${candidate}Package.swift" ]]; then
      packages+=("$candidate")
    fi
  done
  if (( ${#packages[@]} == 0 )); then
    step "swift test — 暂无逻辑包"
    echo "本仓还没有 Packages/：M1 只有一个原生壳子，没有可在宿主 macOS 上跑的逻辑。"
    echo "M2 起承载常量、路径归一化与配置取值都落在包里，那时这一档才有东西跑。"
    return 0
  fi
  for package in "${packages[@]}"; do
    step "swift test — ${package}"
    (cd "$package" && swift test)
  done
}

run_app() {
  step "挑一台模拟器"
  select_sim_device "$SIM_DEVICE_PREF"

  step "xcodegen generate"
  xcodegen generate

  step "xcodebuild build（iOS 模拟器）"
  xcodebuild build \
    -scheme "$SCHEME" \
    -destination "id=${SIM_UDID}" \
    -derivedDataPath "$DERIVED" \
    -quiet

  step "产物里的取值与 pro 取值表逐项对齐"
  local plist="${APP_PATH}/Info.plist"
  [[ -f "$plist" ]] || fail "产物里没有 Info.plist：${plist}"
  assert_plist "$plist" CFBundleIdentifier "$BUNDLE_ID"
  assert_plist "$plist" CFBundleShortVersionString "$APP_VERSION"
  # 中文显示名落在本地化资源里，不在 Info.plist 本体里 —— 少这一份，桌面图标下就是英文名。
  local zh_strings="${APP_PATH}/zh-Hans.lproj/InfoPlist.strings"
  [[ -f "$zh_strings" ]] || fail "产物里没有 zh-Hans.lproj/InfoPlist.strings，中文显示名落不下来"
  assert_plist "$zh_strings" CFBundleDisplayName "$ZH_DISPLAY_NAME"

  step "模拟器实跑冒烟测试"
  xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$SIM_UDID" >/dev/null
  xcrun simctl install "$SIM_UDID" "$APP_PATH"
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null

  # 启动即崩的 App 也会「launch 成功」，所以必须隔一会儿再确认进程还在。
  #
  # 这里刻意不用 `... | grep -q`：grep -q 匹配到就关闭管道，上游 launchctl 收到 SIGPIPE
  # 退出非零，`set -o pipefail` 会把整条流水线判为失败 —— 明明存活也会报崩溃。
  local listing="" alive=0
  for _ in 1 2 3 4 5; do
    sleep 2
    listing="$(xcrun simctl spawn "$SIM_UDID" launchctl list 2>/dev/null || true)"
    if [[ "$listing" == *"$BUNDLE_ID"* ]]; then
      alive=1
      break
    fi
  done

  # 「屏幕上能看到一个原生页面」这半条判据只有截图留得下证据，趁进程还在截。
  if (( alive == 1 )); then
    mkdir -p .probe
    xcrun simctl io "$SIM_UDID" screenshot --type=png .probe/m1-home.png >/dev/null
    echo "→ 截图 .probe/m1-home.png（不入库，看一眼即可）"
  fi

  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  (( alive == 1 )) || fail "App 启动后进程已消失（疑似崩溃）"
  echo "✅ 装得上、起得来、进程存活（${SIM_NAME} · iOS ${SIM_RUNTIME}）"

  xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
}

assert_plist() {
  local plist="$1" key="$2" expected="$3" actual
  actual="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || fail "${key} 取值是「${actual}」，取值表要的是「${expected}」"
  printf '   %s = %s\n' "$key" "$actual"
}

case "${1:-all}" in
  logic) run_logic ;;
  app)   run_app ;;
  all)   run_logic; run_app ;;
  *)     echo "用法: $0 [all|logic|app]" >&2; exit 2 ;;
esac

step "全部通过"
