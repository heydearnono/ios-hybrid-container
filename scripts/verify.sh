#!/usr/bin/env bash
# 一条命令验证整个工程。AI 与 CI 都只调这个入口。
#
#   scripts/verify.sh          全量：逻辑测试 + 生成工程 + 构建 + 模拟器实跑
#   scripts/verify.sh logic    只跑逻辑测试（秒级，日常改代码用这个）
#   scripts/verify.sh app      只做工程生成 + 构建 + 模拟器实跑
#
# 设计前提：整个项目由 AI 开发，所以每一步都必须无人工干预地跑完 ——
# 不点 Xcode、不弹签名对话框、不需要真机。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE="${AILAB_SIM_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="dev.ailab.AILab"
DERIVED=".build/xcode"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

run_logic() {
  for package in Packages/*/; do
    step "swift test — ${package}"
    (cd "$package" && swift test)
  done
}

run_app() {
  step "xcodegen generate"
  xcodegen generate

  step "xcodebuild build（iOS 模拟器）"
  xcodebuild build \
    -scheme AILab \
    -destination "platform=iOS Simulator,name=${DEVICE}" \
    -derivedDataPath "$DERIVED" \
    -quiet

  step "模拟器实跑冒烟测试"
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  xcrun simctl bootstatus "$DEVICE" >/dev/null

  local app_path="${DERIVED}/Build/Products/Debug-iphonesimulator/AILab.app"
  xcrun simctl install "$DEVICE" "$app_path"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null

  # 启动即崩的 App 也会「launch 成功」，所以必须隔一会儿再确认进程还在。
  #
  # 这里刻意不用 `... | grep -q`：grep -q 匹配到就关闭管道，上游 launchctl 收到 SIGPIPE
  # 退出非零，`set -o pipefail` 会把整条流水线判为失败 —— 明明存活也会报崩溃。
  local listing=""
  local alive=0
  for _ in 1 2 3 4 5; do
    sleep 2
    listing="$(xcrun simctl spawn "$DEVICE" launchctl list 2>/dev/null || true)"
    if [[ "$listing" == *"$BUNDLE_ID"* ]]; then
      alive=1
      break
    fi
  done

  if (( alive == 1 )); then
    echo "✅ App 启动后存活"
  else
    echo "❌ App 启动后进程已消失（疑似崩溃）"
    xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    exit 1
  fi

  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
}

case "${1:-all}" in
  logic) run_logic ;;
  app)   run_app ;;
  all)   run_logic; run_app ;;
  *)     echo "用法: $0 [all|logic|app]" >&2; exit 2 ;;
esac

step "全部通过"
