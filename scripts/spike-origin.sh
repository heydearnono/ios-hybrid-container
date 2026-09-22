#!/usr/bin/env bash
# 插队核实 · 承载 origin 形态与 data: iframe
#
#   scripts/spike-origin.sh
#
# 起一次带 `--spike-origin` 的 App，把两种 URL 形状（带 host / 不带 host）的
# location.origin、storage、子资源、注入计数与两个子帧的自报都收回来。
#
# 结果三条路各取一次，顺带回答「从命令行回读得到什么」：
#   1. 落盘文件 —— simctl get_app_container 直接读，最可靠
#   2. print    —— simctl launch --console-pty 收得到
#   3. OSLog    —— simctl spawn log show，M4 那几条靠日志判的断言要走这条路
#
# 这是一次性验证代码，不是 M2 的承载实现。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 选设备这一段与 verify.sh / probe.sh 共用一份，见该文件开头的注释。
# shellcheck source=lib/sim-device.sh
source "$ROOT/scripts/lib/sim-device.sh"

SIM_DEVICE_PREF="${CRAB_SIM_DEVICE:-}"
BUNDLE_ID="net.xiaoluzhu.crab"
DERIVED=".build/xcode"
APP_PATH="${DERIVED}/Build/Products/Debug-iphonesimulator/Crab.app"
OUT=".probe"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

mkdir -p "$OUT"

step "挑一台模拟器"
select_sim_device "$SIM_DEVICE_PREF"

step "生成工程并构建"
xcodegen generate >/dev/null
xcodebuild build \
  -scheme Crab \
  -destination "id=${SIM_UDID}" \
  -derivedDataPath "$DERIVED" \
  -quiet

step "装进模拟器"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" >/dev/null
xcrun simctl install "$SIM_UDID" "$APP_PATH"

step "起一次，stdout 收进 ${OUT}/spike-console.txt"
# --console-pty 会一直跟着进程，所以后台跑、给足时间、再收摊。
xcrun simctl launch --terminate-running-process --console-pty \
  "$SIM_UDID" "$BUNDLE_ID" --spike-origin >"${OUT}/spike-console.txt" 2>&1 &
launch_pid=$!
sleep 12
xcrun simctl io "$SIM_UDID" screenshot --type=png "${OUT}/spike-origin.png" 2>/dev/null || true
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
wait "$launch_pid" 2>/dev/null || true

step "① 落盘文件（判据取这一条）"
container="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)"
result="${container}/Documents/spike-origin.txt"
if [[ -f "$result" ]]; then
  cp "$result" "${OUT}/spike-origin.txt"
  cat "${OUT}/spike-origin.txt"
else
  echo "❌ 没有落盘文件：${result}"
fi

step "② console 里的 CRAB-SPIKE 行"
grep -a "CRAB-SPIKE" "${OUT}/spike-console.txt" || echo "（console 里一行也没有）"

step "③ OSLog 回读（M4 关心的就是这条路通不通）"
xcrun simctl spawn "$SIM_UDID" log show \
  --last 3m --style compact \
  --predicate 'subsystem == "net.xiaoluzhu.crab"' 2>/dev/null \
  | grep -a "CRAB-SPIKE" || echo "（log show 里一行也没有 —— 这条路要另找，写进记录）"

xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true

step "完事。原始输出都在 ${OUT}/（不入库），结论写进 docs/运行记录/"
