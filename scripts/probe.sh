#!/usr/bin/env bash
# 探针页断言的唯一入口。三仓同名，输出形状三端一字不差：
#
#   一行一条  <slug> PASS|FAIL|MANUAL   附加信息接在行尾
#
# slug 与行的顺序固定，就是 pro 的文档顺序：M2 六条、M3 两条、M4 八条，合计十六条。
# 规约在 pro 的 plan/M2-本地承载.md 最后一节，改要三端一起改，本仓不自定。
#
# 现状（M2）：承载前六条已接上，由本脚本在模拟器上跑出 PASS / FAIL。
# M3 两条、M4 八条还没实现——它们**不打印任何 PASS / FAIL**，走 stderr 列出，
# 因为假的 PASS 会污染对账记录，而 FAIL 的意思是「断言跑了没过」，不是「还没写」。
# 还有未实现条目时，命令以退出码 2 收场；六条里只要有一条 FAIL（或没跑出来），退出码 1。
#
# M4 那几条要人先按按钮、答对话框、触发一次后退，人工那一遍在本命令之前跑完；
# 本命令只把页面侧与原生日志侧的结果收齐并判定，不代按。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 选设备这一段三个脚本共用一份，不各写一遍（见该文件开头的注释）。run 分支先
# `select_sim_device` 挑出 SIM_UDID，之后 simctl 一律按它用。
# shellcheck source=lib/sim-device.sh
source "$ROOT/scripts/lib/sim-device.sh"

# slug 顺序即输出顺序，不要重排。右边一列是它由哪个里程碑装上。
SLUGS=(
  "origin              M2"
  "storage             M2"
  "subresource         M2"
  "intercept           M2"
  "escape              M2"
  "escape-encoded      M2"
  "inject-order        M3"
  "inject-scope        M3"
  "nav-same-origin     M4"
  "nav-back            M4"
  "nav-cross-origin    M4"
  "nav-blank           M4"
  "nav-system-scheme   M4  结果落在拨号盘与邮件应用，永远输出 MANUAL，另附一行人工观察"
  "nav-unknown-scheme  M4"
  "dialog              M4"
  "permission          M4"
)

case "${1:-run}" in
  slugs)
    printf '%s\n' "${SLUGS[@]}"
    exit 0
    ;;
  run) ;;
  *)
    echo "用法: $0 [run|slugs]" >&2
    exit 2
    ;;
esac

BUNDLE_ID="net.xiaoluzhu.crab"
DERIVED=".build/xcode"
APP_PATH="${DERIVED}/Build/Products/Debug-iphonesimulator/Crab.app"
RESULT_NAME="m2-probe.txt"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1" >&2; }

step "挑一台模拟器"
select_sim_device "${CRAB_SIM_DEVICE:-}"

step "生成工程并构建"
xcodegen generate >&2
xcodebuild build \
  -scheme Crab \
  -destination "id=${SIM_UDID}" \
  -derivedDataPath "$DERIVED" \
  -quiet >&2

step "装进模拟器"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" >/dev/null
xcrun simctl install "$SIM_UDID" "$APP_PATH" >&2

step "起一次 --probe-m2，等页面把六条判完落盘"
# 清掉上一轮的结果，免得读到旧的。
container="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
[[ -n "$container" ]] && rm -f "${container}/Documents/${RESULT_NAME}"

xcrun simctl launch --terminate-running-process "$SIM_UDID" "$BUNDLE_ID" --probe-m2 >&2

# 轮询结果文件出现（断言里有 fetch，异步）。最多 ~20s。
result=""
for _ in $(seq 1 20); do
  sleep 1
  container="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  candidate="${container}/Documents/${RESULT_NAME}"
  if [[ -n "$container" && -f "$candidate" ]]; then
    result="$candidate"
    break
  fi
done

mkdir -p .probe
xcrun simctl io "$SIM_UDID" screenshot --type=png .probe/m2-probe.png >/dev/null 2>&1 || true
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true

if [[ -z "$result" ]]; then
  echo "❌ 没读到结果文件 Documents/${RESULT_NAME}：探针页没跑完或没落盘。不编造结果。" >&2
  exit 1
fi
cp "$result" ".probe/${RESULT_NAME}"

# —— 判定与输出 ——
# 实现了的（M2）打到 stdout；没实现的（M3/M4）走 stderr，一个 PASS 也不假装。
fail=0
pending=0
pending_lines=()

for entry in "${SLUGS[@]}"; do
  read -r slug milestone _rest <<<"$entry"
  if [[ "$milestone" == "M2" ]]; then
    value="$(awk -v s="$slug" '$1==s{print $2}' "$result" || true)"
    if [[ -z "$value" ]]; then
      value="FAIL"
      echo "   （$slug 没在结果文件里，判 FAIL，不编造）" >&2
    fi
    printf '%s %s\n' "$slug" "$value"
    [[ "$value" == "PASS" ]] || fail=1
  else
    pending=1
    pending_lines+=("${slug}（${milestone}）")
  fi
done

if (( pending == 1 )); then
  {
    echo
    echo "未实现（走 stderr，不进 stdout 的判定）："
    printf '  %s\n' "${pending_lines[@]}"
  } >&2
fi

if (( fail == 1 )); then
  exit 1          # 有断言跑了没过
elif (( pending == 1 )); then
  exit 2          # 六条过了，但十六条还没齐
else
  exit 0
fi
