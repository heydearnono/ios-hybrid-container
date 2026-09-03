#!/usr/bin/env bash
# spike: text-embedding-01 —— 一条命令跑完，无人工干预。
#
#   ./run.sh              # 类型检查 + 模拟器实跑（默认 iPhone 17 Pro）
#   ./run.sh typecheck    # 只做类型检查，不需要模拟器
#   ./run.sh app          # 额外打一个最小 .app 进模拟器跑（验证「是不是缺 App 容器」）
#
# 二进制全部编到 mktemp 目录里，跑完删掉 —— 仓库里不留产物。

set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios26.2-simulator"
DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro}"
MODE="${1:-all}"

echo "==> [1/3] typecheck api-typecheck.swift（把 26.2 的精确签名钉住）"
xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET" -swift-version 6 api-typecheck.swift
echo "    OK"

if [[ "$MODE" == "typecheck" ]]; then exit 0; fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> [2/3] build embedding-probe.swift"
xcrun swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 \
  embedding-probe.swift -o "$BUILD/embprobe" 2>&1 | grep -v incompatible-sysroot || true

DEV="$(xcrun simctl list devices available | grep -m1 "$DEVICE_NAME (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [[ -z "$DEV" ]]; then echo "找不到可用模拟器：$DEVICE_NAME" >&2; exit 1; fi
echo "    device = $DEVICE_NAME ($DEV)"

xcrun simctl boot "$DEV" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1 || true

echo "==> [3/3] run on simulator（日志走 stderr）"
# 注意：**首次**在一台全新模拟器上跑，NLEmbedding 的句向量资源还没下载，会全是 nil。
# 探针里的 requestAssets 会把资源拉下来，但**不会回调**；下一次跑才看得到句向量。
xcrun simctl spawn "$DEV" "$BUILD/embprobe" || true

if [[ "$MODE" == "app" ]]; then
  echo "==> [extra] 打成最小 .app 再跑一遍（排除「裸进程没有 App 容器」这个可能）"
  APP="$BUILD/CtxProbe.app"
  mkdir -p "$APP"
  xcrun swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 \
    contextual-in-app-probe.swift -o "$APP/CtxProbe" 2>&1 | grep -v incompatible-sysroot || true
  cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CtxProbe</string>
  <key>CFBundleIdentifier</key><string>lab.ios.ctxprobe</string>
  <key>CFBundleName</key><string>CtxProbe</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>MinimumOSVersion</key><string>26.2</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>LSRequiresIPhoneOS</key><true/>
</dict>
</plist>
PLIST
  xcrun simctl install "$DEV" "$APP"
  xcrun simctl launch --console-pty "$DEV" lab.ios.ctxprobe || true
  xcrun simctl uninstall "$DEV" lab.ios.ctxprobe || true
fi

echo "==> done"
