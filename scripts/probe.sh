#!/usr/bin/env bash
# 探针页断言的唯一入口。三仓同名，输出形状三端一字不差：
#
#   一行一条  <slug> PASS|FAIL|MANUAL   附加信息接在行尾
#
# slug 与行的顺序固定，就是 pro 的文档顺序：M2 六条、M3 两条、M4 八条，合计十六条。
# 规约在 pro 的 plan/M2-本地承载.md 最后一节，改要三端一起改，本仓不自定。
#
# 现状：M1 阶段探针页还不存在（M1 不碰 WebView），所以这里只落 slug 清单与输出形状，
# 一条也不实现。**刻意不打印任何 PASS / FAIL** —— 假的 PASS 会污染对账记录，
# 而 FAIL 的意思是「断言跑了没过」，不是「还没写」。未实现的走 stderr 并以退出码 2 收场。
#
# M4 那几条要人先按按钮、答对话框、触发一次后退，人工那一遍在本命令之前跑完；
# 本命令只把页面侧与原生日志侧的结果收齐并判定，不代按。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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

{
  echo "探针页尚未接入：M1 只有一个原生壳子，十六条断言一条也没有实现。"
  echo "承载与前六条落在 M2，注入两条落在 M3，导航与对话框八条落在 M4。"
  echo
  echo "待实现（0/${#SLUGS[@]}）："
  printf '  %s\n' "${SLUGS[@]}"
} >&2

exit 2
